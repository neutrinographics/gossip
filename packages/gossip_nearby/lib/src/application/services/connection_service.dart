import 'dart:async'
    show Completer, StreamController, StreamSubscription, unawaited;
import 'dart:collection' show Queue;
import 'dart:math' show Random;
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

/// A queued message waiting to be sent.
class _QueuedMessage {
  final EndpointId endpointId;
  final NodeId destination;
  final Uint8List bytes;
  final Completer<void> completer;

  _QueuedMessage({
    required this.endpointId,
    required this.destination,
    required this.bytes,
  }) : completer = Completer<void>();
}

/// Tracks a discovered-but-not-connected endpoint for retry logic.
class _PendingDiscovery {
  final EndpointId endpointId;
  final String advertisedName;
  final int discoveredAtMs;

  _PendingDiscovery({
    required this.endpointId,
    required this.advertisedName,
    required this.discoveredAtMs,
  });
}

/// Application service coordinating connection lifecycle and handshakes.
///
/// Responsibilities:
/// - Listens to NearbyPort events and orchestrates responses
/// - Manages handshake protocol (send/receive NodeIds)
/// - Forwards gossip messages to/from the domain
/// - Emits domain events for connection state changes
class ConnectionService {
  final NodeId _localNodeId;
  final String? _displayName;
  final NearbyPort _nearbyPort;
  final ConnectionRegistry _registry;
  final HandshakeCodec _codec;
  final NearbyMetrics _metrics;
  final LogCallback? _onLog;
  final TimePort _timePort;
  final Random _random;

  final Duration _connectionTimeout;
  final _eventController = StreamController<ConnectionEvent>.broadcast();
  final _errorController = StreamController<ConnectionError>.broadcast();
  StreamSubscription<NearbyEvent>? _nearbySubscription;

  final Map<EndpointId, DateTime> _handshakeStartTimes = {};
  final Map<EndpointId, _PendingDiscovery> _pendingDiscoveries = {};
  bool _disposed = false;

  /// High-priority message queue (SWIM pings/acks).
  final Queue<_QueuedMessage> _highPriorityQueue = Queue<_QueuedMessage>();

  /// Normal-priority message queue (gossip messages).
  final Queue<_QueuedMessage> _normalPriorityQueue = Queue<_QueuedMessage>();

  /// Whether the queue processor is currently running.
  bool _isProcessingQueue = false;

  /// Callback invoked when a gossip message is received from a connected peer.
  GossipMessageCallback? onGossipMessage;

  ConnectionService({
    required NodeId localNodeId,
    String? displayName,
    required NearbyPort nearbyPort,
    required ConnectionRegistry registry,
    HandshakeCodec codec = const HandshakeCodec(),
    NearbyMetrics? metrics,
    LogCallback? onLog,
    TimePort? timePort,
    Duration connectionTimeout = const Duration(seconds: 5),
    Random? random,
  }) : _localNodeId = localNodeId,
       _displayName = displayName,
       _nearbyPort = nearbyPort,
       _registry = registry,
       _codec = codec,
       _metrics = metrics ?? NearbyMetrics(),
       _onLog = onLog,
       _timePort = timePort ?? RealTimePort(),
       _connectionTimeout = connectionTimeout,
       _random = random ?? Random() {
    _nearbySubscription = _nearbyPort.events.listen(_handleNearbyEvent);
    _scheduleNextRetry();
  }

  /// Stream of connection events (HandshakeCompleted, ConnectionClosed, etc.)
  Stream<ConnectionEvent> get events => _eventController.stream;

  /// Stream of connection errors for observability.
  Stream<ConnectionError> get errors => _errorController.stream;

  /// Metrics for this service.
  NearbyMetrics get metrics => _metrics;

