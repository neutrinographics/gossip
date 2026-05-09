import 'dart:async' show StreamController, unawaited;
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;
import 'package:gossip/gossip.dart';
import 'package:nearby_connections/nearby_connections.dart';

import '../../domain/interfaces/nearby_port.dart';
import '../../domain/value_objects/endpoint_id.dart';
import '../../domain/value_objects/service_id.dart';

/// The user name passed to Nearby Connections API.
///
/// This value is not used by our handshake protocol since we exchange
/// `NodeId`s after connection. The Nearby Connections API requires a
/// non-null string, so we pass an empty string.
const _unusedUserName = '';

/// Marker for the platform-side "already advertising" status — the radio
/// is active under our service ID even though our Dart-side state thinks
/// it isn't. See [NearbyAdapter.startAdvertising] for the recovery path.
const _statusAlreadyAdvertising = 'STATUS_ALREADY_ADVERTISING';

/// Marker for the platform-side "already discovering" status. See
/// [NearbyAdapter.startDiscovery].
const _statusAlreadyDiscovering = 'STATUS_ALREADY_DISCOVERING';

/// Implements [NearbyPort] using the `nearby_connections` Flutter plugin.
///
/// This adapter translates between the domain's port interface and
/// the platform-specific Nearby Connections API.
class NearbyAdapter implements NearbyPort {
  final Nearby _nearby;
  final LogCallback? _onLog;
  final _eventController = StreamController<NearbyEvent>.broadcast();

  bool _isAdvertising = false;
  bool _isDiscovering = false;
  final Strategy _strategy;

  NearbyAdapter({
    Nearby? nearby,
    required Strategy strategy,
    LogCallback? onLog,
  }) : _nearby = nearby ?? Nearby(),
       _strategy = strategy,
       _onLog = onLog;

  @override
  Stream<NearbyEvent> get events => _eventController.stream;

  @override
  Future<void> startAdvertising(ServiceId serviceId, String displayName) async {
    if (_isAdvertising) return;

    try {
      final started = await _nearby.startAdvertising(
        displayName,
        _strategy,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
        serviceId: serviceId.value,
      );

      if (started) {
        _isAdvertising = true;
        _log(LogLevel.debug, 'Advertising started');
      } else {
        _log(LogLevel.warning, 'startAdvertising returned false');
      }
    } on PlatformException catch (e, stack) {
      // The platform is already advertising for our service — the OS-level
      // state and our Dart-side flag drifted out of sync (e.g. a prior
      // stop call silently failed under a Bluetooth toggle). The radio is
      // doing what we asked it to; adopt the state instead of bubbling
      // a misleading failure up to the caller.
      if (_isAlreadyAdvertising(e)) {
        _isAdvertising = true;
        _log(
          LogLevel.warning,
          'Platform reports already advertising — adopting state '
          '(prior session likely did not clean up)',
        );
        await _dropOrphanedConnections();
        return;
      }
      _log(LogLevel.error, 'startAdvertising failed', e, stack);
      rethrow;
    } catch (e, stack) {
      _log(LogLevel.error, 'startAdvertising failed', e, stack);
      rethrow;
    }
  }

  @override
  Future<void> stopAdvertising() async {
    if (!_isAdvertising) return;
    try {
      await _nearby.stopAdvertising();
    } catch (e, stack) {
      _log(LogLevel.error, 'stopAdvertising failed', e, stack);
    } finally {
      _isAdvertising = false;
    }
  }

  @override
  Future<void> startDiscovery(ServiceId serviceId) async {
    if (_isDiscovering) return;

    try {
      final started = await _nearby.startDiscovery(
        _unusedUserName,
        _strategy,
        onEndpointFound: _onEndpointFound,
        onEndpointLost: _onEndpointLost,
        serviceId: serviceId.value,
      );

      if (started) {
        _isDiscovering = true;
        _log(LogLevel.debug, 'Discovery started');
      } else {
        _log(LogLevel.warning, 'startDiscovery returned false');
      }
    } on PlatformException catch (e, stack) {
      // See [startAdvertising] for the reasoning — adopt platform state
      // when it's already running our discovery rather than treating it
      // as a failure.
      if (_isAlreadyDiscovering(e)) {
        _isDiscovering = true;
        _log(
          LogLevel.warning,
          'Platform reports already discovering — adopting state '
          '(prior session likely did not clean up)',
        );
        await _dropOrphanedConnections();
        return;
      }
      _log(LogLevel.error, 'startDiscovery failed', e, stack);
      rethrow;
    } catch (e, stack) {
      _log(LogLevel.error, 'startDiscovery failed', e, stack);
      rethrow;
    }
  }

