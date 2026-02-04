import 'dart:math';
import 'dart:typed_data';

import 'package:gossip/src/domain/events/domain_event.dart' show PeerStatus;
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';
import 'package:gossip/src/infrastructure/ports/message_port.dart';
import 'package:gossip/src/protocol/messages/ack.dart';
import 'package:gossip/src/protocol/messages/ping.dart';
import 'package:gossip/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

import 'failure_detector_test_harness.dart';

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

void main() {
  group('FailureDetector', () {
    test('can be constructed with required dependencies', () {
      final h = FailureDetectorTestHarness();
      expect(h.detector, isNotNull);
    });

    test('selectRandomPeer returns null when no reachable peers', () {
      final h = FailureDetectorTestHarness();
      expect(h.detector.selectRandomPeer(), isNull);
    });

    test('selectRandomPeer returns a reachable peer', () {
      final h = FailureDetectorTestHarness();
      final peer = h.addPeer('peer1');

      final selected = h.detector.selectRandomPeer();
      expect(selected, isNotNull);
      expect(selected!.id, equals(peer.id));
    });

    test('probe round sends Ping to random peer', () async {
      final h = FailureDetectorTestHarness(
        pingTimeout: const Duration(milliseconds: 500),
      );
      final peer = h.addPeer('peer1');

      final pingFuture = h.expectPing(peer);
      final probeRoundFuture = h.detector.performProbeRound();
      final ping = await pingFuture;

      expect(ping.sender, equals(h.localNode));
      expect(ping.sequence, greaterThan(0));

      await h.advancePastTimeout();
      await probeRoundFuture;
    });

    test('listens to incoming Ping and responds with Ack', () async {
      final h = FailureDetectorTestHarness();
      final peer = h.addPeer('peer1');

      h.startListening();

      final ping = Ping(sender: peer.id, sequence: 42);
      final ackFuture = peer.port.incoming.first;

      await peer.port.send(h.localNode, h.codec.encode(ping));

      final message = await ackFuture.timeout(const Duration(seconds: 1));
      final ack = h.codec.decode(message.bytes);

      expect(ack, isA<Ack>());
      expect((ack as Ack).sender, equals(h.localNode));
      expect(ack.sequence, equals(42));

      h.stopListening();
    });

    test(
      'late Ack arriving during indirect ping phase prevents probe failure',
      () async {
        final h = FailureDetectorTestHarness(
          pingTimeout: const Duration(milliseconds: 500),
          random: Random(42),
        );
        final peer = h.addPeer('peer1');
        final intermediary = h.addPeer('intermediary');

        h.startListening();

        // Listen for Ping on both peers
        Ping? receivedPing;
        NodeId? pingTarget;
        final peerSub = peer.port.incoming.listen((msg) {
          final decoded = h.codec.decode(msg.bytes);
          if (decoded is Ping) {
            receivedPing = decoded;
            pingTarget = peer.id;
          }
        });
        final intermediarySub = intermediary.port.incoming.listen((msg) {
          final decoded = h.codec.decode(msg.bytes);
          if (decoded is Ping) {
            receivedPing = decoded;
            pingTarget = intermediary.id;
          }
        });

        final probeRoundFuture = h.detector.performProbeRound();
        await Future.delayed(Duration.zero);

        expect(receivedPing, isNotNull, reason: 'Ping should have been sent');

        // Advance past direct timeout → indirect ping phase
        await h.timePort.advance(const Duration(milliseconds: 501));
        await Future.delayed(Duration.zero);

        // Send "late" Ack during indirect phase
        final ack = Ack(sender: pingTarget!, sequence: receivedPing!.sequence);
        final senderPort = pingTarget == peer.id
            ? peer.port
            : intermediary.port;
        await senderPort.send(h.localNode, h.codec.encode(ack));
        await Future.delayed(Duration.zero);

        await h.timePort.advance(const Duration(milliseconds: 500));
        await probeRoundFuture;

        final probed = h.peerRegistry.getPeer(pingTarget!);
        expect(
          probed!.failedProbeCount,
          equals(0),
          reason: 'Late Ack should prevent probe failure',
        );
        expect(probed.status, equals(PeerStatus.reachable));

        await peerSub.cancel();
        await intermediarySub.cancel();
        h.stopListening();
      },
    );

    test(
      'late Ack in 2-device scenario (no intermediaries) prevents probe failure',
      () async {
        final h = FailureDetectorTestHarness(
          pingTimeout: const Duration(milliseconds: 500),
        );
        final peer = h.addPeer('peer1');

        h.startListening();

        final pingFuture = h.expectPing(peer);
        final probeRoundFuture = h.detector.performProbeRound();
        final ping = await pingFuture;

        // Advance past direct timeout → grace period
        await h.timePort.advance(const Duration(milliseconds: 501));
        await Future.delayed(Duration.zero);

        // Send "late" Ack during grace period
        await h.sendAck(peer, ping.sequence);

        await h.timePort.advance(const Duration(milliseconds: 500));
        await probeRoundFuture;

        final probed = h.peerRegistry.getPeer(peer.id)!;
        expect(
          probed.failedProbeCount,
          equals(0),
          reason: 'Late Ack during grace period should prevent failure',
        );
        expect(probed.status, equals(PeerStatus.reachable));

        h.stopListening();
      },
    );

    test('probe failure is recorded when no Ack arrives at all', () async {
      final h = FailureDetectorTestHarness(
        pingTimeout: const Duration(milliseconds: 500),
      );
      h.addPeer('peer1');

      final probeRoundFuture = h.detector.performProbeRound();
      await Future.delayed(Duration.zero);

      await h.advancePastTimeout();
      await probeRoundFuture;

      final peer = h.peerRegistry.getPeer(NodeId('peer1'))!;
      expect(
        peer.failedProbeCount,
        equals(1),
        reason: 'Probe failure should be recorded when no Ack arrives',
      );
    });

    test('sends SWIM messages with high priority', () async {
      // This test needs a custom MessagePort to capture priorities.
      final bus = InMemoryMessageBus();
      final localPort = InMemoryMessagePort(NodeId('local'), bus);
      final capPort = PriorityCapturingMessagePort(localPort);
      final peerPort = InMemoryMessagePort(NodeId('peer1'), bus);

      final hCap = FailureDetectorTestHarness(
        pingTimeout: const Duration(milliseconds: 500),
        messagePort: capPort,
      );
      hCap.addPeer('peer1');
      hCap.startListening();

      final probeRoundFuture = hCap.detector.performProbeRound();
      await Future.delayed(Duration.zero);

      expect(capPort.capturedPriorities, isNotEmpty);
      expect(
        capPort.capturedPriorities.first,
        equals(MessagePriority.high),
        reason: 'Ping should be sent with high priority',
      );

      // Send a Ping to detector so it responds with Ack
      final codec = ProtocolCodec();
      final pingMsg = Ping(sender: NodeId('peer1'), sequence: 99);
      await peerPort.send(NodeId('local'), codec.encode(pingMsg));
      await Future.delayed(Duration.zero);

      expect(capPort.capturedPriorities.length, greaterThanOrEqualTo(2));
      expect(
        capPort.capturedPriorities,
        everyElement(equals(MessagePriority.high)),
        reason: 'All SWIM messages should use high priority',
      );

      await hCap.timePort.advance(const Duration(milliseconds: 501));
      await hCap.timePort.advance(const Duration(milliseconds: 501));
      await probeRoundFuture;
      hCap.stopListening();
    });
  });
}
