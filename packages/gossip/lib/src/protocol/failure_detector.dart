import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:gossip/src/application/observability/log_level.dart';
import 'package:gossip/src/domain/errors/sync_error.dart';
import 'package:gossip/src/domain/services/jitter.dart';
import 'package:gossip/src/domain/services/quiescence_pacer.dart';
import 'package:gossip/src/domain/services/rtt_tracker.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/domain/entities/peer.dart';
import 'package:gossip/src/membership/domain/events/membership_events.dart';
import 'package:gossip/src/infrastructure/ports/time_port.dart';
import 'package:gossip/src/infrastructure/ports/message_port.dart';
import 'package:gossip/src/protocol/protocol_codec.dart';
import 'package:gossip/src/protocol/messages/ping.dart';
import 'package:gossip/src/protocol/messages/ack.dart';
import 'package:gossip/src/protocol/messages/ping_req.dart';

/// Tracks a pending ping awaiting Ack response.
///
/// Used to match incoming Acks with outgoing Pings by sequence number.
/// The [completer] resolves to true when Ack is received, enabling timeout
/// handling via Future.timeout().
///
/// Supports both direct pings (local → target) and indirect pings
/// (local → intermediary → target → intermediary → local).
class _PendingPing {
  final NodeId target;
  final int sequence;
  final int sentAtMs;

  /// Whether a forwarded Ack (sender != target) may complete this ping.
  ///
  /// True only for indirect-phase pings, where intermediaries answer on
  /// the target's behalf. Direct pings require the Ack sender to be the
  /// probed target — otherwise a stale Ack with a colliding sequence
  /// from an unrelated peer would mark the wrong peer alive.
  final bool allowForwarded;

  final Completer<bool> completer;

  _PendingPing({
    required this.target,
    required this.sequence,
    required this.sentAtMs,
    this.allowForwarded = false,
  }) : completer = Completer<bool>();
}

/// Protocol service implementing SWIM failure detection.
///
/// Detects peer failures through periodic probing with automatic fallback
/// to indirect probing. Implements the SWIM (Scalable Weakly-consistent
/// Infection-style Process Group Membership) protocol.
///
/// ## Protocol Flow
///
/// **Probe Round (adaptive interval)**:
/// 1. Select random reachable peer
/// 2. Send direct Ping
/// 3. Wait for Ack (per-peer RTT-adaptive timeout)
/// 4. If no Ack, initiate indirect ping via intermediaries
///
/// **Indirect Ping (when direct probe fails)**:
/// 1. Select up to 3 other reachable peers as intermediaries
/// 2. Send PingReq to each intermediary
/// 3. Intermediaries ping the target and forward any Ack back
/// 4. Wait for Ack via any intermediary
/// 5. If no Ack, increment failed probe count
///
/// **Failure Detection**:
/// - After [failureThreshold] consecutive failures, mark peer as suspected
/// - After [unreachableThreshold] consecutive failures, mark suspected peer
///   as unreachable (excluded from probing and gossip)
/// - Suspected peers can recover by responding to future probes
/// - Unreachable peers are periodically probed (every [unreachableProbeInterval]
///   rounds) to detect transport recovery without requiring explicit reconnection
/// - Unreachable peers also recover via transport reconnection (incoming Ping
///   or re-adding the peer)
///
/// ## Lifecycle
///
/// Call [start] to begin probe rounds and [startListening] to handle
/// incoming messages. Both are independent; typically both are started
/// together.
class FailureDetector {
  // ---------------------------------------------------------------------------
  // Construction & configuration
  // ---------------------------------------------------------------------------

  final NodeId localNode;
  final PeerRegistry peerRegistry;
  final int failureThreshold;
  final int unreachableThreshold;
  final int unreachableProbeInterval;
  final TimePort timePort;
  final MessagePort messagePort;
  final ErrorCallback? onError;
  final LogCallback? onLog;

  final Duration _pingTimeout;
  final Duration _probeInterval;
  final RttTracker _rttTracker;

  /// Whether a static ping timeout / probe interval was supplied. Tracked
  /// independently: passing one static knob must NOT disable adaptive
  /// timing on the other (a static `probeInterval` must not pin the ping
  /// timeout at its 500ms fallback — the ADR-013 regression).
  final bool _staticPingTimeoutProvided;
  final bool _staticProbeIntervalProvided;
  final Random _random;
  final ProtocolCodec _codec = ProtocolCodec();

