import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

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
  /// Target peer being probed.
  final NodeId target;

  /// Sequence number matching the Ping message.
  final int sequence;

  /// Timestamp when Ping was sent (milliseconds since epoch for RTT calculation).
  final int sentAtMs;

  /// Completes with true when matching Ack arrives, false on explicit failure.
  final Completer<bool> completer;

  _PendingPing({
    required this.target,
    required this.sequence,
    required this.sentAtMs,
  }) : completer = Completer<bool>();
}

/// Protocol service implementing SWIM failure detection.
///
/// [FailureDetector] detects peer failures through periodic probing with
/// automatic fallback to indirect probing. It implements the SWIM (Scalable
/// Weakly-consistent Infection-style Process Group Membership) protocol for
/// distributed failure detection.
///
/// ## Protocol Flow
///
/// **Probe Round (every 1 second)**:
/// 1. Select random reachable peer
/// 2. Send direct Ping
/// 3. Wait for Ack (default 500ms timeout)
/// 4. If no Ack, initiate indirect ping
///
/// **Indirect Ping (when direct probe fails)**:
/// 1. Select up to 3 other reachable peers as intermediaries
/// 2. Send PingReq to each intermediary
/// 3. Intermediaries ping the target and forward any Ack back
/// 4. Wait for Ack via any intermediary (default 500ms timeout)
/// 5. If no Ack, increment failed probe count
///
/// **Failure Detection**:
/// - After [failureThreshold] consecutive failures (default 3), mark peer as
///   [PeerStatus.suspected]
/// - Suspected peers can recover by responding to future probes (incarnation
///   refutation in SWIM)
///
/// ## Message Handling
///
/// Responds to three message types:
/// - **Ping**: Responds with Ack immediately
/// - **Ack**: Records peer contact, completes pending ping
/// - **PingReq**: Pings target on behalf of requester, forwards Ack back
///
/// ## Lifecycle
///
/// Must call [start] to begin probe rounds and [startListening] to handle
/// incoming messages. Both are independent; typically both are started together.
///
/// Used by: Application facades (Coordinator) to manage peer health monitoring.
class FailureDetector {
  /// Local node identifier for this instance.
  final NodeId localNode;

  /// Peer registry aggregate tracking all peer state.
  final PeerRegistry peerRegistry;

  /// Number of consecutive probe failures before marking peer as suspected.
  ///
  /// Default is 3. Higher values reduce false positives but increase detection time.
  final int failureThreshold;

  /// Timer abstraction for scheduling periodic probe rounds.
  final TimePort timePort;

  /// Message transport for sending/receiving protocol messages.
  final MessagePort messagePort;

  /// Optional callback for reporting synchronization errors.
  ///
  /// When provided, errors that would otherwise be silent are reported
  /// through this callback for observability.
  final ErrorCallback? onError;

  /// Codec for serializing/deserializing protocol messages.
  final ProtocolCodec _codec = ProtocolCodec();

  /// Random number generator for peer selection.
  final Random _random;

  /// Whether probe rounds are currently running.
  bool _isRunning = false;

  /// Handle for cancelling the periodic timer.
  TimerHandle? _timerHandle;

  /// Incrementing sequence number for correlating Ping/Ack pairs.
  int _nextSequence = 1;

  /// Subscription to incoming messages (for cleanup on stop).
  StreamSubscription<IncomingMessage>? _messageSubscription;

  /// Pending pings awaiting Ack responses, keyed by sequence number.
  final Map<int, _PendingPing> _pendingPings = {};

  /// Timeout for direct ping response.
  final Duration _pingTimeout;

  /// Timeout for indirect ping response (via intermediaries).
  final Duration _indirectPingTimeout;

  /// Interval between probe rounds.
  final Duration _probeInterval;

  /// RTT tracker for measuring round-trip time from ping/ack pairs.
  final RttTracker _rttTracker;

  /// Whether static timeouts were explicitly provided at construction.
  /// When true, uses static timeouts instead of adaptive RTT-based timeouts.
  final bool _staticTimeoutsProvided;

