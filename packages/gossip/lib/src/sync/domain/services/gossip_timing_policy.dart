import 'package:gossip/src/shared/domain/services/duration_clamp.dart';
import 'package:gossip/src/shared/domain/services/quiescence_pacer.dart';
import 'package:gossip/src/sync/domain/interfaces/peer_directory.dart';

/// Owns `GossipEngine`'s gossip-round interval policy: whether the
/// interval is a caller-supplied static value or derived from peer RTT,
/// the median-SRTT adaptive formula, and the quiescence pacer that
/// stretches the adaptive interval while quiet.
///
/// Pulled out of `GossipEngine`, which held a field triad
/// (`_adaptiveTimingEnabled` / `_staticGossipInterval` /
/// `_staticIntervalProvided`) that read as one static/adaptive switch but
/// actually encoded three distinct states — explicit static, adaptive, and
/// a default-static fallback — across two booleans and a `Duration` with a
/// dead `?? 500ms` fallback. [_IntervalMode] collapses those three states
/// into a single sealed choice instead: [_StaticInterval] covers both the
/// explicit and the default-fallback cases (both bypass the pacer
/// identically); [_Adaptive] is the only case the pacer ever touches.
class GossipTimingPolicy {
  GossipTimingPolicy({
    required PeerDirectory peerDirectory,
    Duration? staticInterval,
    required bool adaptiveEnabled,
  }) : _peerDirectory = peerDirectory,
       _mode = _resolveMode(staticInterval, adaptiveEnabled);

  final PeerDirectory _peerDirectory;
  final _IntervalMode _mode;

  static _IntervalMode _resolveMode(
    Duration? staticInterval,
    bool adaptiveEnabled,
  ) {
    if (staticInterval != null) return _StaticInterval(staticInterval);
    if (adaptiveEnabled) return const _Adaptive();
    return const _StaticInterval(_defaultStaticInterval);
  }

  /// Default gossip interval when adaptive timing is disabled and no
  /// explicit interval was supplied at construction.
  static const Duration _defaultStaticInterval = Duration(milliseconds: 500);

  /// Minimum gossip interval (prevent CPU spin).
  static const Duration _minGossipInterval = Duration(milliseconds: 100);

  /// Maximum gossip interval (ensure progress).
  static const Duration _maxGossipInterval = Duration(seconds: 5);

  /// Multiplier for gossip interval relative to RTT.
  /// Gossip interval = 2x RTT (time for request + response round trip).
  static const int _gossipIntervalMultiplier = 2;

  /// Default conservative gossip interval when no per-peer RTT data exists.
  static const Duration _defaultConservativeInterval = Duration(
    milliseconds: 1000,
  );

  /// The slowest the anti-entropy safety net may get (owner decision:
  /// 30 s, not configurable).
  static const Duration _idleCeiling = Duration(seconds: 30);

  /// Two-tier pacing (spec 2026-08-20): stretches the adaptive interval
  /// toward [_idleCeiling] across quiet rounds; any news snaps it back.
  /// Only the [_Adaptive] branch of [effectiveInterval] ever reads this —
  /// a static interval bypasses the pacer entirely.
  final QuiescencePacer _pacer = QuiescencePacer(ceiling: _idleCeiling);

  /// The effective gossip interval.
  ///
  /// If a static interval was supplied at construction (or none was and
  /// adaptive timing is disabled), returns that fixed value unconditionally
  /// — the pacer below never applies to it. Otherwise computes from the
  /// *median* per-peer smoothed RTT across all reachable peers
  /// ([_adaptiveBaseInterval]: multiplied by [_gossipIntervalMultiplier]
  /// (2x), clamped to [_minGossipInterval] and [_maxGossipInterval]
  /// (100ms-5s active), with a [_defaultConservativeInterval] (1000ms)
  /// fallback when no peer has an RTT estimate yet), then paced.
  ///
  /// Median (not min) pacing keeps a single fast peer from pinning the loop
  /// to a fast cadence that over-drives slower links, while a single very
  /// slow peer can't stall the whole mesh either — each uniform-random round
  /// is ~(n-1)/n likely to target a slower-than-fastest peer with a
  /// potentially large payload, so the median is robust to an outlier at
  /// either end. Latency-sensitive delivery is handled by reactive
  /// push-on-write; this is the anti-entropy safety net, so a steadier
  /// median cadence is the right trade-off.
  ///
  /// During quiet rounds this adaptive base is further stretched toward the
  /// 30s idle ceiling by the quiescence pacer ([quietRound]/[news] drive
  /// it).
  Duration get effectiveInterval => switch (_mode) {
    _StaticInterval(:final duration) => duration,
    _Adaptive() => _pacer.apply(_adaptiveBaseInterval),
  };

  /// Latency-derived cadence input to the adaptive branch of
  /// [effectiveInterval] — see there for the interval policy (median SRTT
  /// × 2, clamping, and fallback).
  Duration get _adaptiveBaseInterval {
    final srtts = <Duration>[];
    for (final partner in _peerDirectory.reachablePartners()) {
      final smoothedRtt = partner.smoothedRtt;
      if (smoothedRtt != null) srtts.add(smoothedRtt);
    }

    // Fall back to conservative default when no peers have RTT estimates
    if (srtts.isEmpty) {
      return _defaultConservativeInterval;
    }

    srtts.sort();
    final medianSrtt = srtts[srtts.length ~/ 2];
    final computed = medianSrtt * _gossipIntervalMultiplier;
    return clampDuration(
      computed,
      min: _minGossipInterval,
      max: _maxGossipInterval,
    );
  }

  /// Reports that something happened this round (local write, merge, delta
  /// traffic, a membership change): snaps [effectiveInterval] back to its
  /// base cadence.
  void news() => _pacer.news();

  /// Reports that a round completed with nothing to say: stretches
  /// [effectiveInterval] toward the 30s idle ceiling.
  void quietRound() => _pacer.quietRound();
}

/// Which of the two ways [GossipTimingPolicy.effectiveInterval] is
/// resolved — see the class doc for why this collapses the engine's old
/// three-state field triad.
sealed class _IntervalMode {
  const _IntervalMode();
}

/// A fixed interval, set either explicitly at construction or as the
/// default fallback when adaptive timing is disabled. Both cases bypass
/// the pacer identically, so they share one representation.
class _StaticInterval extends _IntervalMode {
  const _StaticInterval(this.duration);

  final Duration duration;
}

/// The interval is derived from peer RTT and paced — the only mode
/// [GossipTimingPolicy._pacer] ever applies to.
class _Adaptive extends _IntervalMode {
  const _Adaptive();
}