  FailureDetector({
    required this.localNode,
    required this.peerRegistry,
    this.failureThreshold = 3,
    this.unreachableThreshold = 9,
    this.unreachableProbeInterval = 5,
    required this.timePort,
    required this.messagePort,
    this.onError,
    this.onLog,
    Duration? pingTimeout,
    Duration? probeInterval,
    Random? random,
    RttTracker? rttTracker,
  }) : _pingTimeout = pingTimeout ?? const Duration(milliseconds: 500),
       _probeInterval = probeInterval ?? const Duration(milliseconds: 1000),
       _random = random ?? Random(),
       _rttTracker = rttTracker ?? RttTracker(),
       _staticPingTimeoutProvided = pingTimeout != null,
       _staticProbeIntervalProvided = probeInterval != null;

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------

  static const Duration _minPingTimeout = Duration(milliseconds: 500);
  static const Duration _maxPingTimeout = Duration(seconds: 10);
  static const Duration _minProbeInterval = Duration(milliseconds: 500);
  static const Duration _maxProbeInterval = Duration(seconds: 30);
  static const int _probeIntervalMultiplier = 3;

  /// Hard cap on how long freshness alone may suppress a probe (final
  /// review, item 2): 4× the 30 s ceiling. Freshness-only suppression
  /// (below) keys on INBOUND evidence — under asymmetric one-way loss
  /// (our probes to a peer die, but the peer's own traffic to us, e.g. its
  /// own unreachable-probing of us, keeps arriving) that inbound evidence
  /// never stops, so we would never probe the peer and never detect the
  /// failure. This bounds half-open detection instead of suppressing
  /// forever. Not configurable — no new knobs.
  static const Duration _maxProbeSuppression = Duration(minutes: 2);

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  /// Two-tier pacing for the probe loop (spec 2026-08-20).
  ///
  /// Independent from GossipEngine's pacer instance: each protocol loop
  /// paces its own cadence toward its own ceiling. All-healthy rounds
  /// stretch [effectiveProbeInterval] toward [_maxProbeInterval]; a full
  /// miss or a membership change (new peer, recovery) snaps it back.
  final QuiescencePacer _pacer = QuiescencePacer(ceiling: _maxProbeInterval);

  bool _isRunning = false;

  /// Generation token for the probe round loop.
  ///
  /// Incremented on every [start] and [stop] so that delay callbacks
  /// scheduled by a previous run become stale and cannot fork a second
  /// concurrent probe loop when the detector is restarted within one
  /// interval (e.g. Coordinator pause()/resume()).
  int _generation = 0;
  int _nextSequence = 1;
  int _unreachableProbeCounter = 0;
  int _unreachableProbeIndex = 0;

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
  StreamSubscription<IncomingMessage>? _messageSubscription;
  final Map<int, _PendingPing> _pendingPings = {};
  int _acksReceived = 0;
  int _pingsSent = 0;

  /// Tracks peers that are temporarily held from failure detection probing.
  ///
  /// Key: peer NodeId, Value: timestamp (ms since epoch) until which the
  /// peer should be excluded from probe selection.
  ///
  /// This is a protocol-layer concern: newly connected peers get a grace
  /// period before being subject to failure detection, preventing false
  /// positives during connection establishment.
  final Map<NodeId, int> _probingHeldUntil = {};

  /// Timestamp (ms since epoch) of the last time we actually sent this peer
  /// a probe Ping — via [performProbeRound], [probeNewPeer], or
  /// [_probeUnreachablePeer] (all funnel through [_sendPing]). Distinct from
  /// [Peer.lastContactMs] (inbound evidence only): this tracks our own
  /// outbound attempts, so [selectRandomPeer] can bound how long freshness
  /// alone may suppress a peer (item 2 — see [_maxProbeSuppression]).
  ///
  /// A missing entry means "never probed" — on a real device `nowMs` is a
  /// huge wall-clock epoch reading, so treating a missing entry as 0 makes
  /// a never-probed peer immediately cap-expired (probe-eligible), matching
  /// cold-start expectations.
  final Map<NodeId, int> _lastProbeAttemptMs = {};

  // ---------------------------------------------------------------------------
  // Public API: probing hold (startup grace period)
  // ---------------------------------------------------------------------------

  /// Sets a probing hold for a peer until the given timestamp.
  ///
  /// The peer will be excluded from failure detection probing until
  /// [holdUntilMs] is reached. This provides a grace period for newly
  /// connected peers while the transport layer stabilizes.
  ///
  /// Call [clearProbingHold] to remove the hold early (e.g., when
  /// [probeNewPeer] confirms connectivity).
  void setProbingHold(NodeId peerId, int holdUntilMs) {
    _probingHeldUntil[peerId] = holdUntilMs;
  }