  FailureDetector({
    required this.localNode,
    required this.peerRegistry,
    this.failureThreshold = 3,
    required this.timePort,
    required this.messagePort,
    this.onError,
    Duration? pingTimeout,
    Duration? indirectPingTimeout,
    Duration? probeInterval,
    Random? random,
    RttTracker? rttTracker,
  }) : _pingTimeout = pingTimeout ?? const Duration(milliseconds: 500),
       _indirectPingTimeout =
           indirectPingTimeout ?? const Duration(milliseconds: 500),
       _probeInterval = probeInterval ?? const Duration(milliseconds: 1000),
       _random = random ?? Random(),
       _rttTracker = rttTracker ?? RttTracker(),
       _staticTimeoutsProvided = pingTimeout != null || probeInterval != null;

  /// Window duration for metrics sliding window (10 seconds).
  static const int _metricsWindowDurationMs = 10000;

  /// Minimum ping timeout (network physics floor).
  static const Duration _minPingTimeout = Duration(milliseconds: 200);

  /// Maximum ping timeout (reasonable upper limit).
  static const Duration _maxPingTimeout = Duration(seconds: 10);

  /// Minimum probe interval.
  static const Duration _minProbeInterval = Duration(milliseconds: 500);

  /// Maximum probe interval.
  static const Duration _maxProbeInterval = Duration(seconds: 30);

  /// Multiplier for probe interval relative to ping timeout.
  /// Probe interval = 3 * pingTimeout to allow direct + indirect probes.
  static const int _probeIntervalMultiplier = 3;

  /// Emits an error through the callback if one is registered.
  void _emitError(SyncError error) {
    onError?.call(error);
  }

  /// Sends bytes to a peer with error handling.
  ///
  /// All SWIM protocol messages (Ping, Ack, PingReq) use high priority
  /// to ensure failure detection isn't delayed by gossip congestion.
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

  /// Whether probe rounds are currently active.
  bool get isRunning => _isRunning;

  /// RTT tracker for monitoring network latency.
  ///
  /// Exposes the RTT estimate and sample count for observability.
  RttTracker get rttTracker => _rttTracker;

  /// Returns the effective ping timeout based on RTT measurements.
  ///
  /// If a static [pingTimeout] was provided at construction, uses that value.
  /// Otherwise uses the RTT tracker's suggested timeout (smoothedRtt + 4 * variance),
  /// clamped to [_minPingTimeout, _maxPingTimeout].
  ///
  /// Before any RTT samples are collected, uses the initial conservative
  /// estimate (1 second + 4 * 500ms = 3 seconds).
  Duration get effectivePingTimeout {
    // Use static timeout if explicitly provided (for backward compatibility)
    if (_useStaticTimeouts) {
      return _pingTimeout;
    }
    return _rttTracker.suggestedTimeout(
      minTimeout: _minPingTimeout,
      maxTimeout: _maxPingTimeout,
    );
  }

  /// Returns the effective ping timeout for a specific peer.
  ///
  /// Uses the peer's per-peer RTT estimate if available, falling back to
  /// the global [effectivePingTimeout] when no per-peer estimate exists.
  /// This allows fast peers to use shorter timeouts while slow peers get
  /// longer ones, preventing false SWIM suspicion.
  Duration effectivePingTimeoutForPeer(NodeId peerId) {
    if (_useStaticTimeouts) {
      return _pingTimeout;
    }
    final peer = peerRegistry.getPeer(peerId);
    final peerRtt = peer?.metrics.rttEstimate;
    if (peerRtt != null) {
      return peerRtt.suggestedTimeout(
        minTimeout: _minPingTimeout,
        maxTimeout: _maxPingTimeout,
      );
    }
    return effectivePingTimeout;
  }

  /// Whether static timeouts were explicitly provided.
  bool get _useStaticTimeouts => _staticTimeoutsProvided;

  /// Returns the effective probe interval based on RTT measurements.
  ///
  /// If a static [probeInterval] was provided at construction, uses that value.
  /// Otherwise computed as 3x the effective ping timeout to allow time for both
  /// direct and indirect probes within each interval.
  ///
  /// Clamped to [_minProbeInterval, _maxProbeInterval].
  Duration get effectiveProbeInterval {
    // Use static interval if explicitly provided (for backward compatibility)
    if (_useStaticTimeouts) {
      return _probeInterval;
    }
    final baseInterval = effectivePingTimeout * _probeIntervalMultiplier;
    if (baseInterval < _minProbeInterval) return _minProbeInterval;
    if (baseInterval > _maxProbeInterval) return _maxProbeInterval;
    return baseInterval;
  }

