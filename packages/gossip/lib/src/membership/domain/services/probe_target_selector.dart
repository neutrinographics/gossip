import 'dart:math';

import 'package:gossip/src/membership/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/membership/domain/entities/peer.dart';
import 'package:gossip/src/shared/domain/interfaces/time_port.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';

/// Owns the failure detector's probe-target selection policy: which peer
/// to ping next, which peers can stand in as indirect-ping intermediaries
/// when a direct probe fails, which peer is due for the periodic
/// unreachable-recovery probe, and the startup grace period that excludes
/// a peer from probing altogether.
///
/// Pulled out of `FailureDetector` (CC5-2/CC5-14): the extracted method was
/// named `selectRandomPeer` — a fossil from before the H3 fix replaced
/// pure-random selection with round-robin coverage — while it, and the
/// state it closed over (the shuffled cursor, the probing-hold map, the
/// per-peer last-probe-attempt map backing the suppression cap), had
/// nothing to do with the detector's ping/ack/timeout orchestration. Giving
/// the policy a class of its own gives it its true name and lets it be
/// tested, and reasoned about, independently of the protocol machinery.
class ProbeTargetSelector {
  ProbeTargetSelector({
    required this.peerRegistry,
    required this.timePort,
    required Random random,
  }) : _random = random;

  final PeerRegistry peerRegistry;
  final TimePort timePort;
  final Random _random;

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------

  /// Hard cap on how long freshness alone may suppress a probe: 4× the
  /// 30 s ceiling, so freshness alone can never suppress a probe for more
  /// than 2 minutes. Freshness-only suppression (below) keys on INBOUND
  /// evidence — under asymmetric one-way loss (our probes to a peer die,
  /// but the peer's own traffic to us, e.g. its own unreachable-probing of
  /// us, keeps arriving) that inbound evidence never stops, so we would
  /// never probe the peer and never detect the failure. This bounds
  /// half-open detection instead of suppressing forever. Not configurable —
  /// no new knobs.
  static const Duration _maxProbeSuppression = Duration(minutes: 2);

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  /// Shuffled round-robin order for main probe selection, with a cursor.
  ///
  /// Rebuilt (reshuffled) from the current probable set whenever the cursor
  /// exhausts it. This guarantees every probable peer is probed once per
  /// cycle — worst-case time-to-probe a specific peer is ~(n-1) rounds —
  /// instead of pure-random selection's geometric coverage (which makes
  /// SWIM detection latency scale O(n · threshold)). Ids no longer probable
  /// (removed, held, gone unreachable) are skipped; newly probable peers
  /// join at the next reshuffle.
  final List<NodeId> _probeOrder = [];
  int _probeOrderIndex = 0;

  int _unreachableProbeIndex = 0;

  /// Tracks peers that are temporarily held from failure detection probing.
  ///
  /// Key: peer NodeId, Value: timestamp (ms since epoch) until which the
  /// peer should be excluded from probe selection.
  ///
  /// This is a protocol-layer concern: newly connected peers get a grace
  /// period before being subject to failure detection, preventing false
  /// positives during connection establishment.
  final Map<NodeId, int> _probingHeldUntil = {};

  /// Timestamp (ms since epoch) of the last time the detector actually sent
  /// this peer a probe Ping, recorded via [recordProbeAttempt]. Distinct
  /// from [Peer.lastContactMs] (inbound evidence only): this tracks the
  /// detector's own outbound attempts, so [nextProbeTarget] can bound how
  /// long freshness alone may suppress a peer (see [_maxProbeSuppression]).
  ///
  /// A missing entry means "never probed" — on a real device `nowMs` is a
  /// huge wall-clock epoch reading, so treating a missing entry as 0 makes
  /// a never-probed peer immediately cap-expired (probe-eligible), matching
  /// cold-start expectations.
  final Map<NodeId, int> _lastProbeAttemptMs = {};

  // ---------------------------------------------------------------------------
  // Probing hold (startup grace period)
  // ---------------------------------------------------------------------------

  /// Sets a probing hold for a peer until the given timestamp.
  ///
  /// The peer is excluded from [nextProbeTarget] selection until
  /// [holdUntilMs] is reached. This provides a grace period for newly
  /// connected peers while the transport layer stabilizes.
  ///
  /// Call [clearProbingHold] to remove the hold early (e.g., once the
  /// caller confirms connectivity).
  void setProbingHold(NodeId peerId, int holdUntilMs) {
    _probingHeldUntil[peerId] = holdUntilMs;
  }

  /// Clears any probing hold for a peer, making it eligible for
  /// [nextProbeTarget] again.
  void clearProbingHold(NodeId peerId) {
    _probingHeldUntil.remove(peerId);
  }

  /// Returns true if the peer currently has an active probing hold.
  bool hasProbingHold(NodeId peerId) {
    final holdUntil = _probingHeldUntil[peerId];
    if (holdUntil == null) return false;
    return timePort.nowMs < holdUntil;
  }

