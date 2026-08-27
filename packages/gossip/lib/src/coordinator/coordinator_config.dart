import 'package:gossip/src/membership/membership.dart';
import 'package:gossip/src/sync/sync.dart';

/// Configuration options for the Coordinator.
///
/// The library automatically adapts timing based on observed network latency,
/// making it self-tuning for any transport (WiFi, BLE, etc.) — most callers
/// only need the policy knobs below, like [suspicionThreshold].
/// [gossipInterval], [probeInterval], and [pingTimeout] are escape hatches:
/// setting any of them bypasses adaptive timing for that value entirely.
///
/// ## Adaptive Timing (ADR-013)
///
/// The following timing parameters are automatically derived from RTT measurements:
/// - **Ping timeout**: `RTT + 4 * variance` (clamped to 500ms-10s)
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
  /// When a peer is added via Coordinator.addPeer, there may be a delay
  /// before the transport layer is fully bidirectional (the remote peer's
  /// receive path may still be initializing). This grace period prevents
  /// false positive failure detections during startup.
  ///
  /// The grace period is automatically cleared early if
  /// [FailureDetector.probeNewPeer] succeeds, confirming the peer is
  /// actually reachable.
  ///
  /// **Default: 10 seconds**
  ///
  /// Set to [Duration.zero] to disable the grace period.
  final Duration startupGracePeriod;

  /// How often to probe unreachable peers, expressed as a multiple of regular
  /// probe rounds.
  ///
  /// Every [unreachableProbeInterval] probe rounds, the failure detector
  /// probes one unreachable peer (round-robin) to detect transport recovery
  /// without requiring an explicit reconnection event.
  ///
  /// **Default: 5.** The resulting real-time cadence tracks the failure
  /// detector's adaptive probe interval, not a fixed duration — see
  /// [FailureDetector.effectiveProbeInterval].
  ///
  /// Lower values detect recovery faster but add more traffic for peers that
  /// are likely still down. Set to 0 to disable unreachable probing.
  final int unreachableProbeInterval;

  /// Explicit gossip round interval. When null (default), `GossipEngine`
  /// computes the interval adaptively from per-peer RTT, bounded to
  /// [100ms, 5s]. When non-null, the engine uses this value verbatim.
  final Duration? gossipInterval;

  /// Explicit SWIM probe interval. When null (default), `FailureDetector`
  /// derives the interval adaptively from pingTimeout * 3.
  final Duration? probeInterval;

  /// Explicit SWIM ping timeout. When null (default), `FailureDetector`
  /// computes the timeout adaptively from per-peer RTT.
  final Duration? pingTimeout;

  /// Whether to allow adaptive timing for any knob left null above.
  /// When false, the engine and failure-detector use their internal
  /// fallback constants instead of adaptive computation.
  final bool adaptiveTimingEnabled;

  /// Maximum encoded size (bytes) of a single gossip DeltaResponse message.
  ///
  /// Large entry backlogs are paginated across gossip rounds so no single
  /// message exceeds this budget. It also determines the maximum entry
  /// payload accepted by `EventStream.append` (roughly 3/4 of the budget
  /// after envelope overhead — ~22KB at the default): a payload that
  /// can't fit one delta message can never be synced.
  ///
  /// **Default: 30KB**, leaving envelope headroom under the 32KB message
  /// limit shared by Android Nearby Connections and the BLE frame codec.
  /// Only raise this if every transport in your deployment carries larger
  /// messages.
  final int maxMessageBytes;

  /// How often the library applies each stream's retention policy, pruning
  /// entries the policy no longer keeps.
  ///
  /// Retention policies attached at stream creation are declarative; this is
  /// what actually enforces them. Without periodic compaction a stream with a
  /// pruning policy (e.g. [TimeBasedRetention]) would grow without bound.
  /// Streams with a retain-all policy are skipped cheaply.
  ///
  /// **Default: 5 minutes.** Set to `null` (or [Duration.zero]) to disable
  /// auto-compaction, in which case the application must call
  /// `EventStream.compact()` itself. Requires a `timePort` (auto-compaction
  /// is inactive in local-only mode).
  ///
  /// A scheduling failure (the underlying timer itself breaking, not a
  /// single compaction run failing) stops the compaction loop deliberately
  /// rather than retrying — a broken timer doesn't heal by retrying it — so
  /// the application should observe the resulting `StorageSyncError` and
  /// stop/start the coordinator to restart the loop.
  final Duration? compactionInterval;

  /// Maximum amount a remote peer's timestamp may drag the local HLC ahead
  /// of the local wall clock.
  ///
  /// Bounds the damage a peer with a broken clock (e.g. date set years
  /// ahead) can do: without a bound its timestamp is adopted permanently
  /// and propagates mesh-wide, inverting time-based retention. Should
  /// comfortably exceed realistic device clock skew — remote timestamps
  /// within the bound merge with normal HLC causality semantics.
  ///
  /// **Default: 1 hour.**
  final Duration hlcMaxDrift;

  /// Creates a [CoordinatorConfig] with the specified options.
  const CoordinatorConfig({
    this.suspicionThreshold = 5,
    this.unreachableThreshold = 15,
    this.unreachableProbeInterval = 5,
    this.startupGracePeriod = const Duration(seconds: 10),
    this.gossipInterval,
    this.probeInterval,
    this.pingTimeout,
    this.adaptiveTimingEnabled = true,
    this.maxMessageBytes = 30 * 1024,
    this.compactionInterval = const Duration(minutes: 5),
    this.hlcMaxDrift = const Duration(hours: 1),
  });

  /// Default configuration with standard values.
  static const CoordinatorConfig defaults = CoordinatorConfig();
}