  /// Starts periodic failure detection probe rounds.
  ///
  /// Schedules [performProbeRound] to run at adaptive intervals based on
  /// measured RTT. The interval adjusts as RTT samples are collected.
  /// Safe to call multiple times (subsequent calls are no-ops).
  ///
  /// Note: This does NOT start message listening. Call [startListening]
  /// separately to handle incoming Ping/Ack/PingReq messages.
  void start() {
    if (_isRunning) return;
    _isRunning = true;
    _scheduleNextProbeRound();
  }

  /// Schedules the next probe round using the current effective interval.
  ///
  /// Uses [delay] instead of periodic timer to allow the interval to adapt
  /// based on RTT measurements collected during probe rounds.
  void _scheduleNextProbeRound() {
    if (!_isRunning) return;
    timePort.delay(effectiveProbeInterval).then((_) {
      if (_isRunning) {
        _probeRound();
      }
    });
  }

  /// Stops periodic probe rounds.
  ///
  /// Cancels the timer but does NOT stop message listening. Call
  /// [stopListening] separately if needed.
  void stop() {
    if (!_isRunning) return;
    _isRunning = false;
    _timerHandle?.cancel();
    _timerHandle = null;
  }

  /// Starts listening to incoming Ping/Ack/PingReq messages.
  ///
  /// Subscribes to [messagePort.incoming] and processes all SWIM protocol
  /// messages. Safe to call multiple times (cancels previous subscription).
  ///
  /// Note: This does NOT start probe rounds. Call [start] separately to
  /// begin periodic probing.
  void startListening() {
    _messageSubscription = messagePort.incoming.listen(_handleIncomingMessage);
  }

  /// Stops listening to incoming messages.
  ///
  /// Cancels the message subscription. Pending pings are not affected.
  void stopListening() {
    _messageSubscription?.cancel();
    _messageSubscription = null;
  }

