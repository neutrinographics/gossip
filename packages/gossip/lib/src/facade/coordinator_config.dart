/// Configuration options for the [Coordinator].
///
/// The library automatically adapts timing based on observed network latency,
/// making it self-tuning for any transport (WiFi, BLE, etc.). Only policy
/// parameters like [suspicionThreshold] remain configurable.
///
/// ## Adaptive Timing (ADR-013)
///
/// The following timing parameters are automatically derived from RTT measurements:
/// - **Ping timeout**: `RTT + 4 * variance` (clamped to 200ms-10s)
/// - **Probe interval**: `3 * ping timeout` (clamped to 500ms-30s)
/// - **Gossip interval**: `2 * RTT` (clamped to 100ms-5s)
///
/// This eliminates the need for transport-specific configuration and prevents
/// false positive peer failures on high-latency transports like BLE.
///
/// ## Example
///
/// ```dart
/// // Use defaults (recommended for most cases)
/// final coordinator = await Coordinator.create(
///   localNodeRepository: localNodeRepo,
///   // ... other params
/// );
///
/// // Or customize suspicion threshold for stricter failure detection
/// final config = CoordinatorConfig(suspicionThreshold: 3);
/// final coordinator = await Coordinator.create(
///   localNodeRepository: localNodeRepo,
///   config: config,
///   // ... other params
/// );
/// ```
class CoordinatorConfig {
  /// Number of consecutive probe failures before marking a peer as suspected.
  ///
  /// After this many failed probes without a successful response, the peer
  /// transitions from [PeerStatus.reachable] to [PeerStatus.suspected].
  /// Suspected peers can recover by responding to future probes.
  ///
  /// **Default: 5** (tolerant of high-latency transports like BLE)
  ///
  /// Lower values detect failures faster but may cause false positives on
  /// flaky networks. Higher values are more tolerant but slower to detect
  /// actual failures.
  final int suspicionThreshold;

  /// Number of consecutive probe failures before marking a suspected peer
  /// as unreachable.
  ///
  /// After this many total failed probes (including those that triggered
  /// suspicion), the peer transitions from [PeerStatus.suspected] to
  /// [PeerStatus.unreachable]. Unreachable peers are excluded from probing
  /// and gossip, but remain in the registry so they can recover if the
  /// transport reconnects.
  ///
  /// **Default: 15** (gives suspected peers 10 additional probe cycles
  /// beyond [suspicionThreshold] to recover)
  ///
  /// Must be greater than [suspicionThreshold].
  final int unreachableThreshold;

  /// Grace period for newly added peers before they become eligible for
  /// failure detection probing.
  ///
  /// When a peer is added via [Coordinator.addPeer], there may be a delay
  /// before the transport layer is fully bidirectional (the remote peer's
  /// receive path may still be initializing). This grace period prevents
  /// false positive failure detections during startup.
  ///
  /// The grace period is automatically cleared early if [probeNewPeer]
  /// succeeds, confirming the peer is actually reachable.
  ///
  /// **Default: 10 seconds**
  ///
  /// Set to [Duration.zero] to disable the grace period.
  final Duration startupGracePeriod;

  /// Creates a [CoordinatorConfig] with the specified options.
  const CoordinatorConfig({
    this.suspicionThreshold = 5,
    this.unreachableThreshold = 15,
    this.startupGracePeriod = const Duration(seconds: 10),
  });

  /// Default configuration with standard values.
  static const CoordinatorConfig defaults = CoordinatorConfig();
}
