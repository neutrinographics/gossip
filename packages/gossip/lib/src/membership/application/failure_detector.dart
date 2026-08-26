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

/// The classification [FailureDetector._probe] returns for one probe
/// attempt (direct leg plus indirect fallback).
///
/// Split into three "alive" cases rather than one, even though most
/// callers fold [aliveIndirect] and [aliveLateDirect] back together, so
/// [FailureDetector.performProbeRound] can single out the late-direct-Ack
/// case for its own diagnostic logging without [FailureDetector._probe]
/// having to know which caller is asking.
enum _ProbeOutcome {
  /// The target's own Ack answered the direct Ping before its timeout.
  aliveDirect,

  /// The direct Ping timed out, but an intermediary's forwarded Ack
  /// answered during the indirect phase.
  aliveIndirect,

  /// The direct Ping timed out and no forwarded Ack arrived, but the
  /// original direct Ack itself landed late — during the indirect phase,
  /// after the direct leg gave up waiting but before its pending entry
  /// was cleaned up.
  aliveLateDirect,

  /// Neither the direct Ping nor the indirect phase produced an Ack.
  failed,
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
///
/// Comment keys like COR3-n / WIRE4-n / H-n refer to findings in
/// `docs/audits/`.
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

  final RttTracker _rttTracker;

  /// Owns the ping-timeout / probe-interval policy (CC5-13): static vs.
  /// adaptive per knob, the 3x-timeout interval formula, and the
  /// quiescence pacer. See [ProbeTimingPolicy] for why this is a
  /// separate object rather than fields here.
  late final ProbeTimingPolicy _timing;