  /// Handles incoming SWIM protocol messages.
  ///
  /// Decodes message and dispatches to appropriate handler:
  /// - [Ping] → Send Ack back immediately
  /// - [Ack] → Complete pending ping, update peer contact
  /// - [PingReq] → Ping target on behalf of requester
  ///
  /// Malformed messages are silently ignored to prevent denial-of-service
  /// via protocol violations.
  Future<void> _handleIncomingMessage(IncomingMessage message) async {
    // Record metrics before processing (even if decode fails)
    final nowMs = timePort.nowMs;
    peerRegistry.recordMessageReceived(
      message.sender,
      message.bytes.length,
      nowMs,
      _metricsWindowDurationMs,
    );

    try {
      final protocolMessage = _codec.decode(message.bytes);

      if (protocolMessage is Ping) {
        _swimMessagesReceived++;
        _pingsReceived++;
        _log(
          'SWIM: Received Ping from ${message.sender} seq=${protocolMessage.sequence}',
        );
        final ack = handlePing(protocolMessage);
        final ackBytes = _codec.encode(ack);
        await _safeSend(message.sender, ackBytes, 'Ack');
        _log('SWIM: Sent Ack to ${message.sender} seq=${ack.sequence}');
      } else if (protocolMessage is Ack) {
        _swimMessagesReceived++;
        _acksReceived++;
        _log(
          'SWIM: Received Ack from ${protocolMessage.sender} seq=${protocolMessage.sequence}',
        );
        handleAck(protocolMessage, timestampMs: timePort.nowMs);
      } else if (protocolMessage is PingReq) {
        _swimMessagesReceived++;
        _pingReqsReceived++;
        _log(
          'SWIM: Received PingReq from ${message.sender} target=${protocolMessage.target} seq=${protocolMessage.sequence}',
        );
        await _handlePingReq(protocolMessage, message.sender);
      }
    } catch (e) {
      // Emit error for observability (intentionally non-fatal for DoS prevention)
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

  // SWIM message tracking for diagnostics
  int _swimMessagesReceived = 0;
  int _pingsReceived = 0;
  int _acksReceived = 0;
  int _pingReqsReceived = 0;
  int _pingsSent = 0;
  int _acksSent = 0;

  void _log(String message) {
    // Log via error callback for now (could add dedicated log callback later)
    // Using debugPrint to ensure visibility in Flutter logs
    // ignore: avoid_print
    print('[SWIM_DIAG] $message');
  }

  /// Handles PingReq (indirect ping request) from a peer.
  ///
  /// Implements the intermediary role in indirect probing:
  /// 1. Ping target on behalf of requester
  /// 2. Wait 200ms for Ack from target
  /// 3. If Ack received, forward it back to requester
  /// 4. If timeout, send nothing (requester will timeout and suspect target)
  ///
  /// This allows the requester to distinguish network partition from node
  /// failure. If multiple intermediaries can't reach the target, it's likely
  /// the target has failed rather than being partitioned.
  Future<void> _handlePingReq(PingReq pingReq, NodeId requester) async {
    final ping = Ping(sender: localNode, sequence: pingReq.sequence);
    final pingBytes = _codec.encode(ping);

    final pending = _PendingPing(
      target: pingReq.target,
      sequence: pingReq.sequence,
      sentAtMs: timePort.nowMs,
    );
    _pendingPings[pingReq.sequence] = pending;

    await _safeSend(pingReq.target, pingBytes, 'Ping');

    // Use timerPort.delay for deterministic testing
    final gotAck = await _awaitAckWithTimeout(
      pending,
      pingReq.sequence,
      Duration(milliseconds: 200),
    );

    if (gotAck) {
      final ack = Ack(sender: localNode, sequence: pingReq.sequence);
      final ackBytes = _codec.encode(ack);
      await _safeSend(requester, ackBytes, 'forwarded Ack');
    }
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
        .whenComplete(() {
          // Schedule next probe round with adaptive interval
          // (interval may have changed based on new RTT samples)
          _scheduleNextProbeRound();
        });
  }

  /// Performs a single probe round.
  ///
  /// Implements the core SWIM probing logic:
  /// 1. Select random reachable peer via [selectRandomPeer]
  /// 2. Send direct Ping with incrementing sequence number
  /// 3. Wait for Ack (timeout from [effectivePingTimeout], RTT-adaptive)
  /// 4. If no Ack, fall back to indirect ping via [_performIndirectPing]
  /// 5. Check if late Ack arrived during indirect ping phase
  ///
  /// Returns immediately if no reachable peers exist.
  Future<void> performProbeRound() async {
    final peer = selectRandomPeer();
    if (peer == null) return;

    final sequence = _nextSequence++;
    final pending = _trackPendingPing(peer.id, sequence);

    await _sendPing(peer.id, sequence);

    final peerTimeout = effectivePingTimeoutForPeer(peer.id);

    final gotDirectAck = await _awaitAckWithTimeout(
      pending,
      sequence,
      peerTimeout,
    );

    if (!gotDirectAck) {
      // Direct ping timed out, try indirect
      final gotIndirectAck = await _performIndirectPing(peer.id, sequence);

      // Check if original Ack arrived late (during indirect ping phase)
      // Only record failure if neither direct, indirect, nor late Ack succeeded
      if (!gotIndirectAck && !pending.completer.isCompleted) {
        _handleProbeFailure(peer.id);
      } else if (pending.completer.isCompleted && !gotIndirectAck) {
        // Late Ack arrived during indirect ping - log for diagnostics
        _log(
          'SWIM: Late Ack arrived for seq=$sequence from ${peer.id} '
          '(recovered during indirect ping phase)',
        );
      }
    }

    // Clean up after probe round completes
    _cleanupPendingPing(sequence);
  }

  /// Creates and tracks a pending ping for the given target and sequence.
  _PendingPing _trackPendingPing(NodeId target, int sequence) {
    final pending = _PendingPing(
      target: target,
      sequence: sequence,
      sentAtMs: timePort.nowMs,
    );
    _pendingPings[sequence] = pending;
    return pending;
  }

  /// Sends a Ping message to the target.
  Future<void> _sendPing(NodeId target, int sequence) async {
    _pingsSent++;
    _log(
      'SWIM: Sending Ping to $target seq=$sequence (total pings sent: $_pingsSent)',
    );
    final ping = Ping(sender: localNode, sequence: sequence);
    final bytes = _codec.encode(ping);
    await _safeSend(target, bytes, 'Ping');
  }

  /// Waits for Ack with timeout, returns true if received, false otherwise.
  ///
  /// Uses [timePort.delay] instead of [Future.timeout] to enable
  /// deterministic testing with fake time.
  ///
  /// IMPORTANT: Does NOT remove the pending ping on timeout. Late-arriving
  /// Acks can still be matched. Caller must clean up via [_cleanupPendingPing]
  /// after the probe round completes.
  Future<bool> _awaitAckWithTimeout(
    _PendingPing pending,
    int sequence,
    Duration timeout,
  ) async {
    // Race between ack arriving and timeout
    final timeoutFuture = timePort.delay(timeout).then((_) => false);
    final ackFuture = pending.completer.future;

    final gotAck = await Future.any([ackFuture, timeoutFuture]);
    // Don't remove pending ping here - let late Acks still be processed
    return gotAck;
  }

  /// Cleans up a pending ping after probe round completes.
  ///
  /// Called after both direct and indirect probes finish to remove
  /// the pending ping from tracking.
  void _cleanupPendingPing(int sequence) {
    _pendingPings.remove(sequence);
  }

  /// Performs indirect ping when direct ping fails.
  ///
  /// Indirect probing helps distinguish node failure from network partition.
  /// If multiple intermediaries at different network locations also can't
  /// reach the target, it's strong evidence the target has failed.
  ///
  /// Returns true if Ack was received via an intermediary, false otherwise.
  /// Does NOT record probe failure - caller decides based on late Ack status.
  ///
  /// When no intermediaries are available (e.g., 2-device scenario), waits
  /// for [effectivePingTimeout] as a grace period for late Acks to arrive.
  Future<bool> _performIndirectPing(NodeId target, int sequence) async {
    final intermediaries = _selectRandomIntermediaries(target, 3);
    final peerTimeout = effectivePingTimeoutForPeer(target);

    if (intermediaries.isEmpty) {
      // No intermediaries available - wait grace period for late Acks
      // This handles the 2-device scenario where direct ping times out
      // but the Ack is just slightly delayed
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

    // Clean up indirect ping tracking
    _cleanupPendingPing(indirectSeq);

    return gotAck;
  }

  /// Selects up to [count] random reachable peers, excluding [target].
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

  /// Sends PingReq to each intermediary asking them to probe [target].
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

  /// Records probe failure and checks if peer should transition to suspected.
  void _handleProbeFailure(NodeId target) {
    final peer = peerRegistry.getPeer(target);
    final currentFailedCount = peer?.failedProbeCount ?? 0;
    _log(
      'SWIM: Probe FAILED for $target '
      '(failed count: $currentFailedCount -> ${currentFailedCount + 1}, '
      'threshold: $failureThreshold, '
      'pings sent: $_pingsSent, acks received: $_acksReceived)',
    );
    recordProbeFailure(target);
    checkPeerHealth(target, occurredAt: DateTime.now());
  }

  /// Selects a random peer to probe (reachable or suspected).
  ///
  /// Delegates to [PeerRegistry.selectRandomProbablePeer] which includes
  /// suspected peers. This is essential for SWIM's recovery mechanism:
  /// suspected peers can become reachable again by responding to probes.
  ///
  /// Returns null if no probable peers exist.
  Peer? selectRandomPeer() {
    return peerRegistry.selectRandomProbablePeer(_random);
  }

  /// Handles incoming Ping by returning Ack with matching sequence.
  ///
  /// This is the core response in SWIM probing. The Ack proves this node
  /// is alive and reachable.
  ///
  /// Exposed as public for testing. Called by [_handleIncomingMessage].
  Ack handlePing(Ping ping) {
    return Ack(sender: localNode, sequence: ping.sequence);
  }

  /// Handles incoming Ack by recording peer contact and completing pending ping.
  ///
  /// Updates peer's last contact timestamp in registry (resetting failed probe
  /// count via side effect in PeerRegistry). If this Ack matches a pending ping,
  /// completes the completer to prevent timeout and records RTT sample.
  ///
  /// Exposed as public for testing. Called by [_handleIncomingMessage].
  void handleAck(Ack ack, {required int timestampMs}) {
    final peerBefore = peerRegistry.getPeer(ack.sender);
    final failedCountBefore = peerBefore?.failedProbeCount ?? 0;

    peerRegistry.updatePeerContact(ack.sender, timestampMs);

    final pending = _pendingPings[ack.sequence];
    if (pending != null && !pending.completer.isCompleted) {
      // Calculate and record RTT
      final rttMs = timestampMs - pending.sentAtMs;
      if (rttMs > 0) {
        final rttSample = Duration(milliseconds: rttMs);
        _rttTracker.recordSample(rttSample);
        peerRegistry.recordPeerRtt(ack.sender, rttSample);
        _log(
          'SWIM: Ack matched pending ping seq=${ack.sequence} from ${ack.sender} '
          '(RTT: ${rttMs}ms, failed count reset: $failedCountBefore -> 0)',
        );
      } else {
        _log(
          'SWIM: Ack matched pending ping seq=${ack.sequence} from ${ack.sender} '
          '(failed count reset: $failedCountBefore -> 0)',
        );
      }
      pending.completer.complete(true);
    } else {
      _log(
        'SWIM: Ack seq=${ack.sequence} from ${ack.sender} did NOT match any pending ping '
        '(pending sequences: ${_pendingPings.keys.toList()})',
      );
    }
  }

  /// Records a failed probe attempt for a peer.
  ///
  /// Increments the peer's failed probe count in registry. After
  /// [failureThreshold] consecutive failures, [checkPeerHealth] will
  /// transition peer to [PeerStatus.suspected].
  ///
  /// Exposed as public for testing. Called by [_performIndirectPing].
  void recordProbeFailure(NodeId peerId) {
    peerRegistry.incrementFailedProbeCount(peerId);
  }

  /// Probes a specific newly-connected peer to bootstrap its RTT estimate.
  ///
  /// Sends a targeted Ping to [peerId] and waits for an Ack. If the Ack
  /// arrives, the RTT sample is recorded as per-peer RTT data. On timeout,
  /// no failure is recorded (this is best-effort RTT bootstrapping, not
  /// failure detection).
  ///
  /// Unlike regular probe rounds:
  /// - No random peer selection — targets the specified peer
  /// - No indirect ping on timeout — purpose is RTT, not failure detection
  /// - No failure recording on timeout — regular probe rounds handle that
  ///
  /// Called fire-and-forget from Coordinator.addPeer() to get the first
  /// RTT sample within ~200ms of connection instead of waiting for random
  /// selection in probe rounds.
  Future<void> probeNewPeer(NodeId peerId) async {
    final peer = peerRegistry.getPeer(peerId);
    if (peer == null) return;

    final sequence = _nextSequence++;
    final pending = _trackPendingPing(peerId, sequence);

    await _sendPing(peerId, sequence);

    final timeout = effectivePingTimeoutForPeer(peerId);
    final gotAck = await _awaitAckWithTimeout(pending, sequence, timeout);

    _cleanupPendingPing(sequence);

    if (gotAck) {
      _log('SWIM: probeNewPeer got Ack from $peerId');
    } else {
      _log('SWIM: probeNewPeer timed out for $peerId (no failure recorded)');
    }
  }

  /// Checks peer health and transitions to suspected if threshold exceeded.
  ///
  /// If peer has failed [failureThreshold] or more consecutive probes and
  /// is still in [PeerStatus.reachable], transitions to [PeerStatus.suspected].
  ///
  /// Suspected peers can recover by responding to future probes (SWIM's
  /// incarnation refutation mechanism).
  ///
  /// Exposed as public for testing. Called by [_performIndirectPing].
  void checkPeerHealth(NodeId peerId, {required DateTime occurredAt}) {
    final peer = peerRegistry.getPeer(peerId);
    if (peer == null) return;

    if (peer.failedProbeCount >= failureThreshold &&
        peer.status == PeerStatus.reachable) {
      _log(
        'SWIM: Peer $peerId transitioning to SUSPECTED '
        '(failed probes: ${peer.failedProbeCount}, threshold: $failureThreshold)',
      );
      peerRegistry.updatePeerStatus(
        peerId,
        PeerStatus.suspected,
        occurredAt: occurredAt,
      );
    }
  }
}
