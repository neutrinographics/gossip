import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'package:gossip/src/shared/domain/value_objects/log_level.dart';
import 'package:gossip/src/shared/domain/errors/sync_error.dart';
import 'package:gossip/src/shared/domain/services/duration_clamp.dart';
import 'package:gossip/src/shared/domain/services/generation_scheduler.dart';
import 'package:gossip/src/shared/domain/services/jitter.dart';
import 'package:gossip/src/shared/domain/services/rtt_tracker.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/rtt_estimate.dart';
import 'package:gossip/src/membership/application/membership_timing_snapshot.dart';
import 'package:gossip/src/membership/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/membership/domain/entities/peer.dart';
import 'package:gossip/src/membership/domain/services/probe_target_selector.dart';
import 'package:gossip/src/membership/domain/services/probe_timing_policy.dart';
import 'package:gossip/src/membership/domain/value_objects/peer_status.dart';
import 'package:gossip/src/shared/domain/interfaces/time_port.dart';
import 'package:gossip/src/shared/domain/interfaces/message_port.dart';
import 'package:gossip/src/membership/infrastructure/membership_message_codec.dart';
import 'package:gossip/src/shared/domain/interfaces/message_codec.dart';
import 'package:gossip/src/shared/domain/interfaces/protocol_message.dart';
import 'package:gossip/src/membership/domain/messages/ping.dart';
import 'package:gossip/src/membership/domain/messages/ack.dart';
import 'package:gossip/src/membership/domain/messages/ping_req.dart';

/// Tracks a pending ping awaiting its Ack.
///
/// Matched to an incoming Ack by sequence number, and only when that Ack's
/// sender is [target]: a stale Ack with a colliding sequence from an
/// unrelated peer must not mark a possibly-dead target alive. The
/// [completer] resolves to true when the Ack arrives.
class _PendingPing {
  final NodeId target;
  final int sequence;
  final int sentAtMs;
  final Completer<bool> completer;

  _PendingPing({
    required this.target,
    required this.sequence,
    required this.sentAtMs,
  }) : completer = Completer<bool>();
}

/// The classification [FailureDetector._probe] returns for one probe.
///
/// [aliveLate] is kept distinct from [aliveDirect] only so the detector
/// can log the late-Ack case at the point it sees it — a late Ack is the
/// signal that a timeout is running tight. Every caller handles the two
/// alive cases identically.
enum _ProbeOutcome {
  /// The target's Ack answered before the direct timeout.
  aliveDirect,

  /// The target's Ack landed after the direct timeout but inside the grace
  /// window (ADR-012).
  aliveLate,

  /// No Ack arrived before the grace window closed.
  failed,
}

