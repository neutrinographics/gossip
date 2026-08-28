import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:gossip/src/membership/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/shared/domain/errors/sync_error.dart';
import 'package:gossip/src/shared/domain/services/rtt_tracker.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_message_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:gossip/src/shared/domain/interfaces/message_port.dart';
import 'package:gossip/src/membership/application/failure_detector.dart';
import 'package:gossip/src/membership/infrastructure/membership_message_codec.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_version.dart';
import 'package:gossip/src/membership/domain/messages/ack.dart';
import 'package:gossip/src/membership/domain/messages/ping.dart';
import 'package:gossip/src/membership/domain/messages/ping_req.dart';

import '../../support/pump.dart';

/// A MessagePort that throws on send, simulating transport failure.
class FailingSendMessagePort implements MessagePort {
  final MessagePort _delegate;
  bool shouldFail = true;

  FailingSendMessagePort(this._delegate);

  @override
  Future<void> send(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  }) async {
    if (shouldFail) {
      throw Exception('Transport send failed');
    }
    await _delegate.send(destination, bytes, priority: priority);
  }

  @override
  Stream<IncomingMessage> get incoming => _delegate.incoming;

  @override
  Future<void> close() => _delegate.close();

  @override
  int pendingSendCount(NodeId peer) => _delegate.pendingSendCount(peer);

  @override
  int get totalPendingSendCount => _delegate.totalPendingSendCount;
}

/// A MessagePort that counts every send, delegating the actual work.
///
/// Wraps whatever port the harness would otherwise hand the detector so
/// suppression tests can assert "no message went out this round"
/// without caring which protocol message it would have been.
class _CountingMessagePort implements MessagePort {
  final MessagePort _delegate;
  int sentCount = 0;

  _CountingMessagePort(this._delegate);

  @override
  Future<void> send(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  }) async {
    sentCount++;
    await _delegate.send(destination, bytes, priority: priority);
  }

  @override
  Stream<IncomingMessage> get incoming => _delegate.incoming;

  @override
  Future<void> close() => _delegate.close();

  @override
  int pendingSendCount(NodeId peer) => _delegate.pendingSendCount(peer);

  @override
  int get totalPendingSendCount => _delegate.totalPendingSendCount;
}

/// A MessagePort that captures the priority of each sent message.
class PriorityCapturingMessagePort implements MessagePort {
  final MessagePort _delegate;
  final List<MessagePriority> capturedPriorities = [];

  PriorityCapturingMessagePort(this._delegate);

  @override
  Future<void> send(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  }) async {
    capturedPriorities.add(priority);
    await _delegate.send(destination, bytes, priority: priority);
  }

  @override
  Stream<IncomingMessage> get incoming => _delegate.incoming;

  @override
  Future<void> close() => _delegate.close();

  @override
  int pendingSendCount(NodeId peer) => _delegate.pendingSendCount(peer);

  @override
  int get totalPendingSendCount => _delegate.totalPendingSendCount;
}

/// A peer node managed by the test harness.
class TestPeer {
  final NodeId id;
  final InMemoryMessagePort port;

  TestPeer(this.id, this.port);

  /// Captures the next [Ping] arriving at this peer.
  ///
  /// Sets up a subscription eagerly, so call this **before** the Ping is sent.
  ///
  /// Races against a real-time timeout: with no timeout, a probe that a
  /// regression silently suppresses never arrives, and the wait hangs
  /// until the whole test file is killed by the suite's own timeout —
  /// which reports a generic "test timed out" with no clue which peer
  /// went unprobed. Failing fast here, by name, turns that into an
  /// immediate, diagnosable failure.
  Future<Ping> capturePing(MembershipMessageCodec codec) {
    final completer = Completer<Ping>();
    late StreamSubscription<IncomingMessage> sub;
    sub = port.incoming.listen((msg) {
      final decoded = codec.decode(msg.bytes);
      if (decoded is Ping && !completer.isCompleted) {
        completer.complete(decoded);
        sub.cancel();
      }
    });
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        sub.cancel();
        throw StateError(
          'no Ping arrived at ${id.value} — was the probe '
          'suppressed?',
        );
      },
    );
  }
}

/// Test harness encapsulating FailureDetector infrastructure.
///
/// Reduces boilerplate in failure detector tests by managing node creation,
/// message bus wiring, and common probe interaction patterns.
///
/// ```dart
/// late FailureDetectorTestHarness h;
/// late TestPeer peer;
///
/// setUp(() {
///   h = FailureDetectorTestHarness(
///     pingTimeout: const Duration(milliseconds: 500),
///   );
///   peer = h.addPeer('peer1');
/// });
///
/// test('records RTT', () async {
///   h.startListening();
///   await h.probeWithAck(peer,
///       afterDelay: const Duration(milliseconds: 150));
///   expect(h.rttTracker.hasReceivedSamples, isTrue);
///   h.stopListening();
/// });
/// ```
class FailureDetectorTestHarness {
  final NodeId localNode;
  final PeerRegistry peerRegistry;
  final InMemoryTimePort timePort;
  final InMemoryMessageBus bus;
  final InMemoryMessagePort localPort;
  final FailureDetector detector;
  final MembershipMessageCodec codec = MembershipMessageCodec(
    wireVersion: WireVersion.v2,
  );
  final RttTracker rttTracker;
  final List<SyncError> errors;
  final _CountingMessagePort _sendCounter;