  /// Clears any probing hold for a peer, making them eligible for probing.
  ///
  /// Typically called when [probeNewPeer] succeeds, confirming the peer
  /// is reachable and the transport layer is working.
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
  /// Unlike [clearProbingHold] — which is also called when [probeNewPeer]
  /// merely *confirms* connectivity, and so must not touch probe-attempt
  /// history — this is for actual removal: the peer is gone, so its
  /// probing hold and its [_maxProbeSuppression] tracking (item 2) are
  /// both moot and would otherwise accumulate under peer churn.
  void forgetPeer(NodeId peerId) {
    _probingHeldUntil.remove(peerId);
    _lastProbeAttemptMs.remove(peerId);
  }

  // ---------------------------------------------------------------------------
  // Public API: adaptive timing
  // ---------------------------------------------------------------------------

  bool get isRunning => _isRunning;

  RttTracker get rttTracker => _rttTracker;

  /// Effective ping timeout from global RTT estimate.
  ///
  /// Falls back to static timeout if one was provided at construction.
  Duration get effectivePingTimeout {
    if (_staticPingTimeoutProvided) return _pingTimeout;
    return _rttTracker.suggestedTimeout(
      minTimeout: _minPingTimeout,
      maxTimeout: _maxPingTimeout,
    );
  }

