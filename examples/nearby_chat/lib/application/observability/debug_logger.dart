import 'dart:async';
import 'dart:developer' as developer;

import 'package:gossip/gossip.dart';
import 'package:gossip_nearby/gossip_nearby.dart';

import '../services/connection_service.dart';
import '../services/sync_service.dart';
import 'log_format.dart';

/// Controls what gets logged to the console.
enum DebugLogLevel {
  /// Only errors are logged.
  error,

  /// Errors and warnings are logged.
  warning,

  /// Errors, warnings, and important events (connections, sync) are logged.
  info,

  /// Everything is logged, including metrics.
  verbose,
}

/// Service for logging metrics, events, and errors from gossip and gossip_nearby.
///
/// Use [logLevel] to control verbosity:
/// - [DebugLogLevel.error]: Only errors
/// - [DebugLogLevel.warning]: Errors and warnings
/// - [DebugLogLevel.info]: Errors, warnings, and important events
/// - [DebugLogLevel.verbose]: Everything including periodic metrics
class DebugLogger {
  /// How often to log metrics.
  static const Duration _metricsInterval = Duration(seconds: 30);

  /// Prefix length for displaying IDs in logs.
  static const int _idPrefixLength = 8;
  final SyncService _syncService;
  final ConnectionService _connectionService;

  /// The minimum log level to display. Messages below this level are ignored.
  DebugLogLevel logLevel;

  StreamSubscription<DomainEvent>? _domainEventSubscription;
  StreamSubscription<SyncError>? _syncErrorSubscription;
  StreamSubscription<ConnectionError>? _connectionErrorSubscription;
  StreamSubscription<PeerEvent>? _peerEventSubscription;
  Timer? _metricsTimer;

  DebugLogger({
    required SyncService syncService,
    required ConnectionService connectionService,
    this.logLevel = DebugLogLevel.info,
  }) : _syncService = syncService,
       _connectionService = connectionService;

  /// Starts logging events, errors, and metrics.
  void start() {
    _logInfo('DEBUG', 'DebugLogger started (level: ${logLevel.name})');

    _domainEventSubscription = _syncService.events.listen(_onDomainEvent);
    _syncErrorSubscription = _syncService.errors.listen(_onSyncError);
    _connectionErrorSubscription = _connectionService.errors.listen(
      _onConnectionError,
    );
    _peerEventSubscription = _connectionService.peerEvents.listen(_onPeerEvent);

    _metricsTimer = Timer.periodic(_metricsInterval, (_) {
      _logMetrics();
    });

    _logMetrics();
  }

  /// Stops logging and releases resources.
  void stop() {
    _domainEventSubscription?.cancel();
    _syncErrorSubscription?.cancel();
    _connectionErrorSubscription?.cancel();
    _peerEventSubscription?.cancel();
    _metricsTimer?.cancel();
    _logInfo('DEBUG', 'DebugLogger stopped');
  }

  // ─────────────────────────────────────────────────────────────
  // Domain Events
  // ─────────────────────────────────────────────────────────────

