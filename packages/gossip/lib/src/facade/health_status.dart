import '../domain/value_objects/node_id.dart';
import 'resource_usage.dart';
import 'sync_state.dart';

/// Health status of the coordinator.
///
/// Provides a comprehensive view of the coordinator's current state
/// including sync state, resource usage, and connectivity. Use this
/// for monitoring dashboards, health checks, and debugging.
///
/// ## Usage
///
/// ```dart
/// final health = await coordinator.getHealth();
///
/// if (health.isHealthy) {
///   print('Coordinator is healthy');
///   print('State: ${health.state}');
///   print('Reachable peers: ${health.reachablePeerCount}');
///   print('Total entries: ${health.resourceUsage.totalEntries}');
/// } else {
///   print('Coordinator is not healthy: ${health.state}');
/// }
/// ```
///
/// ## Health Definition
///
/// The coordinator is considered healthy when [state] is [SyncState.running].
/// Note that having zero peers is still healthy - the coordinator operates
/// in standalone mode until peers are added.
///
/// See also:
/// - [ResourceUsage] for detailed resource statistics
/// - [Coordinator.getHealth] to obtain health status
class HealthStatus {
  /// Current sync state.
  final SyncState state;

  /// Local node identifier.
  final NodeId localNode;

  /// SWIM incarnation number.
  final int incarnation;

  /// Resource usage statistics.
  final ResourceUsage resourceUsage;

  /// Number of reachable peers.
  final int reachablePeerCount;

  const HealthStatus({
    required this.state,
    required this.localNode,
    required this.incarnation,
    required this.resourceUsage,
    required this.reachablePeerCount,
  });

  /// Returns true if the coordinator is in a healthy state.
  ///
  /// The coordinator is considered healthy when it is running.
  /// Standalone mode (no peers) is still healthy if running.
  bool get isHealthy => state == SyncState.running;
}
