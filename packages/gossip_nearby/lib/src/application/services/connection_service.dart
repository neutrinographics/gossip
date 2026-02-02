import 'dart:async' show StreamController, StreamSubscription, unawaited;
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

import '../../domain/aggregates/connection_registry.dart';
import '../../domain/errors/connection_error.dart';
import '../../domain/events/connection_event.dart';
import '../../domain/interfaces/nearby_port.dart';
import '../../domain/value_objects/endpoint.dart';
import '../../domain/value_objects/endpoint_id.dart';
import '../../infrastructure/codec/handshake_codec.dart'
    show HandshakeCodec, MessageType, WireFormat;
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
  final _errorController = StreamController<ConnectionError>.broadcast();
  StreamSubscription<NearbyEvent>? _nearbySubscription;

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

  /// Stream of connection errors for observability.
  Stream<ConnectionError> get errors => _errorController.stream;

  /// Metrics for this service.
  NearbyMetrics get metrics => _metrics;

  /// Sends a gossip message to the specified peer.
  Future<void> sendGossipMessage(NodeId destination, Uint8List bytes) async {
    final endpointId = _registry.getEndpointIdForNodeId(destination);
    if (endpointId == null) {
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
      final wrapped = _codec.wrapGossipMessage(bytes);
      await _nearbyPort.sendPayload(endpointId, wrapped);
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
    await _nearbySubscription?.cancel();
    await _eventController.close();
    await _errorController.close();
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

  void _onEndpointDiscovered(EndpointId id, String advertisedName) {
    _log(LogLevel.debug, 'Endpoint discovered: $id ($advertisedName)');

    if (_shouldInitiateConnection(advertisedName)) {
      _log(LogLevel.debug, 'Initiating connection (we have smaller nodeId)');
      unawaited(_nearbyPort.requestConnection(id));
    } else {
      _log(LogLevel.debug, 'Waiting for connection (they have smaller nodeId)');
    }
  }

  /// Determines if this device should initiate the connection.
  ///
  /// When two devices discover each other simultaneously, both would try
  /// to connect, causing race conditions. To avoid this, only the device
  /// with the lexicographically smaller nodeId initiates the connection.
  ///
  /// The remote nodeId is encoded in the advertised name (format: "nodeId|displayName").
  bool _shouldInitiateConnection(String advertisedName) {
    final remoteNodeId = _parseNodeId(advertisedName);
    if (remoteNodeId == null) {
      _log(LogLevel.warning, 'Cannot parse nodeId from: $advertisedName');
      return true; // Fall back to initiating connection
    }
    return _localNodeId.value.compareTo(remoteNodeId) < 0;
  }

  /// Parses the nodeId from an advertised name (format: "nodeId|displayName").
  String? _parseNodeId(String advertisedName) {
    final separatorIndex = advertisedName.indexOf('|');
    if (separatorIndex == -1) return null;
    return advertisedName.substring(0, separatorIndex);
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

  // Track message counts for diagnostics
  int _totalMessagesReceived = 0;
  int _handshakeMessagesReceived = 0;
  int _gossipMessagesReceived = 0;
  DateTime? _lastMessageTime;

  void _onPayloadReceived(EndpointId id, Uint8List bytes) {
    if (bytes.isEmpty) return;

    final now = DateTime.now();
    _totalMessagesReceived++;

    // Diagnostic: detect gaps in message flow
    if (_lastMessageTime != null) {
      final gap = now.difference(_lastMessageTime!);
      if (gap.inSeconds > 2) {
        _log(
          LogLevel.warning,
          'DIAGNOSTIC: Message gap of ${gap.inMilliseconds}ms detected '
          '(total messages: $_totalMessagesReceived, '
          'handshakes: $_handshakeMessagesReceived, '
          'gossip: $_gossipMessagesReceived)',
        );
      }
    }
    _lastMessageTime = now;

    _metrics.recordBytesReceived(bytes.length);
    final messageType = bytes[WireFormat.typeOffset];
    _log(
      LogLevel.trace,
      'Received ${bytes.length} bytes from $id (type: 0x${messageType.toRadixString(16)})',
    );

    switch (messageType) {
      case MessageType.handshake:
        _handshakeMessagesReceived++;
        _handleHandshakeMessage(id, bytes);
      case MessageType.gossip:
        _gossipMessagesReceived++;
        _handleGossipMessage(id, bytes);
      default:
        _log(LogLevel.warning, 'Unknown message type: $messageType from $id');
    }
  }

  void _handleHandshakeMessage(EndpointId id, Uint8List bytes) {
    final remoteNodeId = _codec.decode(bytes);
    if (remoteNodeId == null) {
      _log(LogLevel.error, 'Invalid handshake from $id');
      _metrics.recordHandshakeFailed();
      _handshakeStartTimes.remove(id);
      _errorController.add(
        HandshakeInvalidError(
          id,
          'Failed to decode handshake message',
          occurredAt: DateTime.now(),
        ),
      );
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