/// Protocol service implementing probe-based failure detection.
///
/// Detects peer failures through periodic direct probing with a graded
/// reachable → suspected → unreachable status.
///
/// ## Protocol Flow
///
/// **Probe Round (adaptive interval)**:
/// 1. Select the next probe target (round-robin over probable peers — see ProbeTargetSelector)
/// 2. Send direct Ping
/// 3. Wait for Ack (per-peer RTT-adaptive timeout)
/// 4. If no Ack, hold the pending ping open for one more timeout — the
///    grace window (ADR-012) — and return the moment a late Ack lands
/// 5. If still no Ack, increment failed probe count
///
/// There is no relayed (indirect) probe: a membership verdict never leaves
/// the node that formed it (ADR-007), so asking a third peer to vouch for
/// a silent one protects nothing — see ADR-004's history.
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
  final NodeId localNode;
  final PeerRegistry peerRegistry;
  final int failureThreshold;
  final int unreachableThreshold;
  final int unreachableProbeInterval;
  final TimePort _timePort;
  final MessagePort messagePort;
  final ErrorCallback? onError;
  final LogCallback? onLog;

  final RttTracker _rttTracker;

  /// Owns the ping-timeout / probe-interval policy: static vs. adaptive
  /// per knob, the 3x-timeout interval formula, and the quiescence
  /// pacer. See [ProbeTimingPolicy] for why this is a separate object
  /// rather than fields here.
  late final ProbeTimingPolicy _timing;

  /// Owns probe-target selection policy: round-robin peer selection,
  /// the unreachable-peer recovery cursor, and the probing-hold grace
  /// period. See [ProbeTargetSelector] for why this is a separate object
  /// rather than fields here.
  late final ProbeTargetSelector _selector;
  final Random _random;

  /// Codec for serializing/deserializing this context's (membership's)
  /// protocol messages.
  ///
  /// Injected by the composition root (`Coordinator` wires a
  /// [MembershipMessageCodec]; test harnesses do the same) rather than
  /// constructed inline, so the detector depends only on the shared
  /// [MessageCodec] seam, not a concrete codec class.
  /// [MessageCodec.decode] answers null for a frame outside this codec's
  /// family (e.g. a
  /// sync DigestRequest/Response or DeltaRequest/Response sharing the same
  /// transport) — see the null-check in [_handleIncomingMessage].
  final MessageCodec _codec;

  FailureDetector({
    required MessageCodec codec,
    required this.localNode,
    required this.peerRegistry,
    this.failureThreshold = 3,
    this.unreachableThreshold = 9,
    this.unreachableProbeInterval = 5,
    required TimePort timePort,
    required this.messagePort,
    this.onError,
    this.onLog,
    Duration? pingTimeout,
    Duration? probeInterval,
    Random? random,
    RttTracker? rttTracker,
  }) : _timePort = timePort,
       _codec = codec,
       _random = random ?? Random(),
       _rttTracker = rttTracker ?? RttTracker() {
    _timing = ProbeTimingPolicy(
      peerRegistry: peerRegistry,
      rttTracker: _rttTracker,
      staticPingTimeout: pingTimeout,
      staticProbeInterval: probeInterval,
    );
    // Shares this same Random instance (not a fresh one) — seeded-test
    // determinism depends on every draw coming from one generator.
    _selector = ProbeTargetSelector(
      peerRegistry: peerRegistry,
      timePort: timePort,
      random: _random,
    );
    _scheduler = GenerationScheduler(
      timePort: timePort,
      // ±20% jitter decorrelates probe loops across nodes so they don't
      // phase-lock into correlated bursts (and correlated false
      // suspicions); recomputed fresh so the pacer's growth/reset each
      // round is reflected in the next tick's delay.
      nextDelay: () => applyJitter(effectiveProbeInterval, _random),
      tick: performProbeRound,
      onTickError: (error, stackTrace) => _emitError(
        PeerSyncError(
          localNode,
          SyncErrorType.protocolError,
          'Probe round failed: $error',
          occurredAt: DateTime.now(),
          cause: error,
        ),
      ),
      onSchedulingError: (error, stackTrace) => _emitError(
        PeerSyncError(
          localNode,
          SyncErrorType.protocolError,
          'Probe round scheduling failed: $error',
          occurredAt: DateTime.now(),
          cause: error,
        ),
      ),
    );
  }

  /// Drives the periodic probe round loop: computes each tick's delay
  /// (jittered [effectiveProbeInterval]), runs [performProbeRound], and
  /// reports tick vs. scheduling failures separately. Built eagerly in the
  /// constructor — unlike Coordinator's compaction scheduler, the time port
  /// is always available here, so there is no lazy-construction case.
  late final GenerationScheduler _scheduler;

  int _nextSequence = 1;
  int _unreachableProbeCounter = 0;
  StreamSubscription<IncomingMessage>? _messageSubscription;
  final Map<int, _PendingPing> _pendingPings = {};
  int _acksReceived = 0;
  int _pingsSent = 0;

  // The next five members delegate to _selector — see ProbeTargetSelector
  // for the semantics. Kept public here (rather than routing callers
  // through _selector directly) because Coordinator, the composition
  // root, only ever sees the detector.

  /// Holds [peerId] out of probe selection for [duration], measured from
  /// now on this detector's own time port.
  ///
  /// The deadline is computed here rather than by the caller because the
  /// hold is later judged against this same clock (see
  /// [ProbeTargetSelector.nextProbeTarget]) — a caller-computed absolute
  /// deadline would couple the caller's notion of "now" to this detector's,
  /// which only coincidentally agree in production and diverge under any
  /// clock double that isn't shared.
  void holdProbing(NodeId peerId, Duration duration) =>
      setProbingHold(peerId, _timePort.nowMs + duration.inMilliseconds);

  /// Sets a probing hold for a peer until the given timestamp.
  ///
  /// Production code holds peers via [holdProbing], which computes the
  /// deadline from this detector's own clock. This absolute-deadline form
  /// stays public only so tests can set an already-known deadline directly
  /// (e.g. "already expired", or a value computed from a peer clock).
  @visibleForTesting
  void setProbingHold(NodeId peerId, int holdUntilMs) =>
      _selector.setProbingHold(peerId, holdUntilMs);

  /// Clears any probing hold for a peer, making them eligible for probing.
  void clearProbingHold(NodeId peerId) => _selector.clearProbingHold(peerId);

  /// Returns true if the peer currently has an active probing hold.
  ///
  /// Coordinator never reads this back — it only sets/clears holds — so
  /// production code has no caller; kept public solely for tests to assert
  /// hold state directly.
  @visibleForTesting
  bool hasProbingHold(NodeId peerId) => _selector.hasProbingHold(peerId);

  /// Drops all per-peer bookkeeping for a peer that has been removed from
  /// the system entirely.
  void forgetPeer(NodeId peerId) => _selector.forgetPeer(peerId);

  bool get isRunning => _scheduler.isRunning;

  /// Exposes the RTT tracker for assertions only — production code reads
  /// timing through [effectivePingTimeout] et al., never this directly.
  @visibleForTesting
  RttTracker get rttTracker => _rttTracker;

  /// Effective ping timeout. Delegates to [_timing] — see
  /// [ProbeTimingPolicy.effectivePingTimeout].
  Duration get effectivePingTimeout => _timing.effectivePingTimeout;

  /// Per-peer ping timeout. Delegates to [_timing] — see
  /// [ProbeTimingPolicy.effectivePingTimeoutForPeer].
  Duration effectivePingTimeoutForPeer(NodeId peerId) =>
      _timing.effectivePingTimeoutForPeer(peerId);

  /// Effective probe interval (time between probe rounds). Delegates to
  /// [_timing] — see [ProbeTimingPolicy.effectiveProbeInterval].
  Duration get effectiveProbeInterval => _timing.effectiveProbeInterval;

  /// Snapshots this detector's RTT and timing state for observability
  /// callers outside membership (see [MembershipTimingSnapshot]).
  ///
  /// Selects the minimum per-peer smoothed RTT, paired with that SAME
  /// peer's variance (never an independently-chosen minimum variance across
  /// peers — that would report a timeout basis no single peer actually
  /// has). Falls back to the global [_rttTracker] estimate, as one unit,
  /// only when no peer has an RTT estimate yet.
  MembershipTimingSnapshot timingSnapshot() {
    final perPeerRtt = <NodeId, RttEstimate>{};
    Duration? minSrtt;
    Duration? minSrttVariance;
    int totalSamples = 0;

    for (final peer in peerRegistry.allPeers) {
      final rttEstimate = peer.metrics.rttEstimate;
      if (rttEstimate != null) {
        perPeerRtt[peer.id] = rttEstimate;
        totalSamples++;
        if (minSrtt == null || rttEstimate.smoothedRtt < minSrtt) {
          minSrtt = rttEstimate.smoothedRtt;
          minSrttVariance = rttEstimate.rttVariance;
        }
      }
    }

    // Fall back to the global tracker when no per-peer data exists.
    final smoothedRtt = minSrtt ?? _rttTracker.smoothedRtt;
    final rttVariance = minSrttVariance ?? _rttTracker.rttVariance;
    final sampleCount = totalSamples > 0
        ? totalSamples
        : _rttTracker.sampleCount;
    final hasSamples = totalSamples > 0 ? true : _rttTracker.hasReceivedSamples;

    return MembershipTimingSnapshot(
      perPeerRtt: perPeerRtt,
      smoothedRtt: smoothedRtt,
      rttVariance: rttVariance,
      sampleCount: sampleCount,
      hasSamples: hasSamples,
      pingTimeout: effectivePingTimeout,
      probeInterval: effectiveProbeInterval,
    );
  }

  /// Starts periodic probe rounds at adaptive intervals.
  void start() {
    if (_scheduler.isRunning) return;
    // A restart is news — never resume mid-backoff into a stale world.
    _timing.news();
    _scheduler.start();
  }

  /// Stops periodic probe rounds.
  void stop() {
    _scheduler.stop();
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

  /// Performs a single probe round.
  ///
  /// 1. Select the next probe target (round-robin over probable peers — see ProbeTargetSelector)
  /// 2. Send direct Ping
  /// 3. Wait for Ack (per-peer timeout)
  /// 4. If no Ack, wait out the grace window for a late Ack
  /// 5. Record a failure only if the window closes empty
  ///
  /// Driven internally by [_scheduler]'s tick — production code never calls
  /// this directly. Kept public only so tests can force a round
  /// synchronously instead of waiting on the timer.
  @visibleForTesting
  Future<void> performProbeRound() async {
    await _maybeProbeUnreachablePeerThisRound();

    // Regular probe round: select reachable or suspected peer.
    final peer = _selector.nextProbeTarget(
      freshnessWindow: effectiveProbeInterval,
    );
    if (peer == null) {
      // Nothing needs probing (empty registry or everyone fresh) —
      // that is quiescence, not a stall.
      if (peerRegistry.probablePeers.isNotEmpty) _timing.quietRound();
      return;
    }

    switch (await _probe(peer.id)) {
      case _ProbeOutcome.aliveDirect:
      case _ProbeOutcome.aliveLate:
        // If something else already called news() earlier in this same
        // round (e.g. a different peer's contact recovering it from
        // suspected), this quietRound() still runs right after — netting
        // a multiplier of 1.5x base rather than staying at 1x. Accepted:
        // it self-corrects, since the next quiet round continues growing
        // from wherever this landed, and the next real news() resets it
        // to 1 regardless. A late Ack is a healthy answer too: its
        // contact was recorded by the Ack handler, so nothing more to do.
        _timing.quietRound();
      case _ProbeOutcome.failed:
        _handleProbeFailure(peer.id);
    }
  }

  /// Probes one unreachable peer for recovery, every [unreachableProbeInterval]
  /// probe rounds.
  Future<void> _maybeProbeUnreachablePeerThisRound() async {
    if (unreachableProbeInterval > 0) {
      _unreachableProbeCounter++;
      if (_unreachableProbeCounter >= unreachableProbeInterval) {
        _unreachableProbeCounter = 0;
        await _probeUnreachablePeer();
      }
    }
  }

  /// Probes a specific newly-connected peer to bootstrap its RTT estimate.
  ///
  /// Returns true if an Ack was received, false on timeout. No failure is
  /// recorded on timeout — this is best-effort RTT bootstrapping, not
  /// failure detection. No grace window either: with no verdict to
  /// protect, a late first sample is simply the next probe's.
  ///
  /// Called fire-and-forget from Coordinator.addPeer() to get the first
  /// RTT sample quickly instead of waiting for random probe selection.
  Future<bool> probeNewPeer(NodeId peerId) async {
    _timing.news();
    final peer = peerRegistry.getPeer(peerId);
    if (peer == null) return false;

    final sequence = _nextSequence++;
    final pending = _trackPendingPing(peerId, sequence);
    final bool gotAck;
    try {
      await _sendPing(peerId, sequence);
      gotAck = await _awaitAckWithTimeout(
        pending,
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
  /// timeout since the peer is already unreachable. Unlike it, the probe
  /// carries a verdict (recovered or not), so it gets the grace window.
  ///
  /// Recovery happens via the existing path: if the peer responds with an
  /// Ack, [handleAck] → [_recordPeerContact] → [PeerRegistry.updatePeerContact]
  /// transitions it back to reachable.
  Future<void> _probeUnreachablePeer() async {
    final peer = _selector.nextUnreachableTarget();
    if (peer == null) return;

    _log('Probing unreachable peer ${peer.id} (best-effort recovery)');

    switch (await _probe(peer.id)) {
      case _ProbeOutcome.aliveDirect:
      case _ProbeOutcome.aliveLate:
        _log('Unreachable peer ${peer.id} responded — recovered to reachable');
      case _ProbeOutcome.failed:
        _log('Unreachable peer ${peer.id} did not respond (still unreachable)');
    }
  }

  /// Exposes [ProbeTargetSelector.nextProbeTarget] (with this detector's
  /// current [effectiveProbeInterval] as its freshness window) for tests —
  /// production code reaches it only through [performProbeRound].
  @visibleForTesting
  Peer? nextProbeTarget() =>
      _selector.nextProbeTarget(freshnessWindow: effectiveProbeInterval);

  // Production traffic reaches the next four members only through
  // _handleIncomingMessage; each is public solely so tests can drive it
  // directly.

  /// Handles incoming Ping by returning Ack with matching sequence.
  @visibleForTesting
  Ack handlePing(Ping ping) {
    return Ack(sender: localNode, sequence: ping.sequence);
  }

  /// Handles incoming Ack: updates peer contact and records RTT.
  ///
  /// Acks that don't match a pending ping are silently ignored. This is
  /// normal when a very-late Ack arrives after the grace window closed.
  /// The sender's contact timestamp is updated regardless: an Ack is proof
  /// of life for whoever sent it, even when it confirms no probe.
  @visibleForTesting
  void handleAck(Ack ack, {required int timestampMs}) {
    _recordPeerContact(ack.sender, timestampMs);

    final pending = _pendingPings[ack.sequence];
    if (pending == null || pending.completer.isCompleted) {
      return;
    }

    // Only the probed target may confirm its own ping: a stale Ack with a
    // colliding sequence from an unrelated peer (e.g. after a detector
    // rebuild reset the sequence counter) must not mark a possibly-dead
    // target alive.
    if (ack.sender != pending.target) {
      _log(
        'Ignoring Ack seq=${ack.sequence} from ${ack.sender}: '
        'pending ping targets ${pending.target}',
      );
      return;
    }

    _recordRtt(pending, timestampMs);
    pending.completer.complete(true);
  }

  /// Records a failed probe attempt for a peer.
  @visibleForTesting
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
  @visibleForTesting
  void updatePeerHealth(NodeId peerId, {required DateTime occurredAt}) {
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

  /// Probes [target]: a direct Ping, then — if its timeout expires — the
  /// grace window, one more per-peer timeout on the same pending ping.
  ///
  /// Classifies the result as one of [_ProbeOutcome]'s cases and returns —
  /// it does not itself decide what a caller should do about it (pacer
  /// signals, failure bookkeeping). Those differ between
  /// [performProbeRound]'s regular probing and [_probeUnreachablePeer]'s
  /// best-effort recovery probing, so each maps the outcome to its own
  /// policy.
  Future<_ProbeOutcome> _probe(NodeId target) async {
    final sequence = _nextSequence++;
    final pending = _trackPendingPing(target, sequence);
    try {
      await _sendPing(target, sequence);

      final gotDirectAck = await _awaitAckWithTimeout(
        pending,
        effectivePingTimeoutForPeer(target),
      );
      if (gotDirectAck) return _ProbeOutcome.aliveDirect;

      if (await _awaitLateAck(pending, target)) {
        _log(
          'Late Ack arrived for seq=$sequence from $target '
          'within the grace window',
        );
        return _ProbeOutcome.aliveLate;
      }
      return _ProbeOutcome.failed;
    } finally {
      // Late-Ack grace invariant: the pending entry must stay matchable
      // through the grace window, or a late Ack finds nothing to complete
      // and is silently lost. So cleanup spans both waits.
      _cleanupPendingPing(sequence);
    }
  }

  /// The grace window after a direct timeout (ADR-012): the pending ping
  /// stays open for one more per-peer timeout so a slightly-late Ack still
  /// counts. Returns true the moment such an Ack lands, false when the
  /// window closes empty. Re-reads the timeout at entry so a fresh RTT
  /// sample is honored.
  Future<bool> _awaitLateAck(_PendingPing pending, NodeId target) =>
      _awaitAckWithTimeout(pending, effectivePingTimeoutForPeer(target));

  void _handleProbeFailure(NodeId target) {
    _timing.news();
    final peer = peerRegistry.getPeer(target);
    final failedCount = peer?.failedProbeCount ?? 0;
    _log(
      'Probe FAILED for $target '
      '(failed count: $failedCount -> ${failedCount + 1}, '
      'threshold: $failureThreshold, '
      'pings sent: $_pingsSent, acks received: $_acksReceived)',
    );
    recordProbeFailure(target);
    updatePeerHealth(target, occurredAt: DateTime.now());
  }

  Future<void> _handleIncomingMessage(IncomingMessage message) async {
    // Deliberately NOT recording receive metrics here: GossipEngine
    // subscribes to the same incoming stream and is the single
    // designated recording point — both engines recording would double
    // every rate/byte metric applications throttle on.
    final protocolMessage = _decodeIncomingMessage(message);
    // Foreign-family frame (e.g. a sync DigestRequest/DigestResponse or
    // DeltaRequest/DeltaResponse sharing the same transport) — not ours
    // to handle. Routine traffic, not an error, or an already-reported
    // decode failure.
    if (protocolMessage == null) return;

    await _dispatchProtocolMessage(protocolMessage, message.sender);
  }

  /// Decodes [message] into a [ProtocolMessage], or null if it is either
  /// a foreign-family frame (see [_handleIncomingMessage]) or malformed —
  /// a decode failure is reported here (emitted and logged) rather than
  /// left for the caller.
  ProtocolMessage? _decodeIncomingMessage(IncomingMessage message) {
    try {
      return _codec.decode(message.bytes);
    } catch (e, st) {
      _emitError(
        PeerSyncError(
          message.sender,
          SyncErrorType.messageCorrupted,
          'Malformed SWIM message from ${message.sender}: $e',
          occurredAt: DateTime.now(),
          cause: e,
        ),
      );
      _log(
        'Malformed SWIM message from ${message.sender}: $e',
        level: LogLevel.error,
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }

  /// Routes [protocolMessage] to its type-specific handler.
  ///
  /// A handler failure here is distinct from a decode failure: the
  /// message was well-formed, so this is a protocol/application-level
  /// fault (e.g. a downstream callback throwing) rather than corrupted
  /// bytes.
  Future<void> _dispatchProtocolMessage(
    ProtocolMessage protocolMessage,
    NodeId sender,
  ) async {
    try {
      if (protocolMessage is Ping) {
        await _handleIncomingPing(protocolMessage, sender);
      } else if (protocolMessage is Ack) {
        _handleIncomingAck(protocolMessage);
      } else if (protocolMessage is PingReq) {
        _ignoreRelayRequest(protocolMessage, sender);
      }
    } catch (e, st) {
      _emitError(
        PeerSyncError(
          sender,
          SyncErrorType.protocolError,
          'Failed handling ${protocolMessage.runtimeType} from $sender: $e',
          occurredAt: DateTime.now(),
          cause: e,
        ),
      );
      _log(
        'Failed handling ${protocolMessage.runtimeType} from $sender: $e',
        level: LogLevel.error,
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<void> _handleIncomingPing(Ping ping, NodeId sender) async {
    _log('Received Ping from $sender seq=${ping.sequence}');
    _recordPeerContact(sender, _timePort.nowMs);
    final ack = handlePing(ping);
    final ackBytes = _codec.encode(ack);
    await _safeSend(sender, ackBytes, 'Ack');
    _log('Sent Ack to $sender seq=${ack.sequence}');
  }

  void _handleIncomingAck(Ack ack) {
    _acksReceived++;
    _log('Received Ack from ${ack.sender} seq=${ack.sequence}');
    handleAck(ack, timestampMs: _timePort.nowMs);
  }

  /// A relay request from a peer still running the retired relayed-probing
  /// protocol. Nothing happens beyond a log line: a membership verdict
  /// never leaves the node that formed it (ADR-007), so probing a third
  /// peer on someone else's behalf protected nothing. The frame is not
  /// proof the sender can hear us either, so it records no contact.
  void _ignoreRelayRequest(PingReq pingReq, NodeId requester) {
    _log('Ignoring PingReq from $requester target=${pingReq.target}');
  }

  /// Records an RTT sample from a matched Ack, attributed to the probed
  /// target — which the sender guard in [handleAck] makes the same node as
  /// the Ack's sender.
  ///
  /// All valid RTT samples are recorded regardless of whether they exceeded
  /// the timeout. Unlike TCP (where Karn's algorithm avoids ambiguity between
  /// original and retransmitted segments), probe pings have unique sequence
  /// numbers so every Ack is unambiguously matched. Recording all samples
  /// lets the EWMA adapt upward when latency increases, preventing a
  /// survivorship bias where only fast samples feed the estimate.
  void _recordRtt(_PendingPing pending, int timestampMs) {
    final rttMs = timestampMs - pending.sentAtMs;

    if (rttMs <= 0) return;

    final rttSample = clampDuration(
      Duration(milliseconds: rttMs),
      min: RttTracker.minSample,
      max: RttTracker.maxSample,
    );

    _rttTracker.recordSample(rttSample);
    peerRegistry.recordPeerRtt(pending.target, rttSample);
    _log(
      'Ack seq=${pending.sequence} from ${pending.target} (RTT: ${rttMs}ms)',
    );
  }

  _PendingPing _trackPendingPing(NodeId target, int sequence) {
    final pending = _PendingPing(
      target: target,
      sequence: sequence,
      sentAtMs: _timePort.nowMs,
    );
    _pendingPings[sequence] = pending;
    return pending;
  }

  Future<void> _sendPing(NodeId target, int sequence) async {
    _pingsSent++;
    // Single choke point for all 3 of our own probe-selection Pings
    // (performProbeRound and _probeUnreachablePeer via _probe;
    // probeNewPeer directly) — records that this peer was actually
    // probed, resetting its suppression-cap clock.
    _selector.recordProbeAttempt(target, _timePort.nowMs);
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
    Duration timeout,
  ) async {
    if (pending.completer.isCompleted) return true;
    final timeoutFuture = _timePort.delay(timeout).then((_) => false);
    return Future.any([pending.completer.future, timeoutFuture]);
  }

  void _cleanupPendingPing(int sequence) {
    _pendingPings.remove(sequence);
  }

  Future<void> _safeSend(
    NodeId recipient,
    Uint8List bytes,
    String context,
  ) async {
    try {
      await messagePort.send(recipient, bytes, priority: MessagePriority.high);
      peerRegistry.recordMessageSent(recipient, bytes.length);
    } catch (e, st) {
      _emitError(
        PeerSyncError(
          recipient,
          SyncErrorType.peerUnreachable,
          'Failed to send $context to $recipient: $e',
          occurredAt: DateTime.now(),
          cause: e,
        ),
      );
      _log(
        'Failed to send $context to $recipient: $e',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Updates peer contact and logs recovery if the peer was non-reachable.
  void _recordPeerContact(NodeId peerId, int timestampMs) {
    final peer = peerRegistry.getPeer(peerId);
    final oldStatus = peer?.status;

    peerRegistry.updatePeerContact(peerId, timestampMs);

    if (oldStatus != null && oldStatus != PeerStatus.reachable) {
      _timing.news();
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

  void _log(
    String message, {
    LogLevel level = LogLevel.debug,
    Object? error,
    StackTrace? stackTrace,
  }) {
    onLog?.call(level, '[SWIM] $message', error, stackTrace);
  }
}
