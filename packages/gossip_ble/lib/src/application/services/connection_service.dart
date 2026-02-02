import 'dart:async';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

import '../../domain/aggregates/connection_registry.dart';
import '../../domain/errors/connection_error.dart';
import '../../domain/events/connection_event.dart';
import '../../domain/ports/ble_port.dart';
import '../../domain/ports/handshake_codec_port.dart';
import '../../domain/value_objects/device_id.dart';
import '../observability/ble_metrics.dart';
import '../observability/log_level.dart';

/// Callback for receiving gossip messages.
typedef GossipMessageCallback = void Function(NodeId sender, Uint8List bytes);

/// A simple cancellation token for timeout handling.
class _CancellationToken {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() {
    _isCancelled = true;
  }
}

/// Application service coordinating connection lifecycle and handshakes.
///
/// Responsibilities:
/// - Listens to BlePort events and orchestrates responses
/// - Manages handshake protocol (send/receive NodeIds)
/// - Forwards gossip messages to/from the domain
/// - Emits domain events for connection state changes
class ConnectionService {
  final NodeId _localNodeId;
  final BlePort _blePort;
  final ConnectionRegistry _registry;
  final HandshakeCodecPort _codec;
  final BleMetrics _metrics;
  final LogCallback? _onLog;
  final Duration _handshakeTimeout;
  final TimePort _timePort;

  final _eventController = StreamController<ConnectionEvent>.broadcast();
  final _errorController = StreamController<ConnectionError>.broadcast();
  StreamSubscription<BleEvent>? _bleSubscription;

  final Map<DeviceId, DateTime> _handshakeStartTimes = {};
  final Map<DeviceId, _CancellationToken> _handshakeTimeoutTokens = {};

  /// Callback invoked when a gossip message is received from a connected peer.
  GossipMessageCallback? onGossipMessage;

  /// Default timeout for handshake completion.
  static const defaultHandshakeTimeout = Duration(seconds: 30);

  ConnectionService({
    required NodeId localNodeId,
    required BlePort blePort,
    required ConnectionRegistry registry,
    required HandshakeCodecPort codec,
    required TimePort timePort,
    BleMetrics? metrics,
    LogCallback? onLog,
    Duration? handshakeTimeout,
  }) : _localNodeId = localNodeId,
       _blePort = blePort,
       _registry = registry,
       _codec = codec,
       _timePort = timePort,
       _metrics = metrics ?? BleMetrics(),
       _onLog = onLog,
       _handshakeTimeout = handshakeTimeout ?? defaultHandshakeTimeout {
    _bleSubscription = _blePort.events.listen(_handleBleEvent);
  }

  /// Stream of connection events (HandshakeCompleted, ConnectionClosed, etc.)
  Stream<ConnectionEvent> get events => _eventController.stream;

  /// Stream of connection errors for observability.
  Stream<ConnectionError> get errors => _errorController.stream;

  /// Metrics for this service.
  BleMetrics get metrics => _metrics;

  /// Sends a gossip message to the specified peer.
  Future<void> sendGossipMessage(NodeId destination, Uint8List bytes) async {
    final deviceId = _registry.getDeviceIdForNode(destination);
    if (deviceId == null) {
      _log(LogLevel.warning, 'Cannot send: no connection for $destination');
      _errorController.add(
        ConnectionNotFoundError(
          destination,
          'No active connection for peer',
          occurredAt: DateTime.now(),
        ),
      );
      return;
    }

    try {
      final wrapped = _codec.wrapGossip(bytes);
      await _blePort.send(deviceId, wrapped);
      _metrics.recordBytesSent(wrapped.length);
      _log(LogLevel.trace, 'Sent ${wrapped.length} bytes to $destination');
    } catch (e, stack) {
      _log(LogLevel.error, 'Send failed to $destination', e, stack);
      _errorController.add(
        SendFailedError(
          destination,
          'Failed to send payload: $e',
          occurredAt: DateTime.now(),
          cause: e,
        ),
      );
    }
  }

  /// Disposes resources.
  Future<void> dispose() async {
    // Cancel all pending handshake timeouts
    for (final token in _handshakeTimeoutTokens.values) {
      token.cancel();
    }
    _handshakeTimeoutTokens.clear();
    _handshakeStartTimes.clear();

    await _bleSubscription?.cancel();
    await _eventController.close();
    await _errorController.close();
  }

  void _handleBleEvent(BleEvent event) {
    switch (event) {
      case DeviceDiscovered():
        // Handled at facade level
        break;
      case ConnectionEstablished(:final id):
        _onConnectionEstablished(id);
      case BytesReceived(:final id, :final bytes):
        _onBytesReceived(id, bytes);
      case DeviceDisconnected(:final id):
        _onDisconnected(id);
    }
  }

