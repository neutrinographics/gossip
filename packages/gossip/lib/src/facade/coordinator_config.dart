/// Configuration options for the [Coordinator].
///
/// Most timing parameters are now automatically derived from RTT measurements,
/// making the library self-tuning for any transport (WiFi, BLE, etc.).
///
/// ## Example
/// ```dart
/// final config = CoordinatorConfig(
///   gossipInterval: Duration(milliseconds: 100),  // Faster sync
///   suspicionThreshold: 3,                        // Stricter failure detection
/// );
///
/// final coordinator = await Coordinator.create(
///   localNode: NodeId('device-1'),
///   // ... other params
///   config: config,
/// );
/// ```
class CoordinatorConfig {
  /// Interval between gossip rounds for anti-entropy synchronization.
  ///
  /// Lower values mean faster convergence but more network traffic.
  /// Default: 500ms (2 rounds per second)
  final Duration gossipInterval;

  /// Number of failed probes before marking a peer as suspected.
  ///
  /// After this many consecutive probe failures, the peer transitions
  /// from reachable to suspected status.
  /// Default: 5
  final int suspicionThreshold;

  /// Creates a [CoordinatorConfig] with the specified options.
  ///
  /// Timing parameters for SWIM failure detection (ping timeout, probe interval)
  /// are automatically derived from RTT measurements. Only policy parameters
  /// like [suspicionThreshold] remain configurable.
  const CoordinatorConfig({
    this.gossipInterval = const Duration(milliseconds: 500),
    this.suspicionThreshold = 5,
  });

  /// Default configuration with standard values.
  static const CoordinatorConfig defaults = CoordinatorConfig();
}
