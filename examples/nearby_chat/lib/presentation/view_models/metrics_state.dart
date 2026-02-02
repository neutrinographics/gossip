import 'package:gossip/gossip.dart' show NodeId;

/// Metrics state for a single peer.
class PeerMetricsState {
  final NodeId id;
  final String displayName;
  final int bytesSent;
  final int bytesReceived;

  const PeerMetricsState({
    required this.id,
    required this.displayName,
    required this.bytesSent,
    required this.bytesReceived,
  });
}

/// Aggregate metrics state for the sync system.
///
/// Immutable view model for displaying metrics in the UI.
class MetricsState {
  /// Total number of entries stored across all channels/streams.
  final int totalEntries;

  /// Total storage size in bytes.
  final int totalStorageBytes;

  /// Total bytes sent to all peers (lifetime).
  final int totalBytesSent;

  /// Total bytes received from all peers (lifetime).
  final int totalBytesReceived;

  /// Rolling average send rate in bytes per second.
  final double sendRateBytesPerSec;

  /// Rolling average receive rate in bytes per second.
  final double receiveRateBytesPerSec;

  /// Per-peer metrics.
  final List<PeerMetricsState> peers;

  /// When these metrics were last updated.
  final DateTime lastUpdated;

  const MetricsState({
    required this.totalEntries,
    required this.totalStorageBytes,
    required this.totalBytesSent,
    required this.totalBytesReceived,
    required this.sendRateBytesPerSec,
    required this.receiveRateBytesPerSec,
    required this.peers,
    required this.lastUpdated,
  });

  /// Creates an empty metrics state.
  factory MetricsState.empty() => MetricsState(
    totalEntries: 0,
    totalStorageBytes: 0,
    totalBytesSent: 0,
    totalBytesReceived: 0,
    sendRateBytesPerSec: 0,
    receiveRateBytesPerSec: 0,
    peers: const [],
    lastUpdated: DateTime.fromMillisecondsSinceEpoch(0),
  );
}
