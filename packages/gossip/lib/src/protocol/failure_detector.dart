import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:gossip/src/application/observability/log_level.dart';
import 'package:gossip/src/domain/errors/sync_error.dart';
import 'package:gossip/src/domain/services/rtt_tracker.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/domain/entities/peer.dart';
import 'package:gossip/src/domain/events/domain_event.dart';
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
  final Completer<bool> completer;

  _PendingPing({
    required this.target,
    required this.sequence,
    required this.sentAtMs,
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
/// - Suspected peers can recover by responding to future probes
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
  final TimePort timePort;
  final MessagePort messagePort;
  final ErrorCallback? onError;
  final LogCallback? onLog;

  final Duration _pingTimeout;
  final Duration _probeInterval;
  final RttTracker _rttTracker;
  final bool _staticTimeoutsProvided;
  final Random _random;
  final ProtocolCodec _codec = ProtocolCodec();

  FailureDetector({
    required this.localNode,
    required this.peerRegistry,
    this.failureThreshold = 3,
    this.unreachableThreshold = 9,
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
       _staticTimeoutsProvided = pingTimeout != null || probeInterval != null;

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------

  static const int _metricsWindowDurationMs = 10000;
  static const Duration _minPingTimeout = Duration(milliseconds: 200);
  static const Duration _maxPingTimeout = Duration(seconds: 10);
  static const Duration _minProbeInterval = Duration(milliseconds: 500);
  static const Duration _maxProbeInterval = Duration(seconds: 30);
  static const int _probeIntervalMultiplier = 3;
  static const Duration _intermediaryTimeout = Duration(milliseconds: 200);

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  bool _isRunning = false;
  int _nextSequence = 1;
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

  // ---------------------------------------------------------------------------
  // Public API: adaptive timing
  // ---------------------------------------------------------------------------

  bool get isRunning => _isRunning;

  RttTracker get rttTracker => _rttTracker;

  /// Effective ping timeout from global RTT estimate.
  ///
  /// Falls back to static timeout if one was provided at construction.
  Duration get effectivePingTimeout {
    if (_staticTimeoutsProvided) return _pingTimeout;
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
    if (_staticTimeoutsProvided) return _pingTimeout;
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
  /// direct and indirect probes within each interval.
  Duration get effectiveProbeInterval {
    if (_staticTimeoutsProvided) return _probeInterval;
    final baseInterval = effectivePingTimeout * _probeIntervalMultiplier;
    if (baseInterval < _minProbeInterval) return _minProbeInterval;
    if (baseInterval > _maxProbeInterval) return _maxProbeInterval;
    return baseInterval;
  }

  // ---------------------------------------------------------------------------
  // Public API: lifecycle
  // ---------------------------------------------------------------------------

  /// Starts periodic probe rounds at adaptive intervals.
  void start() {
    if (_isRunning) return;
    _isRunning = true;
    _scheduleNextProbeRound();
  }

  /// Stops periodic probe rounds.
  void stop() {
    if (!_isRunning) return;
    _isRunning = false;
  }

  /// Starts listening to incoming SWIM protocol messages.
  void startListening() {
    _messageSubscription = messagePort.incoming.listen(_handleIncomingMessage);
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
    final peer = selectRandomPeer();
    if (peer == null) return;

    final sequence = _nextSequence++;
    final pending = _trackPendingPing(peer.id, sequence);
    await _sendPing(peer.id, sequence);

    final gotDirectAck = await _awaitAckWithTimeout(
      pending,
      sequence,
      effectivePingTimeoutForPeer(peer.id),
    );

    if (!gotDirectAck) {
      final gotIndirectAck = await _performIndirectPing(peer.id);
      _evaluateProbeOutcome(peer.id, sequence, pending, gotIndirectAck);
    }

    _cleanupPendingPing(sequence);
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
    final peer = peerRegistry.getPeer(peerId);
    if (peer == null) return false;

    final sequence = _nextSequence++;
    final pending = _trackPendingPing(peerId, sequence);
    await _sendPing(peerId, sequence);

    final gotAck = await _awaitAckWithTimeout(
      pending,
      sequence,
      effectivePingTimeoutForPeer(peerId),
    );

    _cleanupPendingPing(sequence);

    if (gotAck) {
      _log('probeNewPeer got Ack from $peerId');
    } else {
      _log('probeNewPeer timed out for $peerId (no failure recorded)');
    }

    return gotAck;
  }

  /// Selects a random peer to probe (reachable or suspected).
  ///
  /// Includes suspected peers so they can recover by responding to probes
  /// (SWIM's incarnation refutation mechanism).
  ///
  /// Peers with an active probing hold are excluded to prevent false
  /// positives during connection startup.
  Peer? selectRandomPeer() {
    final nowMs = timePort.nowMs;
    final probable = peerRegistry.probablePeers.where((p) {
      final holdUntil = _probingHeldUntil[p.id];
      if (holdUntil == null) return true;
      return nowMs >= holdUntil;
    }).toList();
    if (probable.isEmpty) return null;
    return probable[_random.nextInt(probable.length)];
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
  /// RTT samples that exceed the peer's timeout window are discarded to
  /// prevent late Acks from inflating the SRTT estimate.
  ///
  /// Acks that don't match a pending ping are silently ignored. This is
  /// normal when: (a) a very-late ack arrives after cleanup, (b) both
  /// direct and indirect acks arrive for the same probe, or (c) a
  /// forwarded ack races with a direct ack. The peer contact timestamp
  /// is still updated regardless.
  void handleAck(Ack ack, {required int timestampMs}) {
    peerRegistry.updatePeerContact(ack.sender, timestampMs);

    final pending = _pendingPings[ack.sequence];
    if (pending == null || pending.completer.isCompleted) {
      return;
    }

    _tryRecordRtt(pending, ack.sender, timestampMs);
    pending.completer.complete(true);
  }

  /// Records a failed probe attempt for a peer.
  void recordProbeFailure(NodeId peerId) {
    peerRegistry.incrementFailedProbeCount(peerId);
  }

  /// Transitions peer to suspected if failure threshold is exceeded.
  // TODO: Implement SWIM refutation. When this node receives a Suspicion
  // message about itself, it should call PeerService.incrementLocalIncarnation()
  // to refute the false suspicion. This requires:
  // 1. A Suspicion protocol message type
  // 2. Handling incoming Suspicion in _handleIncomingMessage
  // 3. Accepting PeerService (or a callback) instead of PeerRegistry directly,
  //    so the incarnation increment is persisted via LocalNodeRepository
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

  void _scheduleNextProbeRound() {
    if (!_isRunning) return;
    timePort.delay(effectiveProbeInterval).then((_) {
      if (_isRunning) _probeRound();
    });
  }

  void _probeRound() {
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
        .whenComplete(_scheduleNextProbeRound);
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
    final pending = _trackPendingPing(target, indirectSeq);
    await _sendPingRequests(intermediaries, target, indirectSeq);

    final gotAck = await _awaitAckWithTimeout(
      pending,
      indirectSeq,
      peerTimeout,
    );

    _cleanupPendingPing(indirectSeq);
    return gotAck;
  }

  void _handleProbeFailure(NodeId target) {
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
    _recordIncomingMetrics(message);

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

  void _recordIncomingMetrics(IncomingMessage message) {
    peerRegistry.recordMessageReceived(
      message.sender,
      message.bytes.length,
      timePort.nowMs,
      _metricsWindowDurationMs,
    );
  }

  Future<void> _handleIncomingPing(Ping ping, NodeId sender) async {
    _log('Received Ping from $sender seq=${ping.sequence}');
    // Receiving a Ping is proof of life — update contact to recover
    // unreachable/suspected peers that contact us.
    peerRegistry.updatePeerContact(sender, timePort.nowMs);
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
    final pending = _PendingPing(
      target: pingReq.target,
      sequence: localSeq,
      sentAtMs: timePort.nowMs,
    );
    _pendingPings[localSeq] = pending;

    final ping = Ping(sender: localNode, sequence: localSeq);
    await _safeSend(pingReq.target, _codec.encode(ping), 'Ping');

    final gotAck = await _awaitAckWithTimeout(
      pending,
      localSeq,
      _intermediaryTimeout,
    );

    _cleanupPendingPing(localSeq);

    if (gotAck) {
      final ack = Ack(sender: localNode, sequence: pingReq.sequence);
      await _safeSend(requester, _codec.encode(ack), 'forwarded Ack');
    }
  }

  // ---------------------------------------------------------------------------
  // Private: RTT recording
  // ---------------------------------------------------------------------------

  /// Records an RTT sample if the Ack arrived within the timeout window.
  ///
  /// RTT is attributed to [pending.target] (the peer being probed), not
  /// [ackSender] — forwarded indirect Acks have the intermediary as sender.
  ///
  /// Late Acks (RTT > timeout) are discarded to prevent SRTT inflation
  /// from timeout-delayed responses.
  void _tryRecordRtt(_PendingPing pending, NodeId ackSender, int timestampMs) {
    final rttMs = timestampMs - pending.sentAtMs;
    final timeout = effectivePingTimeoutForPeer(pending.target);

    if (rttMs <= 0) return;

    if (rttMs <= timeout.inMilliseconds) {
      final rttSample = Duration(milliseconds: rttMs);
      _rttTracker.recordSample(rttSample);
      peerRegistry.recordPeerRtt(pending.target, rttSample);
      _log(
        'Ack seq=${pending.sequence} from $ackSender target=${pending.target} '
        '(RTT: ${rttMs}ms)',
      );
    } else {
      _log(
        'Late Ack seq=${pending.sequence} from $ackSender '
        'RTT ${rttMs}ms exceeds timeout ${timeout.inMilliseconds}ms '
        '— sample discarded',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Private: ping infrastructure
  // ---------------------------------------------------------------------------

  _PendingPing _trackPendingPing(NodeId target, int sequence) {
    final pending = _PendingPing(
      target: target,
      sequence: sequence,
      sentAtMs: timePort.nowMs,
    );
    _pendingPings[sequence] = pending;
    return pending;
  }

  Future<void> _sendPing(NodeId target, int sequence) async {
    _pingsSent++;
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

  void _emitError(SyncError error) {
    onError?.call(error);
  }

  void _log(String message) {
    onLog?.call(LogLevel.debug, '[SWIM] $message');
  }
}