  void _onConnectionEstablished(DeviceId deviceId) {
    _log(LogLevel.info, 'Connection established: $deviceId');
    _metrics.recordConnectionEstablished();

    // Register pending handshake and send our NodeId
    _registry.registerPendingHandshake(deviceId);
    _handshakeStartTimes[deviceId] = DateTime.now();
    _metrics.recordHandshakeStarted();

    // Start handshake timeout using TimePort.delay() with cancellation token
    final token = _CancellationToken();
    _handshakeTimeoutTokens[deviceId] = token;
    unawaited(
      _timePort.delay(_handshakeTimeout).then((_) {
        if (!token.isCancelled) {
          _onHandshakeTimeout(deviceId);
        }
      }),
    );

    // Send handshake with error handling
    final handshakeBytes = _codec.encodeHandshake(_localNodeId);
    unawaited(
      _blePort
          .send(deviceId, handshakeBytes)
          .then((_) {
            _log(LogLevel.debug, 'Sent handshake to $deviceId');
          })
          .catchError((Object error, StackTrace stack) {
            _log(
              LogLevel.error,
              'Failed to send handshake to $deviceId',
              error,
              stack,
            );
            _cleanupPendingHandshake(deviceId);
            _errorController.add(
              HandshakeInvalidError(
                deviceId,
                'Failed to send handshake: $error',
                occurredAt: DateTime.now(),
                cause: error,
              ),
            );
          }),
    );
  }

  void _onHandshakeTimeout(DeviceId deviceId) {
    _log(LogLevel.warning, 'Handshake timeout for $deviceId');

    final event = _registry.cancelPendingHandshake(deviceId, 'Timeout');
    _handshakeStartTimes.remove(deviceId);
    _handshakeTimeoutTokens.remove(deviceId);
    _metrics.recordHandshakeFailed();

    if (event != null) {
      _eventController.add(event);
    }

    _errorController.add(
      HandshakeTimeoutError(
        deviceId,
        'Handshake did not complete within ${_handshakeTimeout.inSeconds}s',
        occurredAt: DateTime.now(),
      ),
    );

    // Disconnect the device since handshake failed
    unawaited(
      _blePort.disconnect(deviceId).catchError((e) {
        _log(LogLevel.warning, 'Failed to disconnect after timeout: $e');
      }),
    );
  }

  /// Cleans up pending handshake state without emitting disconnect event.
  void _cleanupPendingHandshake(DeviceId deviceId) {
    _handshakeTimeoutTokens.remove(deviceId)?.cancel();
    _handshakeStartTimes.remove(deviceId);
    _registry.cancelPendingHandshake(deviceId, 'Cleanup');
    _metrics.recordHandshakeFailed();
  }

  void _onBytesReceived(DeviceId deviceId, Uint8List bytes) {
    if (bytes.isEmpty) return;

    _metrics.recordBytesReceived(bytes.length);
    final messageType = _codec.getMessageType(bytes);

    switch (messageType) {
      case MessageType.handshake:
        _handleHandshakeMessage(deviceId, bytes);
      case MessageType.gossip:
        _handleGossipMessage(deviceId, bytes);
      default:
        _log(
          LogLevel.warning,
          'Unknown message type: $messageType from $deviceId',
        );
    }
  }

  void _handleHandshakeMessage(DeviceId deviceId, Uint8List bytes) {
    // Cancel the timeout since we received a handshake response
    _handshakeTimeoutTokens.remove(deviceId)?.cancel();

    final remoteNodeId = _codec.decodeHandshake(bytes);
    if (remoteNodeId == null) {
      _log(LogLevel.error, 'Invalid handshake from $deviceId');
      _handshakeStartTimes.remove(deviceId);
      _registry.cancelPendingHandshake(deviceId, 'Invalid handshake');
      _metrics.recordHandshakeFailed();
      _errorController.add(
        HandshakeInvalidError(
          deviceId,
          'Failed to decode handshake message',
          occurredAt: DateTime.now(),
        ),
      );
      return;
    }

    final startTime = _handshakeStartTimes.remove(deviceId);
    final duration = startTime != null
        ? DateTime.now().difference(startTime)
        : Duration.zero;

    final event = _registry.completeHandshake(deviceId, remoteNodeId);
    _metrics.recordHandshakeCompleted(duration);
    _log(
      LogLevel.info,
      'Handshake completed with $remoteNodeId (${duration.inMilliseconds}ms)',
    );
    _eventController.add(event);
  }

  void _handleGossipMessage(DeviceId deviceId, Uint8List bytes) {
    final nodeId = _registry.getNodeIdForDevice(deviceId);
    if (nodeId == null) {
      _log(LogLevel.warning, 'Gossip message from unknown device: $deviceId');
      return;
    }

    final payload = _codec.unwrapGossip(bytes);
    if (payload == null) {
      _log(LogLevel.warning, 'Failed to unwrap gossip message from $deviceId');
      return;
    }

    _log(
      LogLevel.trace,
      'Gossip message from $nodeId: ${payload.length} bytes',
    );
    onGossipMessage?.call(nodeId, payload);
  }

  void _onDisconnected(DeviceId deviceId) {
    _log(LogLevel.info, 'Disconnected: $deviceId');

    // Cancel any pending handshake timeout
    _handshakeTimeoutTokens.remove(deviceId)?.cancel();

    // Clean up pending handshake if any
    if (_handshakeStartTimes.remove(deviceId) != null) {
      _metrics.recordHandshakeFailed();
    }
    _registry.cancelPendingHandshake(deviceId, 'Disconnected');

    // Remove connection and emit event
    final event = _registry.removeConnection(deviceId, 'Disconnected');
    if (event != null) {
      _metrics.recordDisconnection();
      _eventController.add(event);
    }
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