  /// Sends a gossip message to the specified peer.
  ///
  /// Messages are queued by priority. High-priority messages (SWIM pings/acks)
  /// are processed before normal-priority messages (gossip data) to ensure
  /// failure detection isn't delayed during congestion.
  Future<void> sendGossipMessage(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  }) async {
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

    final wrapped = _codec.wrapGossipMessage(bytes);
    final message = _QueuedMessage(
      endpointId: endpointId,
      destination: destination,
      bytes: wrapped,
    );

    // Add to appropriate queue based on priority
    if (priority == MessagePriority.high) {
      _highPriorityQueue.add(message);
    } else {
      _normalPriorityQueue.add(message);
    }

    // Start processing if not already running
    unawaited(_processQueues());

    // Wait for this message to be sent
    return message.completer.future;
  }

  /// Returns the number of messages waiting to be sent to a specific peer.
  int pendingSendCount(NodeId peer) {
    final endpointId = _registry.getEndpointIdForNodeId(peer);
    if (endpointId == null) return 0;

    var count = 0;
    for (final msg in _highPriorityQueue) {
      if (msg.endpointId == endpointId) count++;
    }
    for (final msg in _normalPriorityQueue) {
      if (msg.endpointId == endpointId) count++;
    }
    return count;
  }

  /// Returns the total number of messages waiting to be sent across all peers.
  int get totalPendingSendCount =>
      _highPriorityQueue.length + _normalPriorityQueue.length;

  /// Processes queued messages, prioritizing high-priority messages.
  Future<void> _processQueues() async {
    if (_isProcessingQueue) return;
    _isProcessingQueue = true;

    try {
      while (_highPriorityQueue.isNotEmpty || _normalPriorityQueue.isNotEmpty) {
        // Always process high-priority messages first
        final message = _highPriorityQueue.isNotEmpty
            ? _highPriorityQueue.removeFirst()
            : _normalPriorityQueue.removeFirst();

        await _sendQueuedMessage(message);
      }
    } finally {
      _isProcessingQueue = false;
    }
  }

  /// Sends a single queued message and completes its future.
  Future<void> _sendQueuedMessage(_QueuedMessage message) async {
    try {
      await _nearbyPort.sendPayload(message.endpointId, message.bytes);
      _metrics.recordBytesSent(message.bytes.length);
      _log(
        LogLevel.trace,
        'Sent ${message.bytes.length} bytes to ${message.destination}',
      );
      message.completer.complete();
    } catch (e, stack) {
      _log(LogLevel.error, 'Send failed to ${message.destination}', e, stack);
      _errorController.add(
        SendFailedError(
          message.destination,
          'Failed to send payload: $e',
          occurredAt: DateTime.now(),
          cause: e,
        ),
      );
      message.completer.completeError(e, stack);
    }
  }

  /// Disposes resources.
  Future<void> dispose() async {
    _disposed = true;
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
      case EndpointLost(:final id):
        _onEndpointLost(id);
      case ConnectionFailed(:final id):
        _onConnectionFailed(id);
      case Disconnected(:final id):
        _onDisconnected(id);
    }
  }

  void _onEndpointDiscovered(EndpointId id, String advertisedName) {
    _log(LogLevel.debug, 'Endpoint discovered: $id ($advertisedName)');

    // Skip if this is our own advertisement (self-discovery)
    final remoteNodeId = _parseNodeId(advertisedName);
    if (remoteNodeId != null) {
      if (remoteNodeId == _localNodeId.value) {
        _log(LogLevel.debug, 'Ignoring own advertisement: $id');
        return;
      }

      // Skip if we're already connected to this NodeId
      final existingEndpoint = _registry.getEndpointIdForNodeId(
        NodeId(remoteNodeId),
      );
      if (existingEndpoint != null) {
        _log(
          LogLevel.debug,
          'Already connected to $remoteNodeId via $existingEndpoint, '
          'ignoring discovery of $id',
        );
        return;
      }
    }

    // Track for retry logic
    _pendingDiscoveries[id] = _PendingDiscovery(
      endpointId: id,
      advertisedName: advertisedName,
      discoveredAtMs: _timePort.nowMs,
    );

    if (_shouldInitiateConnection(advertisedName)) {
      _log(LogLevel.debug, 'Initiating connection (we have smaller nodeId)');
      _requestConnectionSafely(id);
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
    _pendingDiscoveries.remove(id);

    // Register pending handshake and send our NodeId
    _registry.registerPendingHandshake(id);
    _handshakeStartTimes[id] = DateTime.now();
    _metrics.recordHandshakeStarted();

    final handshakeBytes = _codec.encode(
      _localNodeId,
      displayName: _displayName,
    );
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
    final handshakeData = _codec.decode(bytes);
    if (handshakeData == null) {
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

    final endpoint = Endpoint(
      id: id,
      displayName: handshakeData.displayName ?? '',
    );
    final replaced = _registry.completeHandshake(
      endpoint,
      handshakeData.nodeId,
    );

    // Disconnect old endpoint to avoid loose ends on the remote device
    if (replaced != null) {
      _log(
        LogLevel.info,
        'Duplicate connection for ${handshakeData.nodeId}: '
        'disconnecting old endpoint ${replaced.endpointId}',
      );
      _handshakeStartTimes.remove(replaced.endpointId);
      _pendingDiscoveries.remove(replaced.endpointId);
      unawaited(_nearbyPort.disconnect(replaced.endpointId));
    }

    final event = HandshakeCompleted(
      endpoint: endpoint,
      nodeId: handshakeData.nodeId,
      displayName: handshakeData.displayName,
    );

    _metrics.recordHandshakeCompleted(duration);
    _log(
      LogLevel.info,
      'Handshake completed with ${handshakeData.nodeId} '
      '(displayName: ${handshakeData.displayName}, ${duration.inMilliseconds}ms)',
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

  /// Schedules the next retry check with a jittered interval.
  ///
  /// Uses self-scheduling via [TimePort.delay] (not periodic timer) so each
  /// tick gets a freshly randomized interval. This decorrelates retry timers
  /// across devices, preventing synchronized `requestConnection()` collisions
  /// that cause both sides to fail indefinitely.
  void _scheduleNextRetry() {
    if (_disposed) return;
    _timePort.delay(_jitteredTimeout()).then((_) {
      if (!_disposed) {
        _retryPendingConnections();
        _scheduleNextRetry();
      }
    });
  }

  /// Returns the connection timeout with ±30% random jitter.
  ///
  /// With a 5s base timeout, this produces intervals between 3.5s and 6.5s.
  Duration _jitteredTimeout() {
    // nextDouble() returns [0.0, 1.0) → scale to [0.7, 1.3)
    final multiplier = 0.7 + _random.nextDouble() * 0.6;
    final jitteredMs = (_connectionTimeout.inMilliseconds * multiplier).round();
    return Duration(milliseconds: jitteredMs);
  }

  void _requestConnectionSafely(EndpointId id) {
    unawaited(
      _nearbyPort.requestConnection(id).catchError((e, stack) {
        _log(LogLevel.warning, 'requestConnection failed for $id', e, stack);
      }),
    );
  }

  void _retryPendingConnections() {
    if (_pendingDiscoveries.isEmpty) return;

    final nowMs = _timePort.nowMs;
    final timeoutMs = _connectionTimeout.inMilliseconds;
    for (final pending in _pendingDiscoveries.values) {
      final ageMs = nowMs - pending.discoveredAtMs;
      if (ageMs >= timeoutMs) {
        _log(
          LogLevel.debug,
          'Retrying connection to ${pending.endpointId} '
          '(pending for ${ageMs ~/ 1000}s)',
        );
        _requestConnectionSafely(pending.endpointId);
      }
    }
  }

  void _onEndpointLost(EndpointId id) {
    _log(LogLevel.debug, 'Endpoint lost: $id');
    _pendingDiscoveries.remove(id);
  }

  void _onConnectionFailed(EndpointId id) {
    _log(LogLevel.info, 'Connection failed for endpoint: $id');
    _metrics.recordConnectionFailed();
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