  final List<TestPeer> _peers = [];

  FailureDetectorTestHarness._({
    required this.localNode,
    required this.peerRegistry,
    required this.timePort,
    required this.bus,
    required this.localPort,
    required this.detector,
    required this.rttTracker,
    required this.errors,
    required _CountingMessagePort sendCounter,
  }) : _sendCounter = sendCounter;

  /// Number of messages the local detector has sent (Ping/Ack/PingReq),
  /// across whichever [MessagePort] the harness is using.
  ///
  /// Used by suppression tests to assert an all-fresh probe
  /// round is radio silence.
  int get sentMessageCount => _sendCounter.sentCount;

  /// Creates a harness with the given configuration.
  ///
  /// All parameters are optional. Pass [wrapLocalPort] to interpose a
  /// double (e.g. [FailingSendMessagePort]) between the detector and the
  /// harness's own port. It must decorate the harness's port — rather
  /// than accept a caller-supplied replacement port outright — because
  /// [addPeer] wires every [TestPeer] onto the harness's own
  /// [InMemoryMessageBus]; a replacement port built on a different bus
  /// would leave the harness's send/expect helpers talking to peers the
  /// double can never see traffic from or to.
  factory FailureDetectorTestHarness({
    String localName = 'local',
    Duration? pingTimeout,
    Duration? probeInterval,
    int failureThreshold = 3,
    int unreachableThreshold = 9,
    int unreachableProbeInterval = 3,
    RttTracker? rttTracker,
    Random? random,
    MessagePort Function(MessagePort inner)? wrapLocalPort,
  }) {
    final localNode = NodeId(localName);
    final peerRegistry = PeerRegistry(localNode: localNode);
    final timePort = InMemoryTimePort();
    // Start the fake clock well past zero: a peer's lastContactMs
    // defaults to 0 ("never heard from"), and suppression compares it
    // against timePort.nowMs. On a real device nowMs is a wall-clock epoch
    // reading — always enormous — so a never-contacted peer is naturally
    // "ancient" and probes normally on cold start. InMemoryTimePort starts
    // at nowMs=0, which would make a peer added at test setup look exactly
    // as fresh as one just contacted "now", indistinguishable from real
    // freshness. Advancing once here (before anything is scheduled, so
    // there's nothing for tick()/pending-delay resolution to touch) restores
    // that real-world property for every test built on this harness.
    timePort.advance(const Duration(minutes: 1));
    final bus = InMemoryMessageBus();
    final localPort = InMemoryMessagePort(localNode, bus);
    final tracker = rttTracker ?? RttTracker();
    final errors = <SyncError>[];
    final effectiveLocalPort = wrapLocalPort != null
        ? wrapLocalPort(localPort)
        : localPort;
    final sendCounter = _CountingMessagePort(effectiveLocalPort);

    final detector = FailureDetector(
      codec: MembershipMessageCodec(wireVersion: WireVersion.v2),
      localNode: localNode,
      peerRegistry: peerRegistry,
      timePort: timePort,
      messagePort: sendCounter,
      failureThreshold: failureThreshold,
      unreachableThreshold: unreachableThreshold,
      unreachableProbeInterval: unreachableProbeInterval,
      rttTracker: tracker,
      onError: errors.add,
      pingTimeout: pingTimeout,
      probeInterval: probeInterval,
      random: random,
    );

    return FailureDetectorTestHarness._(
      localNode: localNode,
      peerRegistry: peerRegistry,
      timePort: timePort,
      bus: bus,
      localPort: localPort,
      detector: detector,
      rttTracker: tracker,
      errors: errors,
      sendCounter: sendCounter,
    );
  }

  // Peer management

  /// Adds a peer to the registry and creates its message port.
  TestPeer addPeer(String name) {
    final id = NodeId(name);
    peerRegistry.addPeer(id, occurredAt: DateTime.now());
    final port = InMemoryMessagePort(id, bus);
    final peer = TestPeer(id, port);
    _peers.add(peer);
    return peer;
  }

  /// Adds a peer that automatically Acks every [Ping] it receives, as if
  /// it were a healthy remote node running its own failure detector.
  ///
  /// Does not respond to [PingReq] — this peer is a dumb auto-responder,
  /// not a full detector, so it never acts as an indirect-probe
  /// intermediary.
  TestPeer addAnsweringPeer(String name) {
    final peer = addPeer(name);
    peer.port.incoming.listen((msg) {
      final decoded = codec.decode(msg.bytes);
      if (decoded is Ping) {
        final ack = Ack(sender: peer.id, sequence: decoded.sequence);
        peer.port.send(localNode, codec.encode(ack));
      }
    });
    return peer;
  }