  /// Drops all per-peer bookkeeping for a peer that has been removed from
  /// the system entirely.
  ///
  /// Unlike [clearProbingHold] — which is also called when connectivity is
  /// merely *confirmed*, and so must not touch probe-attempt history — this
  /// is for actual removal: the peer is gone, so its probing hold and its
  /// [_maxProbeSuppression] tracking are both moot and would otherwise
  /// accumulate under peer churn.
  void forgetPeer(NodeId peerId) {
    _probingHeldUntil.remove(peerId);
    _lastProbeAttemptMs.remove(peerId);
  }

  // ---------------------------------------------------------------------------
  // Selection
  // ---------------------------------------------------------------------------

  /// Selects the next peer to probe (reachable or suspected), round-robin
  /// over a shuffled order.
  ///
  /// Includes suspected peers so they can recover by responding to probes.
  /// Peers with an active probing hold are excluded to prevent false
  /// positives during connection startup. [freshnessWindow] suppresses
  /// peers already proven alive by recent inbound traffic (WIRE4-3) — see
  /// the eligibility filter below for the suppression-cap rationale.
  ///
  /// Selection cycles through a shuffled permutation of the probable set:
  /// every peer is probed exactly once per cycle, then the set is
  /// reshuffled. This bounds the worst-case time to probe a specific
  /// (e.g. silently-dead) peer to ~(n-1) rounds — pure-random selection
  /// would give a geometric distribution with a long tail, the root of
  /// H3's O(n · threshold) detection latency.
  Peer? nextProbeTarget({required Duration freshnessWindow}) {
    final nowMs = timePort.nowMs;
    final intervalMs = freshnessWindow.inMilliseconds;
    final maxSuppressionMs = _maxProbeSuppression.inMilliseconds;
    final probable = peerRegistry.probablePeers.where((p) {
      final holdUntil = _probingHeldUntil[p.id];
      if (holdUntil != null && nowMs < holdUntil) return false;
      // Suppression (WIRE4-3): any inbound message already proved this
      // peer alive within the current interval — a probe adds nothing.
      final isFresh = nowMs - p.lastContactMs < intervalMs;
      if (!isFresh) return true;
      // Cap: freshness alone keys on INBOUND evidence, which
      // under asymmetric one-way loss can be perpetually refreshed by the
      // peer's own traffic (e.g. it probing us) even though OUR probes to
      // IT are the ones dying — suppressing forever and never detecting
      // the failure. Bound it: a peer we haven't actually probed in
      // _maxProbeSuppression is probe-eligible regardless of freshness.
      // A missing entry (never probed) reads as 0, so on a real device
      // (huge wall-clock nowMs) a brand-new peer is immediately eligible —
      // consistent with cold start.
      final lastAttempt = _lastProbeAttemptMs[p.id] ?? 0;
      final capExpired = nowMs - lastAttempt >= maxSuppressionMs;
      return capExpired;
    }).toList();
    if (probable.isEmpty) return null;

    final byId = {for (final p in probable) p.id: p};

    // Advance the cursor, skipping ids that are no longer probable
    // (removed / held / gone unreachable since the last reshuffle).
    while (_probeOrderIndex < _probeOrder.length) {
      final peer = byId[_probeOrder[_probeOrderIndex++]];
      if (peer != null) return peer;
    }

    // Cycle exhausted (or first call / membership changed): reshuffle the
    // current probable set and begin a fresh cycle.
    _probeOrder
      ..clear()
      ..addAll(byId.keys)
      ..shuffle(_random);
    _probeOrderIndex = 0;
    return byId[_probeOrder[_probeOrderIndex++]];
  }

  /// Round-robins over [PeerRegistry.unreachablePeers], returning the next
  /// target for periodic recovery probing. Returns null when there are no
  /// unreachable peers.
  ///
  /// Wraps the cursor into range first, so index drift from membership
  /// changes (a peer recovering or being removed) since the last call
  /// can't throw or silently skip past the end of the list.
  Peer? nextUnreachableTarget() {
    final unreachable = peerRegistry.unreachablePeers;
    if (unreachable.isEmpty) return null;

    _unreachableProbeIndex = _unreachableProbeIndex % unreachable.length;
    final peer = unreachable[_unreachableProbeIndex];
    _unreachableProbeIndex = (_unreachableProbeIndex + 1) % unreachable.length;
    return peer;
  }

  /// Picks up to [count] reachable peers, excluding [target], to relay an
  /// indirect ping when a direct probe to [target] fails.
  List<Peer> selectIntermediaries(NodeId target, int count) {
    final candidates = peerRegistry.reachablePeers
        .where((p) => p.id != target)
        .toList();
    if (candidates.isEmpty) return [];

    final numToSelect = min(count, candidates.length);
    final selected = <Peer>[];
    for (var i = 0; i < numToSelect; i++) {
      final index = _random.nextInt(candidates.length);
      selected.add(candidates.removeAt(index));
    }
    return selected;
  }

  // ---------------------------------------------------------------------------
  // Probe-attempt bookkeeping
  // ---------------------------------------------------------------------------

  /// Stamps [peerId] as actually probed at [nowMs], resetting the
  /// suppression-cap clock ([_maxProbeSuppression]) that bounds how long
  /// [nextProbeTarget] may treat it as fresh-and-skippable.
  void recordProbeAttempt(NodeId peerId, int nowMs) {
    _lastProbeAttemptMs[peerId] = nowMs;
  }
}