  /// True iff [e] indicates the platform is already advertising under our
  /// service. The Google Nearby Connections plugin surfaces this as
  /// status code 8001 with the message "8001: STATUS_ALREADY_ADVERTISING".
  bool _isAlreadyAdvertising(PlatformException e) =>
      e.message?.contains(_statusAlreadyAdvertising) ?? false;

  /// True iff [e] indicates the platform is already running discovery
  /// under our service. Status code 8002.
  bool _isAlreadyDiscovering(PlatformException e) =>
      e.message?.contains(_statusAlreadyDiscovering) ?? false;

  /// Drops any platform-level connections we have no Dart-side state for.
  ///
  /// When we adopt a STATUS_ALREADY_* state, the radio survived from a
  /// prior process (e.g. a hot restart) but every connection it holds is
  /// orphaned: the higher layers have no message-port wiring for those
  /// endpoints, so traffic over them silently disappears. Tearing the
  /// connections down lets discovery re-find peers and run a fresh
  /// handshake — restoring a working state instead of leaving the radio
  /// stuck talking past everyone.
  Future<void> _dropOrphanedConnections() async {
    try {
      await _nearby.stopAllEndpoints();
    } catch (e, stack) {
      _log(
        LogLevel.warning,
        'stopAllEndpoints during adoption failed',
        e,
        stack,
      );
    }
  }

  @override
  Future<void> stopDiscovery() async {
    if (!_isDiscovering) return;
    try {
      await _nearby.stopDiscovery();
    } catch (e, stack) {
      _log(LogLevel.error, 'stopDiscovery failed', e, stack);
    } finally {
      _isDiscovering = false;
    }
  }

  @override
  Future<void> requestConnection(EndpointId endpointId) async {
    await _nearby.requestConnection(
      _unusedUserName,
      endpointId.value,
      onConnectionInitiated: _onConnectionInitiated,
      onConnectionResult: _onConnectionResult,
      onDisconnected: _onDisconnected,
    );
  }

  @override
  Future<void> disconnect(EndpointId endpointId) async {
    await _nearby.disconnectFromEndpoint(endpointId.value);
  }

  @override
  Future<void> sendPayload(EndpointId endpointId, Uint8List bytes) async {
    await _nearby.sendBytesPayload(endpointId.value, bytes);
  }

  /// Disposes resources.
  Future<void> dispose() async {
    await stopAdvertising();
    await stopDiscovery();
    await _eventController.close();
  }

  // --- Nearby Callbacks ---

  void _onEndpointFound(
    String endpointId,
    String endpointName,
    String serviceId,
  ) {
    _eventController.add(
      EndpointDiscovered(id: EndpointId(endpointId), displayName: endpointName),
    );
  }

  void _onEndpointLost(String? endpointId) {
    if (endpointId != null) {
      _eventController.add(EndpointLost(id: EndpointId(endpointId)));
    }
  }

  void _onConnectionInitiated(String endpointId, ConnectionInfo info) {
    _log(
      LogLevel.debug,
      'Connection initiated: $endpointId '
      '(incoming: ${info.isIncomingConnection}, name: ${info.endpointName})',
    );
    unawaited(
      _nearby
          .acceptConnection(
            endpointId,
            onPayLoadRecieved: (endpointId, payload) =>
                _onPayloadReceived(endpointId, payload),
            onPayloadTransferUpdate: (endpointId, update) {},
          )
          .catchError((Object e, StackTrace stack) {
            _log(
              LogLevel.error,
              'acceptConnection failed for $endpointId',
              e,
              stack,
            );
            _eventController.add(
              ConnectionFailed(
                id: EndpointId(endpointId),
                reason: 'acceptConnection failed: $e',
              ),
            );
          }),
    );
  }

  void _onConnectionResult(String endpointId, Status status) {
    if (status == Status.CONNECTED) {
      _eventController.add(ConnectionEstablished(id: EndpointId(endpointId)));
    } else {
      _eventController.add(
        ConnectionFailed(id: EndpointId(endpointId), reason: status.name),
      );
    }
  }

  void _onDisconnected(String endpointId) {
    _eventController.add(Disconnected(id: EndpointId(endpointId)));
  }

  void _onPayloadReceived(String endpointId, Payload payload) {
    if (payload.type != PayloadType.BYTES || payload.bytes == null) return;

    _eventController.add(
      PayloadReceived(id: EndpointId(endpointId), bytes: payload.bytes!),
    );
  }

  void _log(
    LogLevel level,
    String message, [
    Object? error,
    StackTrace? stack,
  ]) {
    _onLog?.call(level, message, error, stack);
  }
}