  /// Adds a peer that never responds to anything — used to exercise the
  /// probe-miss path. Equivalent to [addPeer]; named for clarity at call
  /// sites that pair it with [addAnsweringPeer].
  TestPeer addSilentPeer(String name) => addPeer(name);

  // Probe helpers

  /// Returns a future that resolves to the next [Ping] arriving at [peer].
  ///
  /// **Must be called BEFORE starting the probe** that will send the Ping.
  /// The subscription is set up eagerly so it catches the Ping when it
  /// arrives via the InMemoryMessageBus (which delivers synchronously).
  Future<Ping> expectPing(TestPeer peer) {
    return peer.capturePing(codec);
  }

  /// Runs a probe round and sends an Ack back, returning the [Ping].
  ///
  /// If [afterDelay] is provided, advances time by that duration before
  /// sending the Ack (simulating RTT). Uses [FailureDetector.performProbeRound]
  /// by default; pass [useProbeNewPeer] to use [FailureDetector.probeNewPeer]
  /// instead.
  Future<Ping> probeWithAck(
    TestPeer peer, {
    Duration? afterDelay,
    bool useProbeNewPeer = false,
  }) async {
    final pingFuture = expectPing(peer);
    final probeFuture = useProbeNewPeer
        ? detector.probeNewPeer(peer.id)
        : detector.performProbeRound();
    final ping = await pingFuture;
    await sendAck(peer, ping.sequence, afterDelay: afterDelay);
    await probeFuture;
    return ping;
  }

  /// Runs a probe round that times out (no Ack is sent).
  Future<void> probeWithTimeout() async {
    final sentBefore = sentMessageCount;
    final probeFuture = detector.performProbeRound();
    // The round must actually get its Ping out before time is advanced
    // past the timeout — otherwise the timeout races the send.
    await pumpUntil(
      () => sentMessageCount > sentBefore,
      describe: 'the probe round sending its Ping',
    );
    await advancePastTimeout();
    await probeFuture;
  }

  // Message helpers

  /// Sends an [Ack] from [peer] back to the local detector.
  ///
  /// If [afterDelay] is provided, advances time by that duration first
  /// to simulate RTT. Always yields a microtask after sending.
  Future<void> sendAck(
    TestPeer peer,
    int sequence, {
    Duration? afterDelay,
  }) async {
    if (afterDelay != null) {
      await timePort.advance(afterDelay);
    }
    final ack = Ack(sender: peer.id, sequence: sequence);
    await peer.port.send(localNode, codec.encode(ack));
    await flush();
  }

  /// Sends a [Ping] from [peer] to the local detector.
  Future<void> sendPing(TestPeer peer, {int sequence = 1}) async {
    final ping = Ping(sender: peer.id, sequence: sequence);
    await peer.port.send(localNode, codec.encode(ping));
    await flush();
  }

  /// Sends a [PingReq] from [sender] to the local detector, requesting
  /// it probe [target].
  Future<void> sendPingReq(
    TestPeer sender,
    TestPeer target, {
    int sequence = 42,
  }) async {
    final pingReq = PingReq(
      sender: sender.id,
      sequence: sequence,
      target: target.id,
    );
    await sender.port.send(localNode, codec.encode(pingReq));
    await flush();
  }

  /// Starts capturing all decoded messages arriving at [peer].
  ///
  /// Returns a record of `(messages, subscription)`. Cancel the subscription
  /// when done.
  (List<dynamic>, StreamSubscription<IncomingMessage>) captureMessages(
    TestPeer peer,
  ) {
    final messages = <dynamic>[];
    final sub = peer.port.incoming.listen((msg) {
      messages.add(codec.decode(msg.bytes));
    });
    return (messages, sub);
  }

  // Time helpers

  /// Yields the microtask queue [count] times to allow async message
  /// processing.
  ///
  /// Stays a fixed-count settle rather than a [pumpUntil] condition: it
  /// backs [sendAck], [sendPing], and [sendPingReq] (each waiting on
  /// whatever downstream effect that particular call site's test checks —
  /// an RTT sample, a pending-ping completion, an error surfacing, a
  /// captured reply — plus dozens of external call sites across other
  /// tests with their own distinct targets. No single observable
  /// condition covers all of them, so the caller-supplied count is the
  /// only intent [flush] itself can express; [probeWithTimeout] is the
  /// one internal caller with a single, nameable target, and waits on
  /// that directly instead of calling this.
  Future<void> flush([int count = 1]) async {
    for (var i = 0; i < count; i++) {
      await Future.delayed(Duration.zero);
    }
  }

  /// Advances time past a timeout, in two steps (direct + grace period).
  ///
  /// Uses [timeout] if provided, otherwise defaults to 501ms per step.
  Future<void> advancePastTimeout({Duration? timeout}) async {
    final step = timeout ?? const Duration(milliseconds: 501);
    await timePort.advance(step);
    await timePort.advance(step);
  }

  // Lifecycle

  void startListening() => detector.startListening();

  void stopListening() => detector.stopListening();

  /// Disposes all resources: stops listening and closes all peer ports.
  Future<void> dispose() async {
    detector.stopListening();
    for (final peer in _peers) {
      await peer.port.close();
    }
  }
}
