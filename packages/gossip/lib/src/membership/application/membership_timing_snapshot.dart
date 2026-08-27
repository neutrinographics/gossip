import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/rtt_estimate.dart';

/// Snapshot of membership's RTT and timing state, as owned by the
/// `FailureDetector`.
///
/// Produced by `FailureDetector.timingSnapshot()`. Exists so observability
/// callers outside this context (the coordinator facade) read membership's
/// RTT/timing state through one value object instead of reaching into
/// `peerRegistry`, `rttTracker`, and the effective-interval getters
/// individually — the selection policy (per-peer vs. global fallback) stays
/// inside the context that owns the data it selects over.
class MembershipTimingSnapshot {
  /// Per-peer RTT estimates keyed by node ID.
  ///
  /// Only contains entries for peers that have at least one RTT sample.
  final Map<NodeId, RttEstimate> perPeerRtt;

  /// Smoothed RTT: the minimum per-peer smoothed RTT when any peer has an
  /// estimate, else the global tracker's estimate.
  final Duration smoothedRtt;

  /// RTT variance paired with [smoothedRtt] -- the SAME peer's variance
  /// when [smoothedRtt] came from a peer, never an independently-chosen
  /// minimum across peers.
  final Duration rttVariance;

  /// Sample count backing [smoothedRtt]/[rttVariance]: the number of peers
  /// with an RTT estimate when any exist, else the global tracker's sample
  /// count.
  final int sampleCount;

  /// Whether [smoothedRtt]/[rttVariance]/[sampleCount] reflect real samples
  /// rather than cold-start defaults.
  final bool hasSamples;

  /// This detector's current effective SWIM ping timeout.
  final Duration pingTimeout;

  /// This detector's current effective SWIM probe interval.
  final Duration probeInterval;

  const MembershipTimingSnapshot({
    required this.perPeerRtt,
    required this.smoothedRtt,
    required this.rttVariance,
    required this.sampleCount,
    required this.hasSamples,
    required this.pingTimeout,
    required this.probeInterval,
  });
}
