/// Configuration options for the [Coordinator].
///
/// Allows tuning of gossip protocol and failure detection parameters
/// to match deployment requirements.
///
/// The default values are tuned for high-latency transports like BLE,
/// which can have round-trip times of several seconds. For low-latency
/// transports like WiFi, these conservative defaults will still work
/// correctly but may result in slower failure detection.
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
  /// Default: 500ms (2 rounds per second)
  final Duration gossipInterval;

  /// Interval between SWIM probe rounds for failure detection.
  ///
  /// Should be greater than [pingTimeout] + [indirectPingTimeout] to ensure
  /// each probe round completes before the next one starts.
  /// Default: 3000ms (1 probe per 3 seconds)
  final Duration probeInterval;

  /// Timeout for direct ping acknowledgment.
  ///
  /// If no Ack is received within this duration, the peer is considered
  /// potentially failed and indirect probing begins.
  /// Default: 2000ms
  final Duration pingTimeout;

  /// Timeout for indirect ping acknowledgment via intermediaries.
  ///
  /// If no Ack is received via any intermediary within this duration,
  /// the peer's failed probe count is incremented.
  /// Default: 2000ms
  final Duration indirectPingTimeout;

  /// Number of failed probes before marking a peer as suspected.
  ///
  /// After this many consecutive probe failures, the peer transitions
  /// from reachable to suspected status.
  /// Default: 5
  final int suspicionThreshold;

  /// Creates a [CoordinatorConfig] with the specified options.
  ///
  /// All parameters are optional and default to sensible values.
  const CoordinatorConfig({
    this.gossipInterval = const Duration(milliseconds: 500),
    this.probeInterval = const Duration(milliseconds: 3000),
    this.pingTimeout = const Duration(milliseconds: 2000),
    this.indirectPingTimeout = const Duration(milliseconds: 2000),
    this.suspicionThreshold = 5,
  });

  /// Default configuration with standard values.
  static const CoordinatorConfig defaults = CoordinatorConfig();
}
