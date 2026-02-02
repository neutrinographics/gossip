/// Configuration options for the [Coordinator].
///
/// Allows tuning of gossip protocol and failure detection parameters
/// to match deployment requirements.
///
/// All values have sensible defaults for typical mobile deployments
/// with up to 8 devices and sub-second convergence requirements.
///
/// ## Example
/// ```dart
/// final config = CoordinatorConfig(
///   gossipInterval: Duration(milliseconds: 100),  // Faster sync
///   probeInterval: Duration(milliseconds: 500),   // Faster failure detection
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
  /// Default: 200ms (5 rounds per second)
  final Duration gossipInterval;

  /// Interval between SWIM probe rounds for failure detection.
  ///
  /// Lower values mean faster failure detection but more network traffic.
  /// Default: 1000ms (1 probe per second)
  final Duration probeInterval;

  /// Timeout for direct ping acknowledgment.
  ///
  /// If no Ack is received within this duration, the peer is considered
  /// potentially failed and indirect probing begins.
  /// Default: 500ms
  final Duration pingTimeout;

  /// Timeout for indirect ping acknowledgment via intermediaries.
  ///
  /// If no Ack is received via any intermediary within this duration,
  /// the peer's failed probe count is incremented.
  /// Default: 500ms
  final Duration indirectPingTimeout;

  /// Number of failed probes before marking a peer as suspected.
  ///
  /// After this many consecutive probe failures, the peer transitions
  /// from reachable to suspected status.
  /// Default: 3
  final int suspicionThreshold;

  /// Creates a [CoordinatorConfig] with the specified options.
  ///
  /// All parameters are optional and default to sensible values.
  const CoordinatorConfig({
    this.gossipInterval = const Duration(milliseconds: 200),
    this.probeInterval = const Duration(milliseconds: 1000),
    this.pingTimeout = const Duration(milliseconds: 500),
    this.indirectPingTimeout = const Duration(milliseconds: 500),
    this.suspicionThreshold = 3,
  });

  /// Default configuration with standard values.
  static const CoordinatorConfig defaults = CoordinatorConfig();
}
