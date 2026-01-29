import 'dart:async';
import 'dart:developer' as developer;

import 'package:gossip/gossip.dart';
import 'package:gossip_nearby/gossip_nearby.dart';

/// Service for logging all metrics, events, and errors from gossip and gossip_nearby.
///
/// This provides comprehensive observability for debugging the chat application.
class DebugLogger {
  final Coordinator _coordinator;
  final NearbyTransport _transport;

  StreamSubscription<DomainEvent>? _domainEventSubscription;
  StreamSubscription<SyncError>? _syncErrorSubscription;
  StreamSubscription<ConnectionError>? _connectionErrorSubscription;
  StreamSubscription<PeerEvent>? _peerEventSubscription;
  Timer? _metricsTimer;

  DebugLogger({
    required Coordinator coordinator,
    required NearbyTransport transport,
  }) : _coordinator = coordinator,
       _transport = transport;

  /// Starts logging all events, errors, and metrics.
  void start() {
    _log('DEBUG', 'DebugLogger started');

    // Subscribe to Coordinator domain events
    _domainEventSubscription = _coordinator.events.listen(_onDomainEvent);

    // Subscribe to Coordinator sync errors
    _syncErrorSubscription = _coordinator.errors.listen(_onSyncError);

    // Subscribe to NearbyTransport connection errors
    _connectionErrorSubscription = _transport.errors.listen(_onConnectionError);

    // Subscribe to NearbyTransport peer events
    _peerEventSubscription = _transport.peerEvents.listen(_onPeerEvent);

    // Start periodic metrics logging
    _metricsTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _logMetrics();
    });

    // Log initial state
    _logMetrics();
  }

  /// Stops logging and releases resources.
  void stop() {
    _domainEventSubscription?.cancel();
    _syncErrorSubscription?.cancel();
    _connectionErrorSubscription?.cancel();
    _peerEventSubscription?.cancel();
    _metricsTimer?.cancel();
    _log('DEBUG', 'DebugLogger stopped');
  }

  // ─────────────────────────────────────────────────────────────
  // Domain Events (Coordinator)
  // ─────────────────────────────────────────────────────────────

  void _onDomainEvent(DomainEvent event) {
    final timestamp = _formatTime(event.occurredAt);
    switch (event) {
      // Peer events
      case PeerAdded(:final peerId):
        _log('PEER', '[$timestamp] Peer added: $peerId');
      case PeerRemoved(:final peerId):
        _log('PEER', '[$timestamp] Peer removed: $peerId');
      case PeerStatusChanged(:final peerId, :final oldStatus, :final newStatus):
        _log(
          'PEER',
          '[$timestamp] Peer status changed: $peerId $oldStatus -> $newStatus',
        );
      case PeerOperationSkipped(:final peerId, :final operation):
        _log(
          'PEER',
          '[$timestamp] Peer operation skipped: $peerId - $operation',
        );

      // Channel events
      case ChannelCreated(:final channelId):
        _log(
          'CHANNEL',
          '[$timestamp] Channel created: ${_shortId(channelId.value)}',
        );
      case ChannelRemoved(:final channelId):
        _log(
          'CHANNEL',
          '[$timestamp] Channel removed: ${_shortId(channelId.value)}',
        );
      case MemberAdded(:final channelId, :final memberId):
        _log(
          'CHANNEL',
          '[$timestamp] Member added to ${_shortId(channelId.value)}: $memberId',
        );
      case MemberRemoved(:final channelId, :final memberId):
        _log(
          'CHANNEL',
          '[$timestamp] Member removed from ${_shortId(channelId.value)}: $memberId',
        );

      // Stream events
      case StreamCreated(:final channelId, :final streamId):
        _log(
          'STREAM',
          '[$timestamp] Stream created: ${_shortId(channelId.value)}/${streamId.value}',
        );
      case EntryAppended(:final channelId, :final streamId, :final entry):
        _log(
          'SYNC',
          '[$timestamp] Entry appended: ${_shortId(channelId.value)}/${streamId.value} '
              'author=${_shortId(entry.author.value)} seq=${entry.sequence}',
        );
      case EntriesMerged(:final channelId, :final streamId, :final entries):
        _log(
          'SYNC',
          '[$timestamp] Entries merged: ${_shortId(channelId.value)}/${streamId.value} '
              'count=${entries.length}',
        );
      case StreamCompacted(:final channelId, :final streamId, :final result):
        _log(
          'SYNC',
          '[$timestamp] Stream compacted: ${_shortId(channelId.value)}/${streamId.value} '
              'removed=${result.entriesRemoved}',
        );

      // Buffer events
      case BufferOverflowOccurred(
        :final channelId,
        :final streamId,
        :final author,
        :final droppedCount,
      ):
        _log(
          'WARN',
          '[$timestamp] Buffer overflow: ${_shortId(channelId.value)}/${streamId.value} '
              'author=$author dropped=$droppedCount',
        );
      case NonMemberEntriesRejected(
        :final channelId,
        :final streamId,
        :final rejectedCount,
        :final unknownAuthors,
      ):
        _log(
          'WARN',
          '[$timestamp] Non-member entries rejected: ${_shortId(channelId.value)}/${streamId.value} '
              'count=$rejectedCount authors=$unknownAuthors',
        );

      // Error events
      case SyncErrorOccurred(:final error):
        _logSyncError(error, timestamp);
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Sync Errors (Coordinator)
  // ─────────────────────────────────────────────────────────────

  void _onSyncError(SyncError error) {
    _logSyncError(error, _formatTime(error.occurredAt));
  }

  void _logSyncError(SyncError error, String timestamp) {
    switch (error) {
      case PeerSyncError(:final peer, :final type, :final message):
        _log(
          'ERROR',
          '[$timestamp] Peer sync error: peer=$peer type=$type msg=$message',
        );
      case ChannelSyncError(:final channel, :final type, :final message):
        _log(
          'ERROR',
          '[$timestamp] Channel sync error: channel=${_shortId(channel.value)} type=$type msg=$message',
        );
      case StorageSyncError(:final type, :final message):
        _log(
          'ERROR',
          '[$timestamp] Storage sync error: type=$type msg=$message',
        );
      case TransformSyncError(:final channel, :final message):
        _log(
          'ERROR',
          '[$timestamp] Transform sync error: channel=${channel != null ? _shortId(channel.value) : 'null'} msg=$message',
        );
      case BufferOverflowError(
        :final channel,
        :final stream,
        :final author,
        :final bufferSize,
        :final message,
      ):
        _log(
          'ERROR',
          '[$timestamp] Buffer overflow error: ${_shortId(channel.value)}/${stream.value} '
              'author=$author bufferSize=$bufferSize msg=$message',
        );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Connection Errors (NearbyTransport)
  // ─────────────────────────────────────────────────────────────

  void _onConnectionError(ConnectionError error) {
    final timestamp = _formatTime(error.occurredAt);
    switch (error) {
      case ConnectionNotFoundError(:final nodeId):
        _log(
          'NEARBY',
          '[$timestamp] Connection not found: $nodeId - ${error.message}',
        );
      case HandshakeTimeoutError(:final endpointId):
        _log(
          'NEARBY',
          '[$timestamp] Handshake timeout: $endpointId - ${error.message}',
        );
      case HandshakeInvalidError(:final endpointId):
        _log(
          'NEARBY',
          '[$timestamp] Handshake invalid: $endpointId - ${error.message}',
        );
      case SendFailedError(:final nodeId):
        _log('NEARBY', '[$timestamp] Send failed: $nodeId - ${error.message}');
      case ConnectionLostError(:final nodeId):
        _log(
          'NEARBY',
          '[$timestamp] Connection lost: $nodeId - ${error.message}',
        );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Peer Events (NearbyTransport)
  // ─────────────────────────────────────────────────────────────

  void _onPeerEvent(PeerEvent event) {
    switch (event) {
      case PeerConnected(:final nodeId):
        _log('NEARBY', 'Peer connected: ${_shortId(nodeId.value)}');
      case PeerDisconnected(:final nodeId):
        _log('NEARBY', 'Peer disconnected: ${_shortId(nodeId.value)}');
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Metrics Logging
  // ─────────────────────────────────────────────────────────────

  void _logMetrics() {
    _logCoordinatorMetrics();
    _logNearbyMetrics();
    _logPeerMetrics();
  }

  Future<void> _logCoordinatorMetrics() async {
    try {
      final health = await _coordinator.getHealth();
      final usage = await _coordinator.getResourceUsage();

      _log('METRICS', '=== Coordinator Health ===');
      _log('METRICS', '  State: ${health.state}');
      _log('METRICS', '  Local node: ${_shortId(health.localNode.value)}');
      _log('METRICS', '  Incarnation: ${health.incarnation}');
      _log('METRICS', '  Is healthy: ${health.isHealthy}');
      _log('METRICS', '  Reachable peers: ${health.reachablePeerCount}');
      _log('METRICS', '=== Resource Usage ===');
      _log('METRICS', '  Peers: ${usage.peerCount}');
      _log('METRICS', '  Channels: ${usage.channelCount}');
      _log('METRICS', '  Total entries: ${usage.totalEntries}');
      _log(
        'METRICS',
        '  Total storage: ${_formatBytes(usage.totalStorageBytes)}',
      );
    } catch (e) {
      _log('METRICS', 'Failed to get coordinator metrics: $e');
    }
  }

  void _logNearbyMetrics() {
    final metrics = _transport.metrics;
    _log('METRICS', '=== Nearby Transport Metrics ===');
    _log('METRICS', '  Connected peers: ${metrics.connectedPeerCount}');
    _log('METRICS', '  Pending handshakes: ${metrics.pendingHandshakeCount}');
    _log(
      'METRICS',
      '  Connections established: ${metrics.totalConnectionsEstablished}',
    );
    _log('METRICS', '  Connections failed: ${metrics.totalConnectionsFailed}');
    _log('METRICS', '  Messages sent: ${metrics.totalMessagesSent}');
    _log('METRICS', '  Messages received: ${metrics.totalMessagesReceived}');
    _log('METRICS', '  Bytes sent: ${_formatBytes(metrics.totalBytesSent)}');
    _log(
      'METRICS',
      '  Bytes received: ${_formatBytes(metrics.totalBytesReceived)}',
    );
    _log(
      'METRICS',
      '  Avg handshake duration: ${metrics.averageHandshakeDuration.inMilliseconds}ms',
    );
    _log('METRICS', '  Is advertising: ${_transport.isAdvertising}');
    _log('METRICS', '  Is discovering: ${_transport.isDiscovering}');
  }

  void _logPeerMetrics() {
    final peers = _coordinator.peers;
    if (peers.isEmpty) {
      _log('METRICS', '=== Peer Metrics ===');
      _log('METRICS', '  No peers registered');
      return;
    }

    _log('METRICS', '=== Peer Metrics (${peers.length} peers) ===');
    for (final peer in peers) {
      final metrics = _coordinator.getPeerMetrics(peer.id);
      _log('METRICS', '  Peer ${_shortId(peer.id.value)}:');
      _log('METRICS', '    Status: ${peer.status}');
      _log('METRICS', '    Incarnation: ${peer.incarnation ?? 'unknown'}');
      _log('METRICS', '    Failed probe count: ${peer.failedProbeCount}');
      if (metrics != null) {
        _log('METRICS', '    Messages sent: ${metrics.messagesSent}');
        _log('METRICS', '    Messages received: ${metrics.messagesReceived}');
        _log('METRICS', '    Bytes sent: ${_formatBytes(metrics.bytesSent)}');
        _log(
          'METRICS',
          '    Bytes received: ${_formatBytes(metrics.bytesReceived)}',
        );
      }
    }
  }

  /// Logs a message to the console with a category prefix.
  void _log(String category, String message) {
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}.'
        '${now.millisecond.toString().padLeft(3, '0')}';

    final logLine = '[$time][$category] $message';

    // Print to console
    // ignore: avoid_print
    print(logLine);

    // Also log to developer tools (visible in DevTools)
    developer.log(message, name: 'gossip.$category');
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
  }

  String _shortId(String id) {
    return id.length > 8 ? id.substring(0, 8) : id;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// LogCallback implementation for NearbyTransport that prints to console.
void nearbyLogCallback(
  LogLevel level,
  String message, [
  Object? error,
  StackTrace? stackTrace,
]) {
  final now = DateTime.now();
  final time =
      '${now.hour.toString().padLeft(2, '0')}:'
      '${now.minute.toString().padLeft(2, '0')}:'
      '${now.second.toString().padLeft(2, '0')}.'
      '${now.millisecond.toString().padLeft(3, '0')}';

  final levelStr = level.name.toUpperCase().padRight(7);
  var logLine = '[$time][NEARBY][$levelStr] $message';

  if (error != null) {
    logLine += ' | Error: $error';
  }

  // Print to console
  // ignore: avoid_print
  print(logLine);

  // Log to developer tools
  developer.log(
    message,
    name: 'gossip.nearby.${level.name}',
    error: error,
    stackTrace: stackTrace,
  );
}
