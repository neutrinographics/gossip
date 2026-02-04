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

    test('records per-peer RTT against probe target, not Ack sender', () {
      // Simulate a forwarded indirect Ack: the Ack sender is the
      // intermediary (peerB), but the pending ping target is peerA.
      // RTT should be attributed to peerA, not peerB.
      final peerA = NodeId('peerA');
      final peerB = NodeId('peerB');
      final registry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      registry.addPeer(peerA, occurredAt: DateTime.now());
      registry.addPeer(peerB, occurredAt: DateTime.now());

      final tracker = RttTracker();
      final fd = FailureDetector(
        localNode: localNode,
        peerRegistry: registry,
        timePort: timePort,
        messagePort: localPort,
        rttTracker: tracker,
        pingTimeout: const Duration(milliseconds: 500),
      );

      // Manually track a pending ping targeting peerA
      // Use handleAck's public API by simulating the sequence of events:
      // 1. Start a probe round that targets peerA
      // 2. Before it times out, send an Ack with sender=peerB (simulating forwarded Ack)
      //
      // Since we can't easily control peer selection, we'll use handleAck
      // directly by first inserting a pending ping via probeNewPeer's internal
      // mechanism. But probeNewPeer is async and blocks. Instead, test via
      // the codec: send a direct ping to set up the pending entry, then
      // respond with a mismatched sender.

      fd.startListening();

      // We need to create a pending ping for peerA. The simplest way is
      // to use performProbeRound. With only peerA and peerB in the registry,
      // the selected peer will be one of them. We'll capture the sequence
      // and respond with the wrong sender.

      // Actually, the cleanest approach: call handleAck directly with a
      // sequence that matches a pending ping. We need to access _pendingPings
      // which is private. Instead, let's start probeNewPeer (which creates
      // a pending ping for the specific peer) and intercept.

      Ping? capturedPing;
      final peerAPort = InMemoryMessagePort(peerA, bus);
      final sub = peerAPort.incoming.listen((msg) {
        final decoded = codec.decode(msg.bytes);
        if (decoded is Ping) {
          capturedPing = decoded;
        }
      });

      // probeNewPeer targets peerA specifically
      final probeFuture = fd.probeNewPeer(peerA);

      // Let the ping be sent
      Future.delayed(Duration.zero).then((_) async {
        await Future.delayed(Duration.zero);
        expect(capturedPing, isNotNull);

        // Advance time to simulate 100ms RTT
        await timePort.advance(const Duration(milliseconds: 100));

        // Respond with Ack from peerB (simulating forwarded indirect Ack)
        final ack = Ack(sender: peerB, sequence: capturedPing!.sequence);
        final peerBPort = InMemoryMessagePort(peerB, bus);
        await peerBPort.send(localNode, codec.encode(ack));
        await peerBPort.close();
      });

      return probeFuture.then((_) async {
        // Per-peer RTT should be attributed to peerA (the target), not peerB
        final peerAMetrics = registry.getPeer(peerA)!.metrics;
        expect(
          peerAMetrics.rttEstimate,
          isNotNull,
          reason: 'RTT should be attributed to probe target (peerA)',
        );
        expect(peerAMetrics.rttEstimate!.smoothedRtt.inMilliseconds, 100);

        final peerBMetrics = registry.getPeer(peerB)!.metrics;
        expect(
          peerBMetrics.rttEstimate,
          isNull,
          reason: 'RTT should NOT be attributed to Ack sender (peerB)',
        );

        await sub.cancel();
        await peerAPort.close();
        fd.stopListening();
      });
    });

    test(
      'does not record RTT for late Ack that exceeds timeout window',
      () async {
        // This tests the scenario during performProbeRound where a direct
        // ping times out, the indirect/grace phase runs, and then the
        // original direct Ack arrives late. The pending ping (S1) stays
        // in the map throughout — the late Ack matches it but its RTT
        // sample should be discarded (exceeds timeout window).
        detector.startListening();

        // Capture the direct ping sequence
        Ping? capturedPing;
        final pingCompleter = Completer<void>();
        final sub = peerPort.incoming.listen((msg) {
          final decoded = codec.decode(msg.bytes);
          if (decoded is Ping && !pingCompleter.isCompleted) {
            capturedPing = decoded;
            pingCompleter.complete();
          }
        });

        // Start probe round (don't await — it blocks)
        final probeRoundFuture = detector.performProbeRound();
        await Future.delayed(Duration.zero);
        await pingCompleter.future;

        final directSeq = capturedPing!.sequence;

        // Advance past the direct ping timeout (500ms)
        await timePort.advance(const Duration(milliseconds: 501));

        // Now we're in the indirect/grace phase. Send the late direct
        // Ack — it matches _pendingPings[S1] which is still alive.
        final lateAck = Ack(sender: peerNode, sequence: directSeq);
        await peerPort.send(localNode, codec.encode(lateAck));
        await Future.delayed(Duration.zero);

        // Finish the grace phase timeout
        await timePort.advance(const Duration(milliseconds: 501));
        await probeRoundFuture;

        // The late Ack's RTT (~501ms) exceeds the 500ms timeout window.
        // It should NOT be recorded.
        expect(
          rttTracker.hasReceivedSamples,
          isFalse,
          reason: 'Late Ack RTT should be discarded',
        );

        final peer = peerRegistry.getPeer(peerNode)!;
        expect(
          peer.metrics.rttEstimate,
          isNull,
          reason: 'Late Ack should not record per-peer RTT',
        );

        await sub.cancel();
        detector.stopListening();
      },
    );

    test('records RTT for Ack that arrives within timeout window', () async {
      detector.startListening();

      Ping? capturedPing;
      final pingCompleter = Completer<void>();
      final sub = peerPort.incoming.listen((msg) {
        final decoded = codec.decode(msg.bytes);
        if (decoded is Ping && !pingCompleter.isCompleted) {
          capturedPing = decoded;
          pingCompleter.complete();
        }
      });

      final probeFuture = detector.probeNewPeer(peerNode);
      await Future.delayed(Duration.zero);
      await pingCompleter.future;

      // Advance time within the timeout window (400ms < 500ms timeout)
      await timePort.advance(const Duration(milliseconds: 400));

      final ack = Ack(sender: peerNode, sequence: capturedPing!.sequence);
      await peerPort.send(localNode, codec.encode(ack));
      await Future.delayed(Duration.zero);

      await probeFuture;

      // RTT SHOULD be recorded (within timeout window)
      expect(
        rttTracker.hasReceivedSamples,
        isTrue,
        reason: 'Ack within timeout should record RTT',
      );
      expect(rttTracker.smoothedRtt.inMilliseconds, equals(400));

      final peer = peerRegistry.getPeer(peerNode)!;
      expect(peer.metrics.rttEstimate, isNotNull);
      expect(peer.metrics.rttEstimate!.smoothedRtt.inMilliseconds, equals(400));

      await sub.cancel();
      detector.stopListening();
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
