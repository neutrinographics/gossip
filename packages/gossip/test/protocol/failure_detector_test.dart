import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:gossip/src/domain/entities/peer.dart';
import 'package:gossip/src/domain/events/domain_event.dart' show PeerStatus;
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_time_port.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';
import 'package:gossip/src/infrastructure/ports/message_port.dart';
import 'package:gossip/src/protocol/failure_detector.dart';
import 'package:gossip/src/protocol/protocol_codec.dart';
import 'package:gossip/src/protocol/messages/ping.dart';
import 'package:gossip/src/protocol/messages/ack.dart';
import 'package:test/test.dart';

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
  FailureDetector createDetector(NodeId localNode, PeerRegistry peerRegistry) {
    final timer = InMemoryTimePort();
    final bus = InMemoryMessageBus();
    final messagePort = InMemoryMessagePort(localNode, bus);
    return FailureDetector(
      localNode: localNode,
      peerRegistry: peerRegistry,
      timePort: timer,
      messagePort: messagePort,
    );
  }

  group('FailureDetector', () {
    test('can be constructed with required dependencies', () {
      final localNode = NodeId('local');
      final peerRegistry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );

      final detector = createDetector(localNode, peerRegistry);

      expect(detector, isNotNull);
    });

    test('selectRandomPeer returns null when no reachable peers', () {
      final localNode = NodeId('local');
      final peerRegistry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      final detector = createDetector(localNode, peerRegistry);

      final peer = detector.selectRandomPeer();

      expect(peer, isNull);
    });

    test('selectRandomPeer returns a reachable peer', () {
      final localNode = NodeId('local');
      final peerRegistry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      final detector = createDetector(localNode, peerRegistry);

      // Add a peer
      final peer1 = NodeId('peer1');
      peerRegistry.addPeer(peer1, occurredAt: DateTime.now());

      final selected = detector.selectRandomPeer();

      expect(selected, isNotNull);
      expect(selected!.id, equals(peer1));
    });

    test('probe round sends Ping to random peer', () async {
      final localNode = NodeId('local');
      final peerNode = NodeId('peer1');
      final peerRegistry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      peerRegistry.addPeer(peerNode, occurredAt: DateTime.now());

      final timer = InMemoryTimePort();
      final bus = InMemoryMessageBus();
      final localPort = InMemoryMessagePort(localNode, bus);
      final peerPort = InMemoryMessagePort(peerNode, bus);

      final detector = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timer,
        messagePort: localPort,
        pingTimeout: const Duration(milliseconds: 500),
        indirectPingTimeout: const Duration(milliseconds: 500),
      );

      // Capture the ping message when it arrives
      IncomingMessage? receivedMessage;
      final subscription = peerPort.incoming.listen((msg) {
        receivedMessage = msg;
      });

      // Trigger a probe round (don't await - it will wait for ack)
      final probeRoundFuture = detector.performProbeRound();

      // Allow the async probe round to send the ping and message to be delivered
      await Future.delayed(Duration.zero);

      // Verify Ping was sent
      expect(receivedMessage, isNotNull);
      final codec = ProtocolCodec();
      final ping = codec.decode(receivedMessage!.bytes);

      expect(ping, isA<Ping>());
      expect((ping as Ping).sender, equals(localNode));
      expect(ping.sequence, greaterThan(0));

      // Advance time to complete the probe round timeout
      // Need to advance in two steps: first past direct timeout, then past grace period
      // (the grace period delay is only scheduled after direct timeout expires)
      await timer.advance(
        const Duration(milliseconds: 501),
      ); // Past direct timeout
      await timer.advance(
        const Duration(milliseconds: 501),
      ); // Past grace period
      await probeRoundFuture;

      await subscription.cancel();
    });

    test('listens to incoming Ping and responds with Ack', () async {
      final localNode = NodeId('local');
      final peerNode = NodeId('peer1');
      final peerRegistry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      peerRegistry.addPeer(peerNode, occurredAt: DateTime.now());

      final timer = InMemoryTimePort();
      final bus = InMemoryMessageBus();
      final localPort = InMemoryMessagePort(localNode, bus);
      final peerPort = InMemoryMessagePort(peerNode, bus);

      final detector = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timer,
        messagePort: localPort,
      );

      // Start listening
      detector.startListening();

      // Peer sends Ping
      final codec = ProtocolCodec();
      final ping = Ping(sender: peerNode, sequence: 42);
      final pingBytes = codec.encode(ping);

      // Set up listener for Ack response
      final ackFuture = peerPort.incoming.first;

      await peerPort.send(localNode, pingBytes);

      // Verify Ack was sent back
      final message = await ackFuture.timeout(Duration(seconds: 1));
      final ack = codec.decode(message.bytes);

      expect(ack, isA<Ack>());
      expect((ack as Ack).sender, equals(localNode));
      expect(ack.sequence, equals(42)); // Same sequence as Ping

      // Clean up
      detector.stopListening();
    });

    test(
      'late Ack arriving after direct timeout but during indirect ping phase prevents probe failure',
      () async {
        final localNode = NodeId('local');
        final peerNode = NodeId('peer1');
        final intermediaryNode = NodeId('intermediary');
        final peerRegistry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        peerRegistry.addPeer(peerNode, occurredAt: DateTime.now());
        // Add intermediary so indirect ping phase actually runs
        peerRegistry.addPeer(intermediaryNode, occurredAt: DateTime.now());

        final timer = InMemoryTimePort();
        final bus = InMemoryMessageBus();
        final localPort = InMemoryMessagePort(localNode, bus);
        final peerPort = InMemoryMessagePort(peerNode, bus);
        final intermediaryPort = InMemoryMessagePort(intermediaryNode, bus);
        final codec = ProtocolCodec();

        // Use seeded random to ensure peer1 is selected first
        final seededRandom = Random(42);

        final detector = FailureDetector(
          localNode: localNode,
          peerRegistry: peerRegistry,
          timePort: timer,
          messagePort: localPort,
          pingTimeout: Duration(milliseconds: 500),
          indirectPingTimeout: Duration(milliseconds: 500),
          random: seededRandom,
        );

        // Start listening so detector can receive Acks
        detector.startListening();

        // Listen for Ping from detector on both peers
        Ping? receivedPing;
        NodeId? pingTarget;
        final peerSubscription = peerPort.incoming.listen((msg) {
          final decoded = codec.decode(msg.bytes);
          if (decoded is Ping) {
            receivedPing = decoded;
            pingTarget = peerNode;
          }
        });
        final intermediarySubscription = intermediaryPort.incoming.listen((
          msg,
        ) {
          final decoded = codec.decode(msg.bytes);
          if (decoded is Ping) {
            receivedPing = decoded;
            pingTarget = intermediaryNode;
          }
        });

        // Start probe round (don't await - it will block waiting for ack/timeout)
        final probeRoundFuture = detector.performProbeRound();

        // Allow ping to be sent
        await Future.delayed(Duration.zero);
        expect(receivedPing, isNotNull, reason: 'Ping should have been sent');
        expect(pingTarget, isNotNull);

        // Advance time past direct ping timeout (500ms)
        // This triggers indirect ping phase
        await timer.advance(Duration(milliseconds: 501));

        // Allow indirect ping to start (PingReq sent to intermediary)
        await Future.delayed(Duration.zero);

        // Now send the "late" Ack from the target peer - arrives during indirect ping phase
        final ack = Ack(sender: pingTarget!, sequence: receivedPing!.sequence);
        final ackBytes = codec.encode(ack);
        final senderPort = pingTarget == peerNode ? peerPort : intermediaryPort;
        await senderPort.send(localNode, ackBytes);

        // Allow Ack to be processed
        await Future.delayed(Duration.zero);

        // Advance time to complete the indirect ping timeout
        await timer.advance(Duration(milliseconds: 500));

        // Wait for probe round to complete
        await probeRoundFuture;

        // Verify: the targeted peer should NOT have failed probe count incremented
        // because the late Ack was received during indirect ping phase
        final peer = peerRegistry.getPeer(pingTarget!);
        expect(peer, isNotNull);
        expect(
          peer!.failedProbeCount,
          equals(0),
          reason:
              'Late Ack should have prevented probe failure from being recorded',
        );
        expect(peer.status, equals(PeerStatus.reachable));

        // Clean up
        await peerSubscription.cancel();
        await intermediarySubscription.cancel();
        detector.stopListening();
      },
    );

    test(
      'late Ack in 2-device scenario (no intermediaries) prevents probe failure',
      () async {
        // This tests the scenario from phone logs where only 2 devices
        // are connected and the Ack arrives slightly after the direct
        // ping timeout. Without intermediaries, the indirect ping phase
        // would return immediately, not giving time for late Acks.
        // The fix adds a grace period wait even when no intermediaries exist.
        final localNode = NodeId('local');
        final peerNode = NodeId('peer1');
        final peerRegistry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        // Only one peer - no intermediaries available
        peerRegistry.addPeer(peerNode, occurredAt: DateTime.now());

        final timer = InMemoryTimePort();
        final bus = InMemoryMessageBus();
        final localPort = InMemoryMessagePort(localNode, bus);
        final peerPort = InMemoryMessagePort(peerNode, bus);
        final codec = ProtocolCodec();

        final detector = FailureDetector(
          localNode: localNode,
          peerRegistry: peerRegistry,
          timePort: timer,
          messagePort: localPort,
          pingTimeout: Duration(milliseconds: 500),
          indirectPingTimeout: Duration(milliseconds: 500),
        );

        // Start listening so detector can receive Acks
        detector.startListening();

        // Listen for Ping from detector
        Ping? receivedPing;
        final peerSubscription = peerPort.incoming.listen((msg) {
          final decoded = codec.decode(msg.bytes);
          if (decoded is Ping) {
            receivedPing = decoded;
          }
        });

        // Start probe round (don't await - it will block waiting for ack/timeout)
        final probeRoundFuture = detector.performProbeRound();

        // Allow ping to be sent
        await Future.delayed(Duration.zero);
        expect(receivedPing, isNotNull, reason: 'Ping should have been sent');

        // Advance time past direct ping timeout (500ms)
        // This triggers indirect ping phase (which has no intermediaries)
        await timer.advance(Duration(milliseconds: 501));

        // Allow indirect ping phase to start (it will wait for grace period)
        await Future.delayed(Duration.zero);

        // Send the "late" Ack during the grace period
        final ack = Ack(sender: peerNode, sequence: receivedPing!.sequence);
        final ackBytes = codec.encode(ack);
        await peerPort.send(localNode, ackBytes);

        // Allow Ack to be processed
        await Future.delayed(Duration.zero);

        // Advance time to complete the grace period
        await timer.advance(Duration(milliseconds: 500));

        // Wait for probe round to complete
        await probeRoundFuture;

        // Verify: the peer should NOT have failed probe count incremented
        // because the late Ack was received during the grace period
        final peer = peerRegistry.getPeer(peerNode);
        expect(peer, isNotNull);
        expect(
          peer!.failedProbeCount,
          equals(0),
          reason:
              'Late Ack during grace period should prevent probe failure in 2-device scenario',
        );
        expect(peer.status, equals(PeerStatus.reachable));

        // Clean up
        await peerSubscription.cancel();
        detector.stopListening();
      },
    );

    test('probe failure is recorded when no Ack arrives at all', () async {
      final localNode = NodeId('local');
      final peerNode = NodeId('peer1');
      final peerRegistry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      peerRegistry.addPeer(peerNode, occurredAt: DateTime.now());

      final timer = InMemoryTimePort();
      final bus = InMemoryMessageBus();
      final localPort = InMemoryMessagePort(localNode, bus);

      final detector = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timer,
        messagePort: localPort,
        pingTimeout: Duration(milliseconds: 500),
        indirectPingTimeout: Duration(milliseconds: 500),
      );

      // Start probe round (don't await)
      final probeRoundFuture = detector.performProbeRound();

      // Allow ping to be sent
      await Future.delayed(Duration.zero);

      // Advance past direct timeout
      await timer.advance(Duration(milliseconds: 501));

      // Advance past indirect timeout (no Ack sent)
      await timer.advance(Duration(milliseconds: 501));

      // Wait for probe round to complete
      await probeRoundFuture;

      // Verify: peer SHOULD have failed probe count incremented
      final peer = peerRegistry.getPeer(peerNode);
      expect(peer, isNotNull);
      expect(
        peer!.failedProbeCount,
        equals(1),
        reason: 'Probe failure should be recorded when no Ack arrives',
      );
    });

    test('sends SWIM messages with high priority', () async {
      final localNode = NodeId('local');
      final peerNode = NodeId('peer1');
      final peerRegistry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      peerRegistry.addPeer(peerNode, occurredAt: DateTime.now());

      final timer = InMemoryTimePort();
      final bus = InMemoryMessageBus();
      final delegatePort = InMemoryMessagePort(localNode, bus);
      final capturingPort = PriorityCapturingMessagePort(delegatePort);
      final peerPort = InMemoryMessagePort(peerNode, bus);
      final codec = ProtocolCodec();

      final detector = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timer,
        messagePort: capturingPort,
        pingTimeout: Duration(milliseconds: 500),
      );

      // Start listening so detector responds to Pings with Acks
      detector.startListening();

      // Trigger a probe round which sends a Ping
      final probeRoundFuture = detector.performProbeRound();

      // Allow Ping to be sent
      await Future.delayed(Duration.zero);

      // Verify Ping was sent with high priority
      expect(capturingPort.capturedPriorities, isNotEmpty);
      expect(
        capturingPort.capturedPriorities.first,
        equals(MessagePriority.high),
        reason: 'Ping should be sent with high priority',
      );

      // Send a Ping to detector so it responds with Ack
      final ping = Ping(sender: peerNode, sequence: 99);
      await peerPort.send(localNode, codec.encode(ping));

      // Allow Ack response to be sent
      await Future.delayed(Duration.zero);

      // Verify Ack was also sent with high priority
      // (Ping + Ack = 2 high priority messages)
      expect(capturingPort.capturedPriorities.length, greaterThanOrEqualTo(2));
      expect(
        capturingPort.capturedPriorities,
        everyElement(equals(MessagePriority.high)),
        reason: 'All SWIM messages (Ping, Ack) should use high priority',
      );

      // Clean up
      await timer.advance(Duration(milliseconds: 501));
      await timer.advance(Duration(milliseconds: 501));
      await probeRoundFuture;
      detector.stopListening();
    });
  });
}
