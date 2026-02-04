import 'dart:async';
import 'dart:math';

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
import 'package:gossip/src/protocol/protocol_codec.dart';

/// A peer node managed by the test harness.
class TestPeer {
  final NodeId id;
  final InMemoryMessagePort port;

  TestPeer(this.id, this.port);

  /// Captures the next [Ping] arriving at this peer.
  ///
  /// Listens on the peer's incoming stream and returns the first Ping
  /// received. Caller should `await Future.delayed(Duration.zero)` before
  /// calling this if the Ping hasn't been sent yet.
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
///   final future = h.detector.performProbeRound();
///   final ping = await h.capturePing(peer);
///   await h.sendAck(peer, ping.sequence,
///       afterDelay: const Duration(milliseconds: 150));
///   await future;
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

  /// Adds a peer to the registry and creates its message port.
  TestPeer addPeer(String name) {
    final id = NodeId(name);
    peerRegistry.addPeer(id, occurredAt: DateTime.now());
    final port = InMemoryMessagePort(id, bus);
    return TestPeer(id, port);
  }

  /// Returns a future that resolves to the next [Ping] arriving at [peer].
  ///
  /// **Must be called BEFORE starting the probe** that will send the Ping.
  /// The subscription is set up eagerly so it catches the Ping when it
  /// arrives via the InMemoryMessageBus (which delivers synchronously).
  ///
  /// Usage:
  /// ```dart
  /// final pingFuture = h.expectPing(peer);
  /// final probeFuture = h.detector.performProbeRound();
  /// final ping = await pingFuture;
  /// ```
  Future<Ping> expectPing(TestPeer peer) {
    return peer.capturePing(codec);
  }

  /// Sends an [Ack] from [peer] back to the local detector.
  ///
  /// If [afterDelay] is provided, advances time by that duration first
  /// to simulate RTT. Always runs a microtask yield after sending to
  /// allow the Ack to be processed.
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
    await Future.delayed(Duration.zero);
  }

  /// Advances time past a timeout, in two steps (direct + grace period).
  ///
  /// Uses [timeout] if provided, otherwise defaults to 501ms per step.
  Future<void> advancePastTimeout({Duration? timeout}) async {
    final step = timeout ?? const Duration(milliseconds: 501);
    await timePort.advance(step);
    await timePort.advance(step);
  }

  void startListening() => detector.startListening();

  void stopListening() => detector.stopListening();
}
