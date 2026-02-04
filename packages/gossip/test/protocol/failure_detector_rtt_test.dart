import 'dart:async';

import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/domain/services/rtt_tracker.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_time_port.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';
import 'package:gossip/src/protocol/failure_detector.dart';
import 'package:gossip/src/protocol/messages/ping.dart';
import 'package:gossip/src/protocol/messages/ack.dart';
import 'package:gossip/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

void main() {
  group('FailureDetector RTT tracking', () {
    late NodeId localNode;
    late NodeId peerNode;
    late PeerRegistry peerRegistry;
    late InMemoryTimePort timePort;
    late InMemoryMessageBus bus;
    late InMemoryMessagePort localPort;
    late InMemoryMessagePort peerPort;
    late RttTracker rttTracker;
    late FailureDetector detector;
    late ProtocolCodec codec;

    setUp(() {
      localNode = NodeId('local');
      peerNode = NodeId('peer1');
      peerRegistry = PeerRegistry(localNode: localNode, initialIncarnation: 0);
      peerRegistry.addPeer(peerNode, occurredAt: DateTime.now());

      timePort = InMemoryTimePort();
      bus = InMemoryMessageBus();
      localPort = InMemoryMessagePort(localNode, bus);
      peerPort = InMemoryMessagePort(peerNode, bus);
      rttTracker = RttTracker();
      codec = ProtocolCodec();

      detector = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timePort,
        messagePort: localPort,
        rttTracker: rttTracker,
        pingTimeout: const Duration(milliseconds: 500),
      );
    });

    test('records RTT sample when Ack is received', () async {
      detector.startListening();

      // Set up listener to capture pings before starting probe round
      Ping? receivedPing;
      final pingCompleter = Completer<void>();
      final subscription = peerPort.incoming.listen((msg) {
        final decoded = codec.decode(msg.bytes);
        if (decoded is Ping) {
          receivedPing = decoded;
          pingCompleter.complete();
        }
      });

      // Start a probe round (don't await - it blocks waiting for ack)
      final probeRoundFuture = detector.performProbeRound();

      // Wait for ping to arrive
      await Future.delayed(Duration.zero);
      await pingCompleter.future;
      expect(receivedPing, isNotNull);

      // Advance time to simulate RTT of 150ms
      await timePort.advance(const Duration(milliseconds: 150));

      // Send Ack back
      final ack = Ack(sender: peerNode, sequence: receivedPing!.sequence);
      await peerPort.send(localNode, codec.encode(ack));

      // Allow ack to be processed
      await Future.delayed(Duration.zero);

      // Probe round should complete now since Ack was received
      await probeRoundFuture;

      // Verify RTT was recorded
      expect(rttTracker.hasReceivedSamples, isTrue);
      expect(rttTracker.sampleCount, equals(1));
      // RTT should be 150ms
      expect(rttTracker.smoothedRtt.inMilliseconds, equals(150));

      await subscription.cancel();
      detector.stopListening();
    });

    test('exposes rttTracker for monitoring', () {
      expect(detector.rttTracker, same(rttTracker));
    });

    test('creates default RttTracker if none provided', () {
      final detectorWithoutTracker = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timePort,
        messagePort: localPort,
      );

      expect(detectorWithoutTracker.rttTracker, isNotNull);
      expect(detectorWithoutTracker.rttTracker.hasReceivedSamples, isFalse);
    });

    test('multiple probe rounds update RTT estimate', () async {
      detector.startListening();

      // Run 5 probe rounds with varying RTTs
      final rtts = [100, 120, 110, 130, 115];
      for (final rttMs in rtts) {
        // Set up listener for this round's ping
        Ping? receivedPing;
        final pingCompleter = Completer<void>();
        final subscription = peerPort.incoming.listen((msg) {
          final decoded = codec.decode(msg.bytes);
          if (decoded is Ping && !pingCompleter.isCompleted) {
            receivedPing = decoded;
            pingCompleter.complete();
          }
        });

        // Start probe round
        final probeRoundFuture = detector.performProbeRound();

        // Wait for ping
        await Future.delayed(Duration.zero);
        await pingCompleter.future;

        // Advance time to simulate RTT
        await timePort.advance(Duration(milliseconds: rttMs));

        // Send Ack back
        final ack = Ack(sender: peerNode, sequence: receivedPing!.sequence);
        await peerPort.send(localNode, codec.encode(ack));

        // Allow ack to be processed
        await Future.delayed(Duration.zero);

        // Complete the probe round
        await probeRoundFuture;

        await subscription.cancel();
      }

      // Verify multiple samples were recorded
      expect(rttTracker.sampleCount, equals(5));
      // Smoothed RTT should be close to average (around 115ms)
      expect(rttTracker.smoothedRtt.inMilliseconds, closeTo(115, 30));

      detector.stopListening();
    });

    test('records per-peer RTT sample when Ack is received', () async {
      detector.startListening();

      Ping? receivedPing;
      final pingCompleter = Completer<void>();
      final subscription = peerPort.incoming.listen((msg) {
        final decoded = codec.decode(msg.bytes);
        if (decoded is Ping && !pingCompleter.isCompleted) {
          receivedPing = decoded;
          pingCompleter.complete();
        }
      });

      final probeRoundFuture = detector.performProbeRound();
      await Future.delayed(Duration.zero);
      await pingCompleter.future;

      await timePort.advance(const Duration(milliseconds: 150));

      final ack = Ack(sender: peerNode, sequence: receivedPing!.sequence);
      await peerPort.send(localNode, codec.encode(ack));
      await Future.delayed(Duration.zero);
      await probeRoundFuture;

      // Verify per-peer RTT was recorded on the peer entity
      final peer = peerRegistry.getPeer(peerNode)!;
      expect(peer.metrics.rttEstimate, isNotNull);
      expect(
        peer.metrics.rttEstimate!.smoothedRtt,
        equals(const Duration(milliseconds: 150)),
      );

      await subscription.cancel();
      detector.stopListening();
    });

    group('probeNewPeer', () {
      test('sends Ping to specified peer', () async {
        detector.startListening();

        Ping? receivedPing;
        final pingCompleter = Completer<void>();
        final subscription = peerPort.incoming.listen((msg) {
          final decoded = codec.decode(msg.bytes);
          if (decoded is Ping && !pingCompleter.isCompleted) {
            receivedPing = decoded;
            pingCompleter.complete();
          }
        });

        // Fire probeNewPeer (don't await yet)
        final probeFuture = detector.probeNewPeer(peerNode);

        await Future.delayed(Duration.zero);
        await pingCompleter.future;

        // Verify a Ping was sent to the specified peer
        expect(receivedPing, isNotNull);
        expect(receivedPing!.sender, equals(localNode));

        // Send Ack back to complete
        await timePort.advance(const Duration(milliseconds: 100));
        final ack = Ack(sender: peerNode, sequence: receivedPing!.sequence);
        await peerPort.send(localNode, codec.encode(ack));
        await Future.delayed(Duration.zero);

        await probeFuture;
        await subscription.cancel();
        detector.stopListening();
      });

      test('records per-peer RTT on successful Ack', () async {
        detector.startListening();

        Ping? receivedPing;
        final pingCompleter = Completer<void>();
        final subscription = peerPort.incoming.listen((msg) {
          final decoded = codec.decode(msg.bytes);
          if (decoded is Ping && !pingCompleter.isCompleted) {
            receivedPing = decoded;
            pingCompleter.complete();
          }
        });

        final probeFuture = detector.probeNewPeer(peerNode);
        await Future.delayed(Duration.zero);
        await pingCompleter.future;

        await timePort.advance(const Duration(milliseconds: 200));
        final ack = Ack(sender: peerNode, sequence: receivedPing!.sequence);
        await peerPort.send(localNode, codec.encode(ack));
        await Future.delayed(Duration.zero);

        await probeFuture;

        // Verify per-peer RTT was recorded
        final peer = peerRegistry.getPeer(peerNode)!;
        expect(peer.metrics.rttEstimate, isNotNull);
        expect(
          peer.metrics.rttEstimate!.smoothedRtt,
          equals(const Duration(milliseconds: 200)),
        );

        await subscription.cancel();
        detector.stopListening();
      });

      test('does not record failure on timeout', () async {
        detector.startListening();

        final probeFuture = detector.probeNewPeer(peerNode);
        await Future.delayed(Duration.zero);

        // Let it timeout (use global timeout since no per-peer estimate)
        await timePort.advance(const Duration(seconds: 4));

        await probeFuture;

        // Verify no failure was recorded
        final peer = peerRegistry.getPeer(peerNode)!;
        expect(peer.failedProbeCount, equals(0));

        detector.stopListening();
      });

      test('no-ops for unknown peer', () async {
        detector.startListening();

        final unknownNode = NodeId('unknown');
        // Should complete without error
        await detector.probeNewPeer(unknownNode);

        detector.stopListening();
      });

      test('does not perform indirect ping', () async {
        // Add a second peer so intermediaries exist
        final peer2 = NodeId('peer2');
        peerRegistry.addPeer(peer2, occurredAt: DateTime.now());
        final peer2Port = InMemoryMessagePort(peer2, bus);

        detector.startListening();

        // Track all messages to peer2 (should NOT receive PingReq)
        final peer2Messages = <dynamic>[];
        final peer2Sub = peer2Port.incoming.listen((msg) {
          peer2Messages.add(codec.decode(msg.bytes));
        });

        final probeFuture = detector.probeNewPeer(peerNode);
        await Future.delayed(Duration.zero);

        // Let it timeout
        await timePort.advance(const Duration(seconds: 4));

        await probeFuture;

        // Verify no indirect ping was sent to peer2
        expect(peer2Messages, isEmpty);

        await peer2Sub.cancel();
        await peer2Port.close();
        detector.stopListening();
      });
    });

    test('does not record RTT when Ack times out', () async {
      detector.startListening();

      // Start a probe round
      final probeRoundFuture = detector.performProbeRound();

      // Allow ping to be sent
      await Future.delayed(Duration.zero);

      // Don't send Ack - let it timeout
      await timePort.advance(const Duration(milliseconds: 501));
      await timePort.advance(const Duration(milliseconds: 501));

      await probeRoundFuture;

      // Verify no RTT was recorded
      expect(rttTracker.hasReceivedSamples, isFalse);
      expect(rttTracker.sampleCount, equals(0));

      detector.stopListening();
    });
  });
}
