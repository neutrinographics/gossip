/// Resource usage statistics for the coordinator.
///
/// Provides a snapshot of current resource consumption including
/// peer count, channel count, entry count, and storage usage. Use this
/// for capacity planning, monitoring, and debugging.
///
/// ## Usage
///
/// ```dart
/// final usage = await coordinator.getResourceUsage();
///
/// print('Peers: ${usage.peerCount}');
/// print('Channels: ${usage.channelCount}');
/// print('Entries: ${usage.totalEntries}');
/// print('Storage: ${usage.totalStorageBytes} bytes');
/// ```
///
/// ## Performance Note
///
/// Computing resource usage iterates through all channels and streams.
/// For large deployments, consider caching or sampling rather than
/// calling [Coordinator.getResourceUsage] frequently.
///
/// See also:
/// - [HealthStatus] for overall health including resource usage
/// - [Coordinator.getResourceUsage] to obtain statistics
class ResourceUsage {
  /// Number of registered peers.
  final int peerCount;

  /// Number of channels.
  final int channelCount;

  /// Total number of entries across all channels and streams.
  final int totalEntries;

  /// Total storage size in bytes across all channels and streams.
  final int totalStorageBytes;

  const ResourceUsage({
    required this.peerCount,
    required this.channelCount,
    required this.totalEntries,
    required this.totalStorageBytes,
  });
}
