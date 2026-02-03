/// Configuration options for the [Coordinator].
///
/// Most timing parameters are now automatically derived from RTT measurements,
/// making the library self-tuning for any transport (WiFi, BLE, etc.).
///
/// ## Example
/// ```dart
/// final config = CoordinatorConfig(
///   suspicionThreshold: 3,  // Stricter failure detection
/// );
///
/// final coordinator = await Coordinator.create(
///   localNode: NodeId('device-1'),
///   // ... other params
///   config: config,
/// );
/// ```
class CoordinatorConfig {
  /// Number of failed probes before marking a peer as suspected.
  ///
  /// After this many consecutive probe failures, the peer transitions
  /// from reachable to suspected status.
  /// Default: 5
  final int suspicionThreshold;

  /// Creates a [CoordinatorConfig] with the specified options.
  ///
  /// Timing parameters for SWIM failure detection (ping timeout, probe interval)
  /// and gossip interval are automatically derived from RTT measurements.
  /// Only policy parameters like [suspicionThreshold] remain configurable.
  const CoordinatorConfig({this.suspicionThreshold = 5});

  /// Default configuration with standard values.
  static const CoordinatorConfig defaults = CoordinatorConfig();
}