  void _onDomainEvent(DomainEvent event) {
    final timestamp = _formatTime(event.occurredAt);
    switch (event) {
      case PeerAdded(:final peerId):
        _logInfo('PEER', '[$timestamp] Peer added: $peerId');
      case PeerRemoved(:final peerId):
        _logInfo('PEER', '[$timestamp] Peer removed: $peerId');
      case PeerStatusChanged(:final peerId, :final oldStatus, :final newStatus):
        _logInfo(
          'PEER',
          '[$timestamp] Peer status changed: $peerId $oldStatus -> $newStatus',
        );
      case PeerOperationSkipped(:final peerId, :final operation):
        _logVerbose(
          'PEER',
          '[$timestamp] Peer operation skipped: $peerId - $operation',
        );
      case ChannelCreated(:final channelId):
        _logInfo(
          'CHANNEL',
          '[$timestamp] Channel created: ${_shortId(channelId.value)}',
        );
      case ChannelRemoved(:final channelId):
        _logInfo(
          'CHANNEL',
          '[$timestamp] Channel removed: ${_shortId(channelId.value)}',
        );
      case MemberAdded(:final channelId, :final memberId):
        _logInfo(
          'CHANNEL',
          '[$timestamp] Member added to ${_shortId(channelId.value)}: $memberId',
        );
      case MemberRemoved(:final channelId, :final memberId):
        _logInfo(
          'CHANNEL',
          '[$timestamp] Member removed from ${_shortId(channelId.value)}: $memberId',
        );
      case StreamCreated(:final channelId, :final streamId):
        _logVerbose(
          'STREAM',
          '[$timestamp] Stream created: ${_shortId(channelId.value)}/${streamId.value}',
        );
      case EntryAppended(:final channelId, :final streamId, :final entry):
        _logVerbose(
          'SYNC',
          '[$timestamp] Entry appended: ${_shortId(channelId.value)}/${streamId.value} '
              'author=${_shortId(entry.author.value)} seq=${entry.sequence}',
        );
      case EntriesMerged(:final channelId, :final streamId, :final entries):
        _logVerbose(
          'SYNC',
          '[$timestamp] Entries merged: ${_shortId(channelId.value)}/${streamId.value} '
              'count=${entries.length}',
        );
      case StreamCompacted(:final channelId, :final streamId, :final result):
        _logVerbose(
          'SYNC',
          '[$timestamp] Stream compacted: ${_shortId(channelId.value)}/${streamId.value} '
              'removed=${result.entriesRemoved}',
        );
      case BufferOverflowOccurred(
        :final channelId,
        :final streamId,
        :final author,
        :final droppedCount,
      ):
        _logWarning(
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
        _logWarning(
          'WARN',
          '[$timestamp] Non-member entries rejected: ${_shortId(channelId.value)}/${streamId.value} '
              'count=$rejectedCount authors=$unknownAuthors',
        );
      case SyncErrorOccurred(:final error):
        _logSyncError(error, timestamp);
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Sync Errors
  // ─────────────────────────────────────────────────────────────

  void _onSyncError(SyncError error) {
    _logSyncError(error, _formatTime(error.occurredAt));
  }

  void _logSyncError(SyncError error, String timestamp) {
    switch (error) {
      case PeerSyncError(:final peer, :final type, :final message):
        _logError(
          'ERROR',
          '[$timestamp] Peer sync error: peer=$peer type=$type msg=$message',
        );
      case ChannelSyncError(:final channel, :final type, :final message):
        _logError(
          'ERROR',
          '[$timestamp] Channel sync error: channel=${_shortId(channel.value)} type=$type msg=$message',
        );
      case StorageSyncError(:final type, :final message):
        _logError(
          'ERROR',
          '[$timestamp] Storage sync error: type=$type msg=$message',
        );
      case TransformSyncError(:final channel, :final message):
        _logError(
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
        _logError(
          'ERROR',
          '[$timestamp] Buffer overflow error: ${_shortId(channel.value)}/${stream.value} '
              'author=$author bufferSize=$bufferSize msg=$message',
        );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Connection Errors
  // ─────────────────────────────────────────────────────────────

  void _onConnectionError(ConnectionError error) {
    final timestamp = _formatTime(error.occurredAt);
    switch (error) {
      case ConnectionNotFoundError(:final nodeId):
        _logError(
          'NEARBY',
          '[$timestamp] Connection not found: $nodeId - ${error.message}',
        );
      case HandshakeTimeoutError(:final endpointId):
        _logError(
          'NEARBY',
          '[$timestamp] Handshake timeout: $endpointId - ${error.message}',
        );
      case HandshakeInvalidError(:final endpointId):
        _logError(
          'NEARBY',
          '[$timestamp] Handshake invalid: $endpointId - ${error.message}',
        );
      case SendFailedError(:final nodeId):
        _logError(
          'NEARBY',
          '[$timestamp] Send failed: $nodeId - ${error.message}',
        );
      case ConnectionLostError(:final nodeId):
        _logError(
          'NEARBY',
          '[$timestamp] Connection lost: $nodeId - ${error.message}',
        );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Peer Events
  // ─────────────────────────────────────────────────────────────

  void _onPeerEvent(PeerEvent event) {
    switch (event) {
      case PeerConnected(:final nodeId):
        _logInfo('NEARBY', 'Peer connected: ${_shortId(nodeId.value)}');
      case PeerDisconnected(:final nodeId):
        _logInfo('NEARBY', 'Peer disconnected: ${_shortId(nodeId.value)}');
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Metrics Logging
  // ─────────────────────────────────────────────────────────────

  void _logMetrics() {
    if (logLevel != DebugLogLevel.verbose) return;

    _logSyncMetrics();
    _logConnectionMetrics();
    _logPeerMetrics();
  }

  Future<void> _logSyncMetrics() async {
    try {
      final health = await _syncService.getHealth();
      final usage = await _syncService.getResourceUsage();

      _logVerbose('METRICS', '=== Sync Health ===');
      _logVerbose('METRICS', '  State: ${health.state}');
      _logVerbose(
        'METRICS',
        '  Local node: ${_shortId(health.localNode.value)}',
      );
      _logVerbose('METRICS', '  Incarnation: ${health.incarnation}');
      _logVerbose('METRICS', '  Is healthy: ${health.isHealthy}');
      _logVerbose('METRICS', '  Reachable peers: ${health.reachablePeerCount}');
      _logVerbose('METRICS', '=== Resource Usage ===');
      _logVerbose('METRICS', '  Peers: ${usage.peerCount}');
      _logVerbose('METRICS', '  Channels: ${usage.channelCount}');
      _logVerbose('METRICS', '  Total entries: ${usage.totalEntries}');
      _logVerbose(
        'METRICS',
        '  Total storage: ${_formatBytes(usage.totalStorageBytes)}',
      );
    } catch (e) {
      _logError('METRICS', 'Failed to get sync metrics: $e');
    }
  }

  void _logConnectionMetrics() {
    final metrics = _connectionService.metrics;
    _logVerbose('METRICS', '=== Connection Metrics ===');
    _logVerbose('METRICS', '  Connected peers: ${metrics.connectedPeerCount}');
    _logVerbose(
      'METRICS',
      '  Pending handshakes: ${metrics.pendingHandshakeCount}',
    );
    _logVerbose(
      'METRICS',
      '  Connections established: ${metrics.totalConnectionsEstablished}',
    );
    _logVerbose(
      'METRICS',
      '  Connections failed: ${metrics.totalConnectionsFailed}',
    );
    _logVerbose('METRICS', '  Messages sent: ${metrics.totalMessagesSent}');
    _logVerbose(
      'METRICS',
      '  Messages received: ${metrics.totalMessagesReceived}',
    );
    _logVerbose(
      'METRICS',
      '  Bytes sent: ${_formatBytes(metrics.totalBytesSent)}',
    );
    _logVerbose(
      'METRICS',
      '  Bytes received: ${_formatBytes(metrics.totalBytesReceived)}',
    );
    _logVerbose(
      'METRICS',
      '  Avg handshake duration: ${metrics.averageHandshakeDuration.inMilliseconds}ms',
    );
    _logVerbose(
      'METRICS',
      '  Is advertising: ${_connectionService.isAdvertising}',
    );
    _logVerbose(
      'METRICS',
      '  Is discovering: ${_connectionService.isDiscovering}',
    );
  }

  void _logPeerMetrics() {
    final peers = _syncService.peers;
    if (peers.isEmpty) {
      _logVerbose('METRICS', '=== Peer Metrics ===');
      _logVerbose('METRICS', '  No peers registered');
      return;
    }

    _logVerbose('METRICS', '=== Peer Metrics (${peers.length} peers) ===');
    for (final peer in peers) {
      final metrics = _syncService.getPeerMetrics(peer.id);
      _logVerbose('METRICS', '  Peer ${_shortId(peer.id.value)}:');
      _logVerbose('METRICS', '    Status: ${peer.status}');
      _logVerbose(
        'METRICS',
        '    Incarnation: ${peer.incarnation ?? 'unknown'}',
      );
      _logVerbose(
        'METRICS',
        '    Failed probe count: ${peer.failedProbeCount}',
      );
      if (metrics != null) {
        _logVerbose('METRICS', '    Messages sent: ${metrics.messagesSent}');
        _logVerbose(
          'METRICS',
          '    Messages received: ${metrics.messagesReceived}',
        );
        _logVerbose(
          'METRICS',
          '    Bytes sent: ${_formatBytes(metrics.bytesSent)}',
        );
        _logVerbose(
          'METRICS',
          '    Bytes received: ${_formatBytes(metrics.bytesReceived)}',
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Leveled Logging
  // ─────────────────────────────────────────────────────────────

  void _logError(String category, String message) {
    _log(category, message);
  }

  void _logWarning(String category, String message) {
    if (logLevel.index >= DebugLogLevel.warning.index) {
      _log(category, message);
    }
  }

  void _logInfo(String category, String message) {
    if (logLevel.index >= DebugLogLevel.info.index) {
      _log(category, message);
    }
  }

  void _logVerbose(String category, String message) {
    if (logLevel.index >= DebugLogLevel.verbose.index) {
      _log(category, message);
    }
  }

  void _log(String category, String message) {
    final logLine = LogFormat.logLine(category, message);

    // ignore: avoid_print
    print(logLine);

    developer.log(message, name: 'gossip.$category');
  }

  String _formatTime(DateTime time) => LogFormat.shortTime(time);

  String _shortId(String id) => LogFormat.shortId(id, length: _idPrefixLength);

  String _formatBytes(int bytes) => LogFormat.bytes(bytes);
}

/// Minimum log level for [nearbyLogCallback].
///
/// Set this before starting the transport to control verbosity.
LogLevel nearbyMinLogLevel = LogLevel.info;

/// LogCallback implementation for NearbyTransport that prints to console.
///
/// Only logs messages at or above [nearbyMinLogLevel].
void nearbyLogCallback(
  LogLevel level,
  String message, [
  Object? error,
  StackTrace? stackTrace,
]) {
  if (level.index < nearbyMinLogLevel.index) return;

  final levelStr = level.name.toUpperCase().padRight(7);
  final category = 'NEARBY][$levelStr';
  var logLine = LogFormat.logLine(category, message);

  if (error != null) {
    logLine += ' | Error: $error';
  }

  // ignore: avoid_print
  print(logLine);

  developer.log(
    message,
    name: 'gossip.nearby.${level.name}',
    error: error,
    stackTrace: stackTrace,
  );
}
