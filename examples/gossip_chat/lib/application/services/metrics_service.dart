import '../../presentation/view_models/metrics_state.dart';
import 'connection_service.dart';
import 'sync_service.dart';

/// Service for aggregating and calculating sync metrics.
///
/// Tracks rolling averages for data transfer rates by sampling
/// periodically and maintaining a sliding window of samples.
class MetricsService {
  final SyncService _syncService;
  final ConnectionService _connectionService;

  /// Number of samples to keep for rolling average (30 seconds at 2s intervals).
  static const int _maxSamples = 15;

  // Previous sample values for delta calculation
  int _lastTotalBytesSent = 0;
  int _lastTotalBytesReceived = 0;
  DateTime _lastSampleTime = DateTime.now();

  // Rolling average samples (bytes per second)
  final List<double> _sendRateSamples = [];
  final List<double> _receiveRateSamples = [];

  MetricsService({
    required SyncService syncService,
    required ConnectionService connectionService,
  }) : _syncService = syncService,
       _connectionService = connectionService;

  /// Samples current metrics and updates rolling averages.
  ///
  /// Should be called periodically (e.g., every 2 seconds).
  void sampleRates() {
    final now = DateTime.now();
    final elapsed = now.difference(_lastSampleTime).inMilliseconds / 1000.0;

    if (elapsed <= 0) return;

    // Get current totals from transport metrics
    final transportMetrics = _connectionService.metrics;
    final totalBytesSent = transportMetrics.totalBytesSent;
    final totalBytesReceived = transportMetrics.totalBytesReceived;

    // Calculate rates from deltas
    final sentDelta = totalBytesSent - _lastTotalBytesSent;
    final receivedDelta = totalBytesReceived - _lastTotalBytesReceived;

    final sendRate = sentDelta / elapsed;
    final receiveRate = receivedDelta / elapsed;

    _addSample(_sendRateSamples, sendRate);
    _addSample(_receiveRateSamples, receiveRate);

    // Update state for next sample
    _lastTotalBytesSent = totalBytesSent;
    _lastTotalBytesReceived = totalBytesReceived;
    _lastSampleTime = now;
  }

  /// Gets the current metrics state.
  Future<MetricsState> getMetrics() async {
    final resourceUsage = await _syncService.getResourceUsage();
    final transportMetrics = _connectionService.metrics;

    // Build peer states using gossip library's per-peer metrics
    final peerStates = <PeerMetricsState>[];
    for (final peer in _syncService.peers) {
      final peerMetrics = _syncService.getPeerMetrics(peer.id);
      peerStates.add(
        PeerMetricsState(
          id: peer.id,
          displayName: peer.displayName,
          bytesSent: peerMetrics?.bytesSent ?? 0,
          bytesReceived: peerMetrics?.bytesReceived ?? 0,
        ),
      );
    }

    return MetricsState(
      totalEntries: resourceUsage.totalEntries,
      totalStorageBytes: resourceUsage.totalStorageBytes,
      totalBytesSent: transportMetrics.totalBytesSent,
      totalBytesReceived: transportMetrics.totalBytesReceived,
      sendRateBytesPerSec: _average(_sendRateSamples),
      receiveRateBytesPerSec: _average(_receiveRateSamples),
      peers: peerStates,
      lastUpdated: DateTime.now(),
    );
  }

  void _addSample(List<double> samples, double value) {
    samples.add(value);
    if (samples.length > _maxSamples) {
      samples.removeAt(0);
    }
  }

  double _average(List<double> samples) {
    if (samples.isEmpty) return 0;
    return samples.reduce((a, b) => a + b) / samples.length;
  }
}