  /// Owns probe-target selection policy (CC5-2/CC5-14): round-robin peer
  /// selection, indirect-ping intermediary picks, the unreachable-peer
  /// recovery cursor, and the probing-hold grace period. See
  /// [ProbeTargetSelector] for why this is a separate object rather than
  /// fields here.
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
    required this.timePort,
    required this.messagePort,
    this.onError,
    this.onLog,
    Duration? pingTimeout,
    Duration? probeInterval,
    Random? random,
    RttTracker? rttTracker,
  }) : _codec = codec,
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

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------

  /// SWIM's k: number of intermediaries asked to relay a ping when a
  /// direct probe times out, before falling back to (or alongside) waiting
  /// out the grace period for a late direct Ack.
  static const int _indirectProbeFanout = 3;

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  /// Drives the periodic probe round loop: computes each tick's delay
  /// (jittered [effectiveProbeInterval]), runs [performProbeRound], and
  /// reports tick vs. scheduling failures separately. Built eagerly in the
  /// constructor — unlike Coordinator's compaction scheduler, [timePort]
  /// is always available here, so there is no lazy-construction case.
  late final GenerationScheduler _scheduler;

  int _nextSequence = 1;
  int _unreachableProbeCounter = 0;
  StreamSubscription<IncomingMessage>? _messageSubscription;
  final Map<int, _PendingPing> _pendingPings = {};
  int _acksReceived = 0;
  int _pingsSent = 0;

  // ---------------------------------------------------------------------------
  // Public API: probing hold (startup grace period)
  // ---------------------------------------------------------------------------
  //
  // Delegates to _selector — see ProbeTargetSelector for the semantics.
  // Kept public here (rather than routing callers through _selector
  // directly) because Coordinator, the composition root, only ever sees
  // the detector.

  /// Sets a probing hold for a peer until the given timestamp.
  void setProbingHold(NodeId peerId, int holdUntilMs) =>
      _selector.setProbingHold(peerId, holdUntilMs);

  /// Clears any probing hold for a peer, making them eligible for probing.
  void clearProbingHold(NodeId peerId) => _selector.clearProbingHold(peerId);

  /// Returns true if the peer currently has an active probing hold.
  bool hasProbingHold(NodeId peerId) => _selector.hasProbingHold(peerId);

  /// Drops all per-peer bookkeeping for a peer that has been removed from
  /// the system entirely.
  void forgetPeer(NodeId peerId) => _selector.forgetPeer(peerId);

  // ---------------------------------------------------------------------------
  // Public API: adaptive timing
  // ---------------------------------------------------------------------------

  bool get isRunning => _scheduler.isRunning;

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

  // ---------------------------------------------------------------------------
  // Public API: lifecycle
  // ---------------------------------------------------------------------------

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
        // If something else already called news() earlier in this same
        // round (e.g. a different peer's contact recovering it from
        // suspected), this quietRound() still runs right after — netting
        // a multiplier of 1.5x base rather than staying at 1x. Accepted:
        // it self-corrects, since the next quiet round continues growing
        // from wherever this landed, and the next real news() resets it
        // to 1 regardless.
        _timing.quietRound();
      case _ProbeOutcome.aliveIndirect:
      case _ProbeOutcome.aliveLateDirect:
        // A forwarded indirect Ack carries the intermediary as sender, so
        // handleAck only updated the intermediary's contact. Record contact
        // for the target explicitly — otherwise a peer reachable only via
        // intermediaries stays suspected forever (excluded from gossip,
        // never unreachable, never recovered).
        _recordPeerContact(peer.id, timePort.nowMs);
        _timing.quietRound();
      case _ProbeOutcome.failed:
        _handleProbeFailure(peer.id);
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
    _timing.news();
    final peer = peerRegistry.getPeer(peerId);
    if (peer == null) return false;

    final gotAck = await _pingExchange(
      peerId,
      (sequence) => _sendPing(peerId, sequence),
      effectivePingTimeoutForPeer(peerId),
    );

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
  /// Ack, [handleAck] → [_recordPeerContact] → [PeerRegistry.updatePeerContact]
  /// transitions it back to reachable.
  Future<void> _probeUnreachablePeer() async {
    final peer = _selector.nextUnreachableTarget();
    if (peer == null) return;

    _log('Probing unreachable peer ${peer.id} (best-effort recovery)');

    // Indirect ping (inside _probe): ask intermediaries to probe on our
    // behalf. In 2-device scenarios this finds no intermediaries and
    // returns false.
    switch (await _probe(peer.id)) {
      case _ProbeOutcome.aliveDirect:
        _log('Unreachable peer ${peer.id} responded — recovered to reachable');
      case _ProbeOutcome.aliveIndirect:
      case _ProbeOutcome.aliveLateDirect:
        // The forwarded Ack has the intermediary as sender, so handleAck()
        // only updated the intermediary's contact. Explicitly recover the
        // target peer.
        _recordPeerContact(peer.id, timePort.nowMs);
        _log('Unreachable peer ${peer.id} responded (indirect) — recovered');
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

  /// Probes [target]: direct Ping first, falling back to an indirect ping
  /// via intermediaries if the direct Ping times out.
  ///
  /// Classifies the result as one of [_ProbeOutcome]'s four cases and
  /// returns — it does not itself decide what a caller should do about it
  /// (contact recording, pacer signals, failure bookkeeping). Those differ
  /// between [performProbeRound]'s regular probing and
  /// [_probeUnreachablePeer]'s best-effort recovery probing, so each maps
  /// the outcome to its own policy.
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

      final gotIndirectAck = await _performIndirectPing(target);
      if (gotIndirectAck) return _ProbeOutcome.aliveIndirect;

      if (pending.completer.isCompleted) {
        _log(
          'Late Ack arrived for seq=$sequence from $target '
          '(recovered during indirect ping phase)',
        );
        return _ProbeOutcome.aliveLateDirect;
      }
      return _ProbeOutcome.failed;
    } finally {
      // Late-Ack grace invariant: the direct pending entry must stay
      // matchable while intermediaries relay on our behalf, or a late
      // direct Ack that lands mid-indirect-phase finds no pending entry to
      // complete and is silently lost. So cleanup spans both phases —
      // it happens here, once, after the indirect phase concludes, never
      // in a nested finally scoped to the direct leg alone.
      _cleanupPendingPing(sequence);
    }
  }

  /// Performs indirect ping when direct ping fails.
  ///
  /// Sends PingReq to up to 3 intermediaries asking them to probe the
  /// target. When no intermediaries are available (2-device scenario),
  /// waits for a grace period to allow late Acks to arrive.
  Future<bool> _performIndirectPing(NodeId target) async {
    final intermediaries = _selector.selectIntermediaries(
      target,
      _indirectProbeFanout,
    );
    final peerTimeout = effectivePingTimeoutForPeer(target);

    if (intermediaries.isEmpty) {
      await timePort.delay(peerTimeout);
      return false;
    }

    return _pingExchange(
      target,
      (sequence) => _sendPingRequests(intermediaries, target, sequence),
      peerTimeout,
      allowForwarded: true,
    );
  }

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
    final ProtocolMessage? protocolMessage;
    try {
      protocolMessage = _codec.decode(message.bytes);
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
      return;
    }
    // Foreign-family frame (e.g. a sync DigestRequest/DigestResponse or
    // DeltaRequest/DeltaResponse sharing the same transport) — not ours
    // to handle. Routine traffic, not an error: mirrors the
    // pre-injection behavior where the type-dispatch below simply had no
    // matching branch for it.
    if (protocolMessage == null) return;

    try {
      if (protocolMessage is Ping) {
        await _handleIncomingPing(protocolMessage, message.sender);
      } else if (protocolMessage is Ack) {
        _handleIncomingAck(protocolMessage);
      } else if (protocolMessage is PingReq) {
        await _handlePingReq(protocolMessage, message.sender);
      }
    } catch (e, st) {
      // A handler failure is distinct from a decode failure: the message
      // was well-formed, so this is a protocol/application-level fault
      // (e.g. a downstream callback throwing) rather than corrupted bytes.
      _emitError(
        PeerSyncError(
          message.sender,
          SyncErrorType.protocolError,
          'Failed handling ${protocolMessage.runtimeType} from '
          '${message.sender}: $e',
          occurredAt: DateTime.now(),
          cause: e,
        ),
      );
      _log(
        'Failed handling ${protocolMessage.runtimeType} from '
        '${message.sender}: $e',
        level: LogLevel.error,
        error: e,
        stackTrace: st,
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
    final gotAck = await _pingExchange(
      pingReq.target,
      // Deliberately NOT _sendPing: relaying on someone else's behalf
      // isn't our own scheduling decision, so this bypasses the
      // probe-attempt bookkeeping _sendPing does for our own selection
      // choices.
      (sequence) async {
        final ping = Ping(sender: localNode, sequence: sequence);
        await _safeSend(pingReq.target, _codec.encode(ping), 'Ping');
      },
      // Adaptive per-target timeout, not a fixed 500ms: on BLE a target's
      // RTT can exceed 500ms, and a fixed timeout made the intermediary
      // abandon the relay before the target could answer — wasting the
      // whole indirect phase while the requester still waited out its own
      // (longer) timeout.
      effectivePingTimeoutForPeer(pingReq.target),
    );

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
  /// RTT is attributed to pending.target (the peer being probed), not
  /// ackSender — forwarded indirect Acks have the intermediary as sender.
  ///
  /// All valid RTT samples are recorded regardless of whether they exceeded
  /// the timeout. Unlike TCP (where Karn's algorithm avoids ambiguity between
  /// original and retransmitted segments), SWIM pings have unique sequence
  /// numbers so every Ack is unambiguously matched. Recording all samples
  /// lets the EWMA adapt upward when latency increases, preventing a
  /// survivorship bias where only fast samples feed the estimate.
  void _recordRtt(_PendingPing pending, NodeId ackSender, int timestampMs) {
    final rttMs = timestampMs - pending.sentAtMs;

    if (rttMs <= 0) return;

    final rttSample = clampDuration(
      Duration(milliseconds: rttMs),
      min: RttTracker.minSample,
      max: RttTracker.maxSample,
    );

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
    // (performProbeRound and _probeUnreachablePeer via _probe;
    // probeNewPeer directly) — records that this peer was actually
    // probed, resetting its suppression-cap clock.
    _selector.recordProbeAttempt(target, timePort.nowMs);
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
    final timeoutFuture = timePort.delay(timeout).then((_) => false);
    return Future.any([pending.completer.future, timeoutFuture]);
  }

  void _cleanupPendingPing(int sequence) {
    _pendingPings.remove(sequence);
  }

  /// Runs one ping/Ack exchange: allocates a sequence number, tracks it as
  /// pending, invokes [send] to transmit, races the Ack against [timeout],
  /// and always drops the pending entry afterward.
  ///
  /// [send] is a callback rather than a fixed action because its three
  /// callers each send something different: [probeNewPeer] sends a
  /// stamped probe Ping (via [_sendPing]), [_performIndirectPing] sends a
  /// PingReq fan-out (via [_sendPingRequests]), and [_handlePingReq] sends
  /// a bare relay Ping directly (see its closure for why not [_sendPing]).
  ///
  /// Not used by [_probe]'s direct leg: that cleanup must span the
  /// indirect phase that follows it, not fire immediately — see [_probe]'s
  /// finally block.
  Future<bool> _pingExchange(
    NodeId target,
    Future<void> Function(int sequence) send,
    Duration timeout, {
    bool allowForwarded = false,
  }) async {
    final sequence = _nextSequence++;
    final pending = _trackPendingPing(
      target,
      sequence,
      allowForwarded: allowForwarded,
    );
    try {
      await send(sequence);
      return await _awaitAckWithTimeout(pending, timeout);
    } finally {
      _cleanupPendingPing(sequence);
    }
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