  /// Per-peer ping timeout, falling back to global estimate.
  ///
  /// Uses the peer's own RTT estimate if available, otherwise uses the
  /// global [effectivePingTimeout]. This lets fast peers use shorter
  /// timeouts while slow peers get longer ones.
  Duration effectivePingTimeoutForPeer(NodeId peerId) {
    if (_staticPingTimeoutProvided) return _pingTimeout;
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
  /// Computed as 3× the effective ping timeout to allow time for both
  /// direct and indirect probes within each interval, then paced: quiet
  /// (all-answered) rounds stretch this toward [_maxProbeInterval]; a miss
  /// or membership change snaps it back to the formula's raw value. A
  /// static override bypasses the pacer entirely.
  Duration get effectiveProbeInterval {
    if (_staticProbeIntervalProvided) return _probeInterval;
    final baseInterval = effectivePingTimeout * _probeIntervalMultiplier;
    final clampedBase = baseInterval < _minProbeInterval
        ? _minProbeInterval
        : (baseInterval > _maxProbeInterval ? _maxProbeInterval : baseInterval);
    return _pacer.apply(clampedBase);
  }

  // ---------------------------------------------------------------------------
  // Public API: lifecycle
  // ---------------------------------------------------------------------------

  /// Starts periodic probe rounds at adaptive intervals.
  void start() {
    if (_isRunning) return;
    _isRunning = true;
    // A restart is news — never resume mid-backoff into a stale world.
    _pacer.news();
    _generation++;
    _scheduleNextProbeRound(_generation);
  }

  /// Stops periodic probe rounds.
  void stop() {
    if (!_isRunning) return;
    _isRunning = false;
    _generation++;
  }

  /// Starts listening to incoming SWIM protocol messages.
  ///
  /// Safe to call repeatedly: any previous subscription is cancelled
  /// first so messages are never processed twice.
  void startListening() {
    _messageSubscription?.cancel();
    _messageSubscription = messagePort.incoming.listen(
      _handleIncomingMessage,
      // Without onError, one transport stream error becomes an uncaught
      // zone error and permanently cancels SWIM message handling.
      onError: (Object error, StackTrace stackTrace) {
        _emitError(
          PeerSyncError(
            localNode,
            SyncErrorType.protocolError,
            'Transport stream error: $error',
            occurredAt: DateTime.now(),
            cause: error,
          ),
        );
      },
    );
  }

  /// Stops listening to incoming messages.
  void stopListening() {
    _messageSubscription?.cancel();
    _messageSubscription = null;
  }

  // ---------------------------------------------------------------------------
  // Public API: probing
  // ---------------------------------------------------------------------------

  /// Performs a single probe round.
  ///
  /// 1. Select random reachable peer
  /// 2. Send direct Ping
  /// 3. Wait for Ack (per-peer timeout)
  /// 4. If no Ack, fall back to indirect ping
  /// 5. Check if late Ack arrived during indirect phase
  Future<void> performProbeRound() async {
    // Periodically probe one unreachable peer for recovery.
    if (unreachableProbeInterval > 0) {
      _unreachableProbeCounter++;
      if (_unreachableProbeCounter >= unreachableProbeInterval) {
        _unreachableProbeCounter = 0;
        await _probeUnreachablePeer();
      }
    }

    // Regular probe round: select reachable or suspected peer.
    final peer = selectRandomPeer();
    if (peer == null) {
      // Nothing needs probing (empty registry or everyone fresh) —
      // that is quiescence, not a stall.
      if (peerRegistry.probablePeers.isNotEmpty) _pacer.quietRound();
      return;
    }

    final sequence = _nextSequence++;
    final pending = _trackPendingPing(peer.id, sequence);
    try {
      await _sendPing(peer.id, sequence);

      final gotDirectAck = await _awaitAckWithTimeout(
        pending,
        sequence,
        effectivePingTimeoutForPeer(peer.id),
      );

      if (!gotDirectAck) {
        final gotIndirectAck = await _performIndirectPing(peer.id);
        _evaluateProbeOutcome(peer.id, sequence, pending, gotIndirectAck);
      } else {
        // If something else already called news() earlier in this same
        // round (e.g. a different peer's contact recovering it from
        // suspected), this quietRound() still runs right after — netting
        // a multiplier of 1.5x base rather than staying at 1x. Accepted:
        // it self-corrects, since the next quiet round continues growing
        // from wherever this landed, and the next real news() resets it
        // to 1 regardless.
        _pacer.quietRound();
      }
    } finally {
      // Always drop the pending entry — a throw above must not leave a
      // permanently matchable sequence in the map.
      _cleanupPendingPing(sequence);
    }
  }

  /// Probes a specific newly-connected peer to bootstrap its RTT estimate.
  ///
  /// Returns true if an Ack was received, false on timeout. No failure is
  /// recorded on timeout — this is best-effort RTT bootstrapping, not
  /// failure detection. No indirect ping is attempted.
  ///
  /// Called fire-and-forget from Coordinator.addPeer() to get the first
  /// RTT sample quickly instead of waiting for random probe selection.
  Future<bool> probeNewPeer(NodeId peerId) async {
    _pacer.news();
    final peer = peerRegistry.getPeer(peerId);
    if (peer == null) return false;

    final sequence = _nextSequence++;
    final pending = _trackPendingPing(peerId, sequence);
    final bool gotAck;
    try {
      await _sendPing(peerId, sequence);

      gotAck = await _awaitAckWithTimeout(
        pending,
        sequence,
        effectivePingTimeoutForPeer(peerId),
      );
    } finally {
      _cleanupPendingPing(sequence);
    }

    if (gotAck) {
      _log('probeNewPeer got Ack from $peerId');
    } else {
      _log('probeNewPeer timed out for $peerId (no failure recorded)');
    }

    return gotAck;
  }

  /// Probes one unreachable peer on a round-robin schedule.
  ///
  /// Called every [unreachableProbeInterval] probe rounds to detect
  /// transport recovery for peers stuck in unreachable state. This breaks
  /// mutual-unreachable deadlocks where both sides have marked each other
  /// unreachable and neither sends messages.
  ///
  /// Like [probeNewPeer], this is best-effort: no failure is recorded on
  /// timeout since the peer is already unreachable. Falls back to indirect
  /// ping via intermediaries, which is critical for 3+ device scenarios
  /// where a third peer can relay the probe.
  ///
  /// Recovery happens via the existing path: if the peer responds with an
  /// Ack, [handleAck] → [_recordPeerContact] → [updatePeerContact]
  /// transitions it back to reachable.
  Future<void> _probeUnreachablePeer() async {
    final unreachable = peerRegistry.unreachablePeers;
    if (unreachable.isEmpty) return;

    // Round-robin: wrap index if peers changed since last probe.
    _unreachableProbeIndex = _unreachableProbeIndex % unreachable.length;
    final peer = unreachable[_unreachableProbeIndex];
    _unreachableProbeIndex = (_unreachableProbeIndex + 1) % unreachable.length;

    _log('Probing unreachable peer ${peer.id} (best-effort recovery)');

    final sequence = _nextSequence++;
    final pending = _trackPendingPing(peer.id, sequence);
    try {
      await _sendPing(peer.id, sequence);

      final gotDirectAck = await _awaitAckWithTimeout(
        pending,
        sequence,
        effectivePingTimeoutForPeer(peer.id),
      );

      if (!gotDirectAck) {
        // Indirect ping: ask intermediaries to probe on our behalf.
        // In 2-device scenarios this finds no intermediaries and returns
        // false.
        final gotIndirectAck = await _performIndirectPing(peer.id);
        final recovered = gotIndirectAck || pending.completer.isCompleted;

        if (recovered) {
          // The forwarded Ack has the intermediary as sender, so handleAck()
          // only updated the intermediary's contact. Explicitly recover the
          // target peer.
          _recordPeerContact(peer.id, timePort.nowMs);
          _log('Unreachable peer ${peer.id} responded (indirect) — recovered');
        } else {
          _log(
            'Unreachable peer ${peer.id} did not respond (still unreachable)',
          );
        }
        return;
      }

      _log('Unreachable peer ${peer.id} responded — recovered to reachable');
    } finally {
      _cleanupPendingPing(sequence);
    }
  }

  /// Selects the next peer to probe (reachable or suspected), round-robin
  /// over a shuffled order.
  ///
  /// Includes suspected peers so they can recover by responding to probes.
  /// Peers with an active probing hold are excluded to prevent false
  /// positives during connection startup.
  ///
  /// Selection cycles through a shuffled permutation of the probable set:
  /// every peer is probed exactly once per cycle, then the set is
  /// reshuffled. This bounds the worst-case time to probe a specific
  /// (e.g. silently-dead) peer to ~(n-1) rounds — pure-random selection
  /// would give a geometric distribution with a long tail, the root of
  /// H3's O(n · threshold) detection latency.
  Peer? selectRandomPeer() {
    final nowMs = timePort.nowMs;
    final intervalMs = effectiveProbeInterval.inMilliseconds;
    final maxSuppressionMs = _maxProbeSuppression.inMilliseconds;
    final probable = peerRegistry.probablePeers.where((p) {
      final holdUntil = _probingHeldUntil[p.id];
      if (holdUntil != null && nowMs < holdUntil) return false;
      // Suppression (WIRE4-3): any inbound message already proved this
      // peer alive within the current interval — a probe adds nothing.
      final isFresh = nowMs - p.lastContactMs < intervalMs;
      if (!isFresh) return true;
      // Cap (item 2): freshness alone keys on INBOUND evidence, which
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

  // ---------------------------------------------------------------------------
  // Public API: message handlers (public for testing)
  // ---------------------------------------------------------------------------

  /// Handles incoming Ping by returning Ack with matching sequence.
  Ack handlePing(Ping ping) {
    return Ack(sender: localNode, sequence: ping.sequence);
  }

  /// Handles incoming Ack: updates peer contact and records RTT.
  ///
  /// RTT is attributed to the probe target (from `_PendingPing.target`),
  /// not `ack.sender` — because forwarded indirect Acks have the
  /// intermediary as sender, not the original target.
  ///
  /// Acks that don't match a pending ping are silently ignored. This is
  /// normal when: (a) a very-late ack arrives after cleanup, (b) both
  /// direct and indirect acks arrive for the same probe, or (c) a
  /// forwarded ack races with a direct ack. The peer contact timestamp
  /// is still updated regardless.
  void handleAck(Ack ack, {required int timestampMs}) {
    _recordPeerContact(ack.sender, timestampMs);

    final pending = _pendingPings[ack.sequence];
    if (pending == null || pending.completer.isCompleted) {
      return;
    }

    // Direct pings may only be confirmed by the probed target itself.
    // A stale Ack with a colliding sequence from an unrelated peer (e.g.
    // after a detector rebuild reset the sequence counter) must not mark
    // a possibly-dead target alive. Forwarded Acks (indirect phase) are
    // legitimately sent by intermediaries and are exempt.
    if (!pending.allowForwarded && ack.sender != pending.target) {
      _log(
        'Ignoring Ack seq=${ack.sequence} from ${ack.sender}: '
        'pending ping targets ${pending.target}',
      );
      return;
    }

    _recordRtt(pending, ack.sender, timestampMs);
    pending.completer.complete(true);
  }

  /// Records a failed probe attempt for a peer.
  void recordProbeFailure(NodeId peerId) {
    peerRegistry.incrementFailedProbeCount(peerId);
  }

  /// Transitions peer status based on consecutive probe failure count.
  ///
  /// - `reachable → suspected` at [failureThreshold]
  /// - `suspected → unreachable` at [unreachableThreshold]
  ///
  /// Recovery (→ reachable) is handled separately via [_recordPeerContact]
  /// when the peer responds. SWIM incarnation/refutation is deliberately not
  /// implemented: this deployment relies on the transport's fast membership
  /// oracle and per-contact recovery instead.
  void checkPeerHealth(NodeId peerId, {required DateTime occurredAt}) {
    final peer = peerRegistry.getPeer(peerId);
    if (peer == null) return;

    if (peer.failedProbeCount >= unreachableThreshold &&
        peer.status == PeerStatus.suspected) {
      _log(
        'Peer $peerId transitioning to UNREACHABLE '
        '(failed probes: ${peer.failedProbeCount}, '
        'threshold: $unreachableThreshold)',
      );
      peerRegistry.updatePeerStatus(
        peerId,
        PeerStatus.unreachable,
        occurredAt: occurredAt,
      );
    } else if (peer.failedProbeCount >= failureThreshold &&
        peer.status == PeerStatus.reachable) {
      _log(
        'Peer $peerId transitioning to SUSPECTED '
        '(failed probes: ${peer.failedProbeCount}, '
        'threshold: $failureThreshold)',
      );
      peerRegistry.updatePeerStatus(
        peerId,
        PeerStatus.suspected,
        occurredAt: occurredAt,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Private: probe round internals
  // ---------------------------------------------------------------------------

  /// Schedules the next probe round.
  ///
  /// [generation] identifies the run that scheduled this callback; if it
  /// no longer matches [_generation] when the delay fires, the detector
  /// was stopped (and possibly restarted) in the meantime and this stale
  /// callback must not run a round or reschedule itself.
  void _scheduleNextProbeRound(int generation) {
    if (!_isRunning || generation != _generation) return;
    // ±20% jitter decorrelates probe loops across nodes so they don't
    // phase-lock into correlated bursts (and correlated false suspicions).
    timePort
        .delay(applyJitter(effectiveProbeInterval, _random))
        .then((_) {
          if (_isRunning && generation == _generation) _probeRound(generation);
        })
        .catchError((Object error, StackTrace stackTrace) {
          // A broken timer must not kill the loop silently: surface the error
          // and stop so isRunning reflects reality.
          if (generation == _generation) {
            _isRunning = false;
            _generation++;
          }
          _emitError(
            PeerSyncError(
              localNode,
              SyncErrorType.protocolError,
              'Probe round scheduling failed: $error',
              occurredAt: DateTime.now(),
              cause: error,
            ),
          );
        });
  }

  void _probeRound(int generation) {
    performProbeRound()
        .catchError((error, stackTrace) {
          _emitError(
            PeerSyncError(
              localNode,
              SyncErrorType.protocolError,
              'Probe round failed: $error',
              occurredAt: DateTime.now(),
              cause: error,
            ),
          );
        })
        .whenComplete(() => _scheduleNextProbeRound(generation));
  }

  /// Evaluates the outcome after a direct ping timeout + indirect phase.
  void _evaluateProbeOutcome(
    NodeId target,
    int sequence,
    _PendingPing directPending,
    bool gotIndirectAck,
  ) {
    if (gotIndirectAck || directPending.completer.isCompleted) {
      // Either indirect succeeded or a late direct Ack arrived.
      if (directPending.completer.isCompleted && !gotIndirectAck) {
        _log(
          'Late Ack arrived for seq=$sequence from $target '
          '(recovered during indirect ping phase)',
        );
      }
      // A forwarded indirect Ack carries the intermediary as sender, so
      // handleAck only updated the intermediary's contact. Record contact
      // for the target explicitly — otherwise a peer reachable only via
      // intermediaries stays suspected forever (excluded from gossip,
      // never unreachable, never recovered).
      _recordPeerContact(target, timePort.nowMs);
      _pacer.quietRound();
      return;
    }
    _handleProbeFailure(target);
  }

  /// Performs indirect ping when direct ping fails.
  ///
  /// Sends PingReq to up to 3 intermediaries asking them to probe the
  /// target. When no intermediaries are available (2-device scenario),
  /// waits for a grace period to allow late Acks to arrive.
  Future<bool> _performIndirectPing(NodeId target) async {
    final intermediaries = _selectRandomIntermediaries(target, 3);
    final peerTimeout = effectivePingTimeoutForPeer(target);

    if (intermediaries.isEmpty) {
      await timePort.delay(peerTimeout);
      return false;
    }

    final indirectSeq = _nextSequence++;
    final pending = _trackPendingPing(
      target,
      indirectSeq,
      allowForwarded: true,
    );
    try {
      await _sendPingRequests(intermediaries, target, indirectSeq);

      return await _awaitAckWithTimeout(pending, indirectSeq, peerTimeout);
    } finally {
      _cleanupPendingPing(indirectSeq);
    }
  }

  void _handleProbeFailure(NodeId target) {
    _pacer.news();
    final peer = peerRegistry.getPeer(target);
    final failedCount = peer?.failedProbeCount ?? 0;
    _log(
      'Probe FAILED for $target '
      '(failed count: $failedCount -> ${failedCount + 1}, '
      'threshold: $failureThreshold, '
      'pings sent: $_pingsSent, acks received: $_acksReceived)',
    );
    recordProbeFailure(target);
    checkPeerHealth(target, occurredAt: DateTime.now());
  }

  // ---------------------------------------------------------------------------
  // Private: message handling
  // ---------------------------------------------------------------------------

  Future<void> _handleIncomingMessage(IncomingMessage message) async {
    // Deliberately NOT recording receive metrics here: GossipEngine
    // subscribes to the same incoming stream and is the single
    // designated recording point — both engines recording would double
    // every rate/byte metric applications throttle on.
    try {
      final protocolMessage = _codec.decode(message.bytes);

      if (protocolMessage is Ping) {
        await _handleIncomingPing(protocolMessage, message.sender);
      } else if (protocolMessage is Ack) {
        _handleIncomingAck(protocolMessage);
      } else if (protocolMessage is PingReq) {
        await _handlePingReq(protocolMessage, message.sender);
      }
    } catch (e) {
      _emitError(
        PeerSyncError(
          message.sender,
          SyncErrorType.messageCorrupted,
          'Malformed SWIM message from ${message.sender}: $e',
          occurredAt: DateTime.now(),
          cause: e,
        ),
      );
    }
  }

  Future<void> _handleIncomingPing(Ping ping, NodeId sender) async {
    _log('Received Ping from $sender seq=${ping.sequence}');
    _recordPeerContact(sender, timePort.nowMs);
    final ack = handlePing(ping);
    final ackBytes = _codec.encode(ack);
    await _safeSend(sender, ackBytes, 'Ack');
    _log('Sent Ack to $sender seq=${ack.sequence}');
  }

  void _handleIncomingAck(Ack ack) {
    _acksReceived++;
    _log('Received Ack from ${ack.sender} seq=${ack.sequence}');
    handleAck(ack, timestampMs: timePort.nowMs);
  }

  /// Intermediary role: ping target on behalf of requester, forward Ack back.
  Future<void> _handlePingReq(PingReq pingReq, NodeId requester) async {
    _log(
      'Received PingReq from $requester '
      'target=${pingReq.target} seq=${pingReq.sequence}',
    );

    // Use a LOCAL sequence number for the intermediary's Ping to the target.
    // The prober's sequence (pingReq.sequence) is only echoed back in the
    // forwarded Ack. Using the prober's sequence would collide with the
    // intermediary's own pending pings in _pendingPings.
    final localSeq = _nextSequence++;
    final pending = _trackPendingPing(pingReq.target, localSeq);

    final bool gotAck;
    try {
      final ping = Ping(sender: localNode, sequence: localSeq);
      await _safeSend(pingReq.target, _codec.encode(ping), 'Ping');

      // Adaptive per-target timeout, not a fixed 500ms: on BLE a target's
      // RTT can exceed 500ms, and a fixed timeout made the intermediary
      // abandon the relay before the target could answer — wasting the
      // whole indirect phase while the requester still waited out its own
      // (longer) timeout.
      gotAck = await _awaitAckWithTimeout(
        pending,
        localSeq,
        effectivePingTimeoutForPeer(pingReq.target),
      );
    } finally {
      _cleanupPendingPing(localSeq);
    }

    if (gotAck) {
      final ack = Ack(sender: localNode, sequence: pingReq.sequence);
      await _safeSend(requester, _codec.encode(ack), 'forwarded Ack');
    }
  }

  // ---------------------------------------------------------------------------
  // Private: RTT recording
  // ---------------------------------------------------------------------------

  /// Records an RTT sample from a matched Ack.
  ///
  /// RTT is attributed to [pending.target] (the peer being probed), not
  /// [ackSender] — forwarded indirect Acks have the intermediary as sender.
  ///
  /// All valid RTT samples are recorded regardless of whether they exceeded
  /// the timeout. Unlike TCP (where Karn's algorithm avoids ambiguity between
  /// original and retransmitted segments), SWIM pings have unique sequence
  /// numbers so every Ack is unambiguously matched. Recording all samples
  /// lets the EWMA adapt upward when latency increases, preventing a
  /// survivorship bias where only fast samples feed the estimate.
  /// Clamp bounds for RTT samples, mirroring [RttTracker]'s internal
  /// clamping so the per-peer estimates get the same protection against
  /// wall-clock jumps and sub-physical readings.
  static const Duration _minRttSample = Duration(milliseconds: 50);
  static const Duration _maxRttSample = Duration(seconds: 30);

  void _recordRtt(_PendingPing pending, NodeId ackSender, int timestampMs) {
    final rttMs = timestampMs - pending.sentAtMs;

    if (rttMs <= 0) return;

    var rttSample = Duration(milliseconds: rttMs);
    if (rttSample < _minRttSample) rttSample = _minRttSample;
    if (rttSample > _maxRttSample) rttSample = _maxRttSample;

    _rttTracker.recordSample(rttSample);
    // A forwarded Ack (indirect phase) measures the 2-hop path
    // requester → intermediary → target → back. Attributing it to the
    // target would systematically inflate its per-peer estimate; only
    // Acks from the target itself count as direct samples.
    if (ackSender == pending.target) {
      peerRegistry.recordPeerRtt(pending.target, rttSample);
    }
    _log(
      'Ack seq=${pending.sequence} from $ackSender target=${pending.target} '
      '(RTT: ${rttMs}ms)',
    );
  }

  // ---------------------------------------------------------------------------
  // Private: ping infrastructure
  // ---------------------------------------------------------------------------

  _PendingPing _trackPendingPing(
    NodeId target,
    int sequence, {
    bool allowForwarded = false,
  }) {
    final pending = _PendingPing(
      target: target,
      sequence: sequence,
      sentAtMs: timePort.nowMs,
      allowForwarded: allowForwarded,
    );
    _pendingPings[sequence] = pending;
    return pending;
  }

  Future<void> _sendPing(NodeId target, int sequence) async {
    _pingsSent++;
    // Single choke point for all 3 of our own probe-selection Pings
    // (performProbeRound, probeNewPeer, _probeUnreachablePeer) — records
    // that this peer was actually probed, resetting its suppression-cap
    // clock (item 2). Deliberately NOT used by the PingReq intermediary
    // role (_handlePingReq sends its relay Ping directly via _safeSend):
    // relaying on someone else's behalf isn't our own scheduling decision.
    _lastProbeAttemptMs[target] = timePort.nowMs;
    _log('Sending Ping to $target seq=$sequence (pings sent: $_pingsSent)');
    final ping = Ping(sender: localNode, sequence: sequence);
    await _safeSend(target, _codec.encode(ping), 'Ping');
  }

  /// Races Ack arrival against timeout. Returns true if Ack won.
  ///
  /// Does NOT remove the pending ping on timeout — late Acks can still
  /// be matched. Caller must clean up via [_cleanupPendingPing].
  Future<bool> _awaitAckWithTimeout(
    _PendingPing pending,
    int sequence,
    Duration timeout,
  ) async {
    final timeoutFuture = timePort.delay(timeout).then((_) => false);
    return Future.any([pending.completer.future, timeoutFuture]);
  }

  void _cleanupPendingPing(int sequence) {
    _pendingPings.remove(sequence);
  }

  // ---------------------------------------------------------------------------
  // Private: peer selection
  // ---------------------------------------------------------------------------

  List<Peer> _selectRandomIntermediaries(NodeId target, int count) {
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

  Future<void> _sendPingRequests(
    List<Peer> intermediaries,
    NodeId target,
    int sequence,
  ) async {
    final pingReq = PingReq(
      sender: localNode,
      sequence: sequence,
      target: target,
    );
    final bytes = _codec.encode(pingReq);
    for (final intermediary in intermediaries) {
      await _safeSend(intermediary.id, bytes, 'PingReq');
    }
  }

  // ---------------------------------------------------------------------------
  // Private: infrastructure
  // ---------------------------------------------------------------------------

  Future<void> _safeSend(
    NodeId recipient,
    Uint8List bytes,
    String context,
  ) async {
    try {
      await messagePort.send(recipient, bytes, priority: MessagePriority.high);
      peerRegistry.recordMessageSent(recipient, bytes.length);
    } catch (e) {
      _emitError(
        PeerSyncError(
          recipient,
          SyncErrorType.peerUnreachable,
          'Failed to send $context to $recipient: $e',
          occurredAt: DateTime.now(),
          cause: e,
        ),
      );
    }
  }

  /// Updates peer contact and logs recovery if the peer was non-reachable.
  void _recordPeerContact(NodeId peerId, int timestampMs) {
    final peer = peerRegistry.getPeer(peerId);
    final oldStatus = peer?.status;

    peerRegistry.updatePeerContact(peerId, timestampMs);

    if (oldStatus != null && oldStatus != PeerStatus.reachable) {
      _pacer.news();
      _log(
        'Peer $peerId transitioning to REACHABLE '
        '(was: ${oldStatus.name}, '
        'failed probes reset to 0)',
      );
    }
  }

  void _emitError(SyncError error) {
    onError?.call(error);
  }

  void _log(String message) {
    onLog?.call(LogLevel.debug, '[SWIM] $message');
  }
}
