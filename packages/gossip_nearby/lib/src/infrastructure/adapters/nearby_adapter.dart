import 'dart:async' show StreamController, unawaited;
import 'dart:typed_data';

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

  NearbyAdapter({Nearby? nearby, LogCallback? onLog})
    : _nearby = nearby ?? Nearby(),
      _onLog = onLog;

  @override
  Stream<NearbyEvent> get events => _eventController.stream;

  @override
  Future<void> startAdvertising(ServiceId serviceId, String displayName) async {
    if (_isAdvertising) return;

    try {
      final started = await _nearby.startAdvertising(
        displayName,
        Strategy.P2P_CLUSTER,
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
        Strategy.P2P_CLUSTER,
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
    } catch (e, stack) {
      _log(LogLevel.error, 'startDiscovery failed', e, stack);
      rethrow;
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
