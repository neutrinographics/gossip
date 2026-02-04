import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/domain/errors/sync_error.dart';
import 'package:gossip/src/domain/services/rtt_tracker.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_time_port.dart';
import 'package:gossip/src/infrastructure/ports/message_port.dart';
import 'package:gossip/src/protocol/failure_detector.dart';
import 'package:gossip/src/protocol/messages/ack.dart';
import 'package:gossip/src/protocol/messages/ping.dart';
import 'package:gossip/src/protocol/messages/ping_req.dart';
import 'package:gossip/src/protocol/protocol_codec.dart';

// ---------------------------------------------------------------------------
// Reusable test doubles
// ---------------------------------------------------------------------------

/// A MessagePort that throws on send, simulating transport failure.
class FailingSendMessagePort implements MessagePort {
  final InMemoryMessagePort _delegate;
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

/// A MessagePort that captures the priority of each sent message.
class PriorityCapturingMessagePort implements MessagePort {
  final InMemoryMessagePort _delegate;
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

// ---------------------------------------------------------------------------
// Test peer
// ---------------------------------------------------------------------------

/// A peer node managed by the test harness.
class TestPeer {
  final NodeId id;
  final InMemoryMessagePort port;

  TestPeer(this.id, this.port);

  /// Captures the next [Ping] arriving at this peer.
  ///
  /// Sets up a subscription eagerly, so call this **before** the Ping is sent.
  Future<Ping> capturePing(ProtocolCodec codec) {
    final completer = Completer<Ping>();
    late StreamSubscription<IncomingMessage> sub;
    sub = port.incoming.listen((msg) {
      final decoded = codec.decode(msg.bytes);
      if (decoded is Ping && !completer.isCompleted) {
        completer.complete(decoded);
        sub.cancel();
      }
    });
    return completer.future;
  }
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

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
  final ProtocolCodec codec = ProtocolCodec();
  final RttTracker rttTracker;
  final List<SyncError> errors;

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
  });

  /// Creates a harness with the given configuration.
  ///
  /// All parameters are optional. Pass [messagePort] to use a custom
  /// MessagePort implementation (e.g. FailingSendMessagePort).
  factory FailureDetectorTestHarness({
    String localName = 'local',
    Duration? pingTimeout,
    Duration? probeInterval,
    int failureThreshold = 3,
    RttTracker? rttTracker,
    Random? random,
    MessagePort? messagePort,
  }) {
    final localNode = NodeId(localName);
    final peerRegistry = PeerRegistry(
      localNode: localNode,
      initialIncarnation: 0,
    );
    final timePort = InMemoryTimePort();
    final bus = InMemoryMessageBus();
    final localPort = InMemoryMessagePort(localNode, bus);
    final tracker = rttTracker ?? RttTracker();
    final errors = <SyncError>[];

    final detector = FailureDetector(
      localNode: localNode,
      peerRegistry: peerRegistry,
      timePort: timePort,
      messagePort: messagePort ?? localPort,
      failureThreshold: failureThreshold,
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
    );
  }

  // -------------------------------------------------------------------------
  // Peer management
  // -------------------------------------------------------------------------

  /// Adds a peer to the registry and creates its message port.
  TestPeer addPeer(String name) {
    final id = NodeId(name);
    peerRegistry.addPeer(id, occurredAt: DateTime.now());
    final port = InMemoryMessagePort(id, bus);
    final peer = TestPeer(id, port);
    _peers.add(peer);
    return peer;
  }

  // -------------------------------------------------------------------------
  // Probe helpers
  // -------------------------------------------------------------------------

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
  /// sending the Ack (simulating RTT). Uses [performProbeRound] by default;
  /// pass [useProbeNewPeer] to use [probeNewPeer] instead.
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
    final probeFuture = detector.performProbeRound();
    await flush();
    await advancePastTimeout();
    await probeFuture;
  }

  // -------------------------------------------------------------------------
  // Message helpers
  // -------------------------------------------------------------------------

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

  // -------------------------------------------------------------------------
  // Time helpers
  // -------------------------------------------------------------------------

  /// Yields the microtask queue [count] times to allow async message
  /// processing.
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

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

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
