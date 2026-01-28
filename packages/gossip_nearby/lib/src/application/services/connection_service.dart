import 'dart:async' show StreamController, StreamSubscription, unawaited;
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

import '../../domain/aggregates/connection_registry.dart';
import '../../domain/events/connection_event.dart';
import '../../domain/interfaces/nearby_port.dart';
import '../../domain/value_objects/endpoint.dart';
import '../../domain/value_objects/endpoint_id.dart';
import '../../infrastructure/codec/handshake_codec.dart';
import '../observability/log_level.dart';
import '../observability/nearby_metrics.dart';

/// Callback for receiving gossip messages.
typedef GossipMessageCallback = void Function(NodeId sender, Uint8List bytes);

/// Application service coordinating connection lifecycle and handshakes.
///
/// Responsibilities:
/// - Listens to NearbyPort events and orchestrates responses
/// - Manages handshake protocol (send/receive NodeIds)
/// - Forwards gossip messages to/from the domain
/// - Emits domain events for connection state changes
class ConnectionService {
  final NodeId _localNodeId;
  final NearbyPort _nearbyPort;
  final ConnectionRegistry _registry;
  final HandshakeCodec _codec;
  final NearbyMetrics _metrics;
  final LogCallback? _onLog;

  final _eventController = StreamController<ConnectionEvent>.broadcast();
  StreamSubscription<NearbyEvent>? _nearbySubscription;

  /// Tracks when handshakes started for duration calculation.
  final Map<EndpointId, DateTime> _handshakeStartTimes = {};

  /// Callback invoked when a gossip message is received from a connected peer.
  GossipMessageCallback? onGossipMessage;

  ConnectionService({
    required NodeId localNodeId,
    required NearbyPort nearbyPort,
    required ConnectionRegistry registry,
    HandshakeCodec codec = const HandshakeCodec(),
    NearbyMetrics? metrics,
    LogCallback? onLog,
  }) : _localNodeId = localNodeId,
       _nearbyPort = nearbyPort,
       _registry = registry,
       _codec = codec,
       _metrics = metrics ?? NearbyMetrics(),
       _onLog = onLog {
    _nearbySubscription = _nearbyPort.events.listen(_handleNearbyEvent);
  }

  /// Stream of connection events (HandshakeCompleted, ConnectionClosed, etc.)
  Stream<ConnectionEvent> get events => _eventController.stream;

  /// Metrics for this service.
  NearbyMetrics get metrics => _metrics;

  /// Sends a gossip message to the specified peer.
  Future<void> sendGossipMessage(NodeId destination, Uint8List bytes) async {
    final endpointId = _registry.getEndpointIdForNodeId(destination);
    if (endpointId == null) {
      _log(LogLevel.warning, 'Cannot send: no connection for $destination');
      return;
    }

    final wrapped = _codec.wrapGossipMessage(bytes);
    await _nearbyPort.sendPayload(endpointId, wrapped);
    _metrics.recordBytesSent(wrapped.length);
    _log(LogLevel.trace, 'Sent ${wrapped.length} bytes to $destination');
  }

  /// Disposes resources.
  Future<void> dispose() async {
    await _nearbySubscription?.cancel();
    await _eventController.close();
  }

  void _handleNearbyEvent(NearbyEvent event) {
    switch (event) {
      case EndpointDiscovered(:final id, :final displayName):
        _onEndpointDiscovered(id, displayName);
      case ConnectionEstablished(:final id):
        _onConnectionEstablished(id);
      case PayloadReceived(:final id, :final bytes):
        _onPayloadReceived(id, bytes);
      case Disconnected(:final id):
        _onDisconnected(id);
    }
  }

  void _onEndpointDiscovered(EndpointId id, String displayName) {
    _log(LogLevel.debug, 'Endpoint discovered: $id ($displayName)');
    // Automatically request connection to discovered endpoints
    unawaited(_nearbyPort.requestConnection(id));
  }

  void _onConnectionEstablished(EndpointId id) {
    _log(LogLevel.info, 'Connection established: $id');
    _metrics.recordConnectionEstablished();

    // Register pending handshake and send our NodeId
    _registry.registerPendingHandshake(id);
    _handshakeStartTimes[id] = DateTime.now();
    _metrics.recordHandshakeStarted();

    final handshakeBytes = _codec.encode(_localNodeId);
    unawaited(_nearbyPort.sendPayload(id, handshakeBytes));
    _log(LogLevel.debug, 'Sent handshake to $id');
  }

  void _onPayloadReceived(EndpointId id, Uint8List bytes) {
    if (bytes.isEmpty) return;

    _metrics.recordBytesReceived(bytes.length);
    _log(LogLevel.trace, 'Received ${bytes.length} bytes from $id');

    final messageType = bytes[0];

    if (messageType == MessageType.handshake) {
      _handleHandshakeMessage(id, bytes);
    } else if (messageType == MessageType.gossip) {
      _handleGossipMessage(id, bytes);
    } else {
      _log(LogLevel.warning, 'Unknown message type: $messageType from $id');
    }
  }

  void _handleHandshakeMessage(EndpointId id, Uint8List bytes) {
    final remoteNodeId = _codec.decode(bytes);
    if (remoteNodeId == null) {
      _log(LogLevel.error, 'Invalid handshake from $id');
      _metrics.recordHandshakeFailed();
      _handshakeStartTimes.remove(id);
      return;
    }

    final startTime = _handshakeStartTimes.remove(id);
    final duration = startTime != null
        ? DateTime.now().difference(startTime)
        : Duration.zero;

    final endpoint = Endpoint(id: id, displayName: '');
    final event = _registry.completeHandshake(endpoint, remoteNodeId);

    _metrics.recordHandshakeCompleted(duration);
    _log(
      LogLevel.info,
      'Handshake completed with $remoteNodeId (${duration.inMilliseconds}ms)',
    );

    _eventController.add(event);
  }

  void _handleGossipMessage(EndpointId id, Uint8List bytes) {
    final nodeId = _registry.getNodeIdForEndpoint(id);
    if (nodeId == null) {
      _log(LogLevel.warning, 'Gossip message from unknown endpoint: $id');
      return;
    }

    final payload = _codec.unwrapGossipMessage(bytes);
    if (payload == null) {
      _log(LogLevel.warning, 'Failed to unwrap gossip message from $id');
      return;
    }

    _log(
      LogLevel.trace,
      'Gossip message from $nodeId: ${payload.length} bytes',
    );
    onGossipMessage?.call(nodeId, payload);
  }

  void _onDisconnected(EndpointId id) {
    _log(LogLevel.info, 'Disconnected: $id');

    // Clean up any pending handshake
    if (_handshakeStartTimes.remove(id) != null) {
      _metrics.recordHandshakeFailed();
    }

    final event = _registry.removeConnection(id, 'Disconnected');
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
