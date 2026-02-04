/// Observability snapshot of adaptive timing state (ADR-013).
///
/// Exposes RTT estimates, computed protocol intervals, and transport
/// backpressure state for monitoring. All durations are the effective
/// values currently in use, which adapt based on measured round-trip times.
///
/// ## Usage
///
/// ```dart
/// final timing = coordinator.getAdaptiveTimingStatus();
/// if (timing != null) {
///   print('RTT: ${timing.smoothedRtt.inMilliseconds}ms');
///   print('Gossip interval: ${timing.effectiveGossipInterval.inMilliseconds}ms');
///   print('Pending sends: ${timing.totalPendingSendCount}');
/// }
/// ```
///
/// Returns `null` from [Coordinator.getAdaptiveTimingStatus] when
/// running in local-only mode (no transport configured).
///
/// See also:
/// - [HealthStatus] for overall coordinator health
/// - [ResourceUsage] for storage and capacity statistics
class AdaptiveTimingStatus {
  /// Smoothed round-trip time estimate (EWMA per RFC 6298).
  final Duration smoothedRtt;

  /// RTT variance (mean deviation) used in timeout computation.
  final Duration rttVariance;

  /// Number of RTT samples collected since startup.
  final int rttSampleCount;

  /// Whether any RTT samples have been received.
  ///
  /// When false, all intervals use conservative initial defaults.
  final bool hasRttSamples;

  /// Effective gossip interval currently in use by the gossip engine.
  final Duration effectiveGossipInterval;

  /// Effective SWIM ping timeout currently in use by the failure detector.
  final Duration effectivePingTimeout;

  /// Effective SWIM probe interval currently in use by the failure detector.
  final Duration effectiveProbeInterval;

  /// Total number of messages pending send across all peers.
  ///
  /// When this exceeds the congestion threshold, gossip rounds are skipped.
  final int totalPendingSendCount;

  const AdaptiveTimingStatus({
    required this.smoothedRtt,
    required this.rttVariance,
    required this.rttSampleCount,
    required this.hasRttSamples,
    required this.effectiveGossipInterval,
    required this.effectivePingTimeout,
    required this.effectiveProbeInterval,
    required this.totalPendingSendCount,
  });
}
