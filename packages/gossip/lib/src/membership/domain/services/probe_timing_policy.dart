import 'package:gossip/src/membership/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/shared/domain/services/duration_clamp.dart';
import 'package:gossip/src/shared/domain/services/quiescence_pacer.dart';
import 'package:gossip/src/shared/domain/services/rtt_tracker.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';

/// Owns the failure detector's probe-timing policy: how long to wait for
/// an Ack, and how often to run a probe round.
///
/// Pulled out of `FailureDetector` (CC5-13): the detector held two
/// independent knobs (ping timeout, probe interval), each independently
/// static-or-adaptive, plus a pacer that stretches only the adaptive
/// interval while quiet. Each knob used to be a field-triad — a
/// `Duration` field with a dead `?? default` fallback, plus a separate
/// `bool ...Provided` flag tracking whether that fallback was ever live —
/// which read as one static/adaptive switch when it was really two
/// independent ones. Collapsing each triad to a single nullable
/// [Duration] (`null` = adaptive, the only honest default) makes "was a
/// static value supplied" the field's own nullability rather than a
/// second flag that could drift from it, and gives the two knobs ×
/// static/adaptive × pacer interaction one home instead of living
/// scattered across the detector's construction, constants, and getters.
class ProbeTimingPolicy {
  ProbeTimingPolicy({
    required this.peerRegistry,
    required RttTracker rttTracker,
    Duration? staticPingTimeout,
    Duration? staticProbeInterval,
  }) : _rttTracker = rttTracker,
       _staticPingTimeout = staticPingTimeout,
       _staticProbeInterval = staticProbeInterval;

  final PeerRegistry peerRegistry;
  final RttTracker _rttTracker;

  /// A caller-supplied fixed ping timeout, or null for the adaptive
  /// RTT-derived estimate.
  ///
  /// Independent of [_staticProbeInterval]: supplying one must NOT
  /// disable adaptive timing on the other — a static probe interval must
  /// not pin the ping timeout to some unrelated fallback value (the
  /// ADR-013 regression this independence guards against).
  final Duration? _staticPingTimeout;

  /// A caller-supplied fixed probe interval, or null for the adaptive
  /// formula. See [_staticPingTimeout] for why these two are independent.
  final Duration? _staticProbeInterval;

  static const Duration _minPingTimeout = Duration(milliseconds: 500);
  static const Duration _maxPingTimeout = Duration(seconds: 10);
  static const Duration _minProbeInterval = Duration(milliseconds: 500);
  static const Duration _maxProbeInterval = Duration(seconds: 30);
  static const int _probeIntervalMultiplier = 3;

  /// Two-tier pacing for the probe loop (spec 2026-08-20).
  ///
  /// Independent from GossipEngine's pacer instance: each protocol loop
  /// paces its own cadence toward its own ceiling. All-healthy rounds
  /// stretch [effectiveProbeInterval] toward [_maxProbeInterval]; a full
  /// miss or a membership change (new peer, recovery) snaps it back via
  /// [news].
  final QuiescencePacer _pacer = QuiescencePacer(ceiling: _maxProbeInterval);

  /// Effective ping timeout from the global RTT estimate.
  ///
  /// Falls back to [_staticPingTimeout] if one was supplied at
  /// construction.
  Duration get effectivePingTimeout {
    if (_staticPingTimeout != null) return _staticPingTimeout;
    return _rttTracker.suggestedTimeout(
      minTimeout: _minPingTimeout,
      maxTimeout: _maxPingTimeout,
    );
  }

  /// Per-peer ping timeout, falling back to the global estimate.
  ///
  /// Uses the peer's own RTT estimate if available, otherwise uses the
  /// global [effectivePingTimeout]. This lets fast peers use shorter
  /// timeouts while slow peers get longer ones.
  Duration effectivePingTimeoutForPeer(NodeId peerId) {
    if (_staticPingTimeout != null) return _staticPingTimeout;
    final peerRtt = peerRegistry.getPeer(peerId)?.metrics.rttEstimate;
    if (peerRtt != null) {
      return peerRtt.suggestedTimeout(
        minTimeout: _minPingTimeout,
        maxTimeout: _maxPingTimeout,
      );
    }
    return effectivePingTimeout;
  }

  /// Effective probe interval (time between probe rounds).
  ///
  /// Computed as 3x the effective ping timeout to allow time for both
  /// direct and indirect probes within each interval, then paced: quiet
  /// (all-answered) rounds stretch this toward [_maxProbeInterval]; a
  /// miss or membership change snaps it back to the formula's raw value.
  /// A static override bypasses the pacer entirely.
  Duration get effectiveProbeInterval {
    if (_staticProbeInterval != null) return _staticProbeInterval;
    final baseInterval = effectivePingTimeout * _probeIntervalMultiplier;
    final clampedBase = clampDuration(
      baseInterval,
      min: _minProbeInterval,
      max: _maxProbeInterval,
    );
    return _pacer.apply(clampedBase);
  }

  /// Reports that something happened this round (peer recovery, a probe
  /// failure, a restart): snaps [effectiveProbeInterval] back to its base
  /// cadence.
  void news() => _pacer.news();

  /// Reports that a round completed with nothing to report: stretches
  /// [effectiveProbeInterval] toward [_maxProbeInterval].
  void quietRound() => _pacer.quietRound();
}
