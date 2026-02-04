import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';
import 'package:gossip/src/protocol/messages/ack.dart';
import 'package:test/test.dart';

import 'failure_detector_test_harness.dart';

void main() {
  group('FailureDetector RTT tracking', () {
    late FailureDetectorTestHarness h;
    late TestPeer peer;

    setUp(() {
      h = FailureDetectorTestHarness(
        pingTimeout: const Duration(milliseconds: 500),
      );
      peer = h.addPeer('peer1');
    });

    test('records RTT sample when Ack is received', () async {
      h.startListening();

      await h.probeWithAck(peer, afterDelay: const Duration(milliseconds: 150));

      expect(h.rttTracker.hasReceivedSamples, isTrue);
      expect(h.rttTracker.sampleCount, equals(1));
      expect(h.rttTracker.smoothedRtt.inMilliseconds, equals(150));

      h.stopListening();
    });

    test('exposes rttTracker for monitoring', () {
      expect(h.detector.rttTracker, same(h.rttTracker));
    });

    test('creates default RttTracker if none provided', () {
      final h2 = FailureDetectorTestHarness();
      expect(h2.detector.rttTracker, isNotNull);
      expect(h2.detector.rttTracker.hasReceivedSamples, isFalse);
    });

    test('multiple probe rounds update RTT estimate', () async {
      h.startListening();

      for (final rttMs in [100, 120, 110, 130, 115]) {
        await h.probeWithAck(peer, afterDelay: Duration(milliseconds: rttMs));
      }

      expect(h.rttTracker.sampleCount, equals(5));
      expect(h.rttTracker.smoothedRtt.inMilliseconds, closeTo(115, 30));

      h.stopListening();
    });

    test('records per-peer RTT sample when Ack is received', () async {
      h.startListening();

      await h.probeWithAck(peer, afterDelay: const Duration(milliseconds: 150));

      final peerEntity = h.peerRegistry.getPeer(peer.id)!;
      expect(peerEntity.metrics.rttEstimate, isNotNull);
      expect(
        peerEntity.metrics.rttEstimate!.smoothedRtt,
        equals(const Duration(milliseconds: 150)),
      );

      h.stopListening();
    });

    group('probeNewPeer', () {
      test('sends Ping to specified peer', () async {
        h.startListening();

        final ping = await h.probeWithAck(
          peer,
          afterDelay: const Duration(milliseconds: 100),
          useProbeNewPeer: true,
        );
        expect(ping.sender, equals(h.localNode));

        h.stopListening();
      });

      test('records per-peer RTT on successful Ack', () async {
        h.startListening();

        await h.probeWithAck(
          peer,
          afterDelay: const Duration(milliseconds: 200),
          useProbeNewPeer: true,
        );

        final peerEntity = h.peerRegistry.getPeer(peer.id)!;
        expect(peerEntity.metrics.rttEstimate, isNotNull);
        expect(
          peerEntity.metrics.rttEstimate!.smoothedRtt,
          equals(const Duration(milliseconds: 200)),
        );

        h.stopListening();
      });

      test('does not record failure on timeout', () async {
        h.startListening();

        final probeFuture = h.detector.probeNewPeer(peer.id);
        await h.flush();

        await h.timePort.advance(const Duration(seconds: 4));
        await probeFuture;

        expect(h.peerRegistry.getPeer(peer.id)!.failedProbeCount, equals(0));

        h.stopListening();
      });

      test('no-ops for unknown peer', () async {
        h.startListening();
        await h.detector.probeNewPeer(NodeId('unknown'));
        h.stopListening();
      });

      test('does not perform indirect ping', () async {
        final peer2 = h.addPeer('peer2');
        h.startListening();

        final (peer2Messages, peer2Sub) = h.captureMessages(peer2);

        final probeFuture = h.detector.probeNewPeer(peer.id);
        await h.flush();

        await h.timePort.advance(const Duration(seconds: 4));
        await probeFuture;

        expect(peer2Messages, isEmpty);

        await peer2Sub.cancel();
        h.stopListening();
      });
    });

    test('records per-peer RTT against probe target, not Ack sender', () async {
      final hCustom = FailureDetectorTestHarness(
        pingTimeout: const Duration(milliseconds: 500),
      );
      final peerA = hCustom.addPeer('peerA');
      final peerB = hCustom.addPeer('peerB');

      hCustom.startListening();

      final pingFuture = hCustom.expectPing(peerA);
      final probeFuture = hCustom.detector.probeNewPeer(peerA.id);
      final ping = await pingFuture;

      await hCustom.timePort.advance(const Duration(milliseconds: 100));

      // Respond with Ack from peerB (simulating forwarded indirect Ack)
      final ack = Ack(sender: peerB.id, sequence: ping.sequence);
      final peerBPort = InMemoryMessagePort(peerB.id, hCustom.bus);
      await peerBPort.send(hCustom.localNode, hCustom.codec.encode(ack));
      await hCustom.flush();

      await probeFuture;

      // RTT should be attributed to peerA (the target), not peerB (the sender)
      final peerAMetrics = hCustom.peerRegistry.getPeer(peerA.id)!.metrics;
      expect(
        peerAMetrics.rttEstimate,
        isNotNull,
        reason: 'RTT should be attributed to probe target (peerA)',
      );
      expect(peerAMetrics.rttEstimate!.smoothedRtt.inMilliseconds, 100);

      final peerBMetrics = hCustom.peerRegistry.getPeer(peerB.id)!.metrics;
      expect(
        peerBMetrics.rttEstimate,
        isNull,
        reason: 'RTT should NOT be attributed to Ack sender (peerB)',
      );

      await peerBPort.close();
      hCustom.stopListening();
    });

    test(
      'does not record RTT for late Ack that exceeds timeout window',
      () async {
        h.startListening();

        final pingFuture = h.expectPing(peer);
        final probeRoundFuture = h.detector.performProbeRound();
        final ping = await pingFuture;

        // Advance past the direct ping timeout (500ms)
        await h.timePort.advance(const Duration(milliseconds: 501));

        // Send the late direct Ack during the grace phase
        final lateAck = Ack(sender: peer.id, sequence: ping.sequence);
        await peer.port.send(h.localNode, h.codec.encode(lateAck));
        await h.flush();

        // Finish the grace phase
        await h.timePort.advance(const Duration(milliseconds: 501));
        await probeRoundFuture;

        expect(
          h.rttTracker.hasReceivedSamples,
          isFalse,
          reason: 'Late Ack RTT should be discarded',
        );
        expect(
          h.peerRegistry.getPeer(peer.id)!.metrics.rttEstimate,
          isNull,
          reason: 'Late Ack should not record per-peer RTT',
        );

        h.stopListening();
      },
    );

    test('records RTT for Ack that arrives within timeout window', () async {
      h.startListening();

      await h.probeWithAck(
        peer,
        afterDelay: const Duration(milliseconds: 400),
        useProbeNewPeer: true,
      );

      expect(
        h.rttTracker.hasReceivedSamples,
        isTrue,
        reason: 'Ack within timeout should record RTT',
      );
      expect(h.rttTracker.smoothedRtt.inMilliseconds, equals(400));

      final peerEntity = h.peerRegistry.getPeer(peer.id)!;
      expect(peerEntity.metrics.rttEstimate, isNotNull);
      expect(
        peerEntity.metrics.rttEstimate!.smoothedRtt.inMilliseconds,
        equals(400),
      );

      h.stopListening();
    });

    test('does not record RTT when Ack times out', () async {
      h.startListening();

      await h.probeWithTimeout();

      expect(h.rttTracker.hasReceivedSamples, isFalse);
      expect(h.rttTracker.sampleCount, equals(0));

      h.stopListening();
    });
  });
}
