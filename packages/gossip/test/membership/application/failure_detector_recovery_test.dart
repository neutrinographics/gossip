import 'package:gossip/src/membership/domain/messages/ack.dart';
import 'package:gossip/src/membership/domain/messages/ping.dart';
import 'package:gossip/src/membership/infrastructure/membership_message_codec.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_version.dart';
import 'package:test/test.dart';

import 'failure_detector_test_harness.dart';

void main() {
  final codec = MembershipMessageCodec(wireVersion: WireVersion.v2);

  group('Ack sender validation', () {
    test('an Ack from a different peer with a colliding sequence does not '
        'confirm a direct probe', () async {
      final h = FailureDetectorTestHarness(
        pingTimeout: const Duration(milliseconds: 500),
      );
      final target = h.addPeer('target');
      final other = h.addPeer('other');

      final probe = h.detector.probeNewPeer(target.id);
      await h.flush();

      // Stale/foreign Ack matching the pending sequence (1) but from
      // the wrong peer.
      h.detector.handleAck(
        Ack(sender: other.id, sequence: 1),
        timestampMs: h.timePort.nowMs,
      );

      await h.timePort.advance(const Duration(milliseconds: 501));
      expect(
        await probe,
        isFalse,
        reason: 'an Ack from a different peer must not confirm the target',
      );
      expect(
        h.peerRegistry.getPeer(target.id)!.metrics.rttEstimate,
        isNull,
        reason: 'the foreign Ack must not pollute the target\'s RTT',
      );
    });
  });

  group('Listening lifecycle', () {
    test('startListening() twice does not double-process messages', () async {
      final h = FailureDetectorTestHarness();
      final peer = h.addPeer('peer1');

      h.detector.startListening();
      h.detector.startListening();

      final acks = <Ack>[];
      final sub = peer.port.incoming.listen((msg) {
        final decoded = codec.decode(msg.bytes);
        if (decoded is Ack) acks.add(decoded);
      });

      await peer.port.send(
        h.localNode,
        codec.encode(Ping(sender: peer.id, sequence: 42)),
      );
      await h.flush(3);

      expect(
        acks.length,
        equals(1),
        reason: 'a leaked second subscription answers every Ping twice',
      );

      await sub.cancel();
      h.detector.stopListening();
    });
  });

  group('RTT sample clamping', () {
    test('per-peer RTT samples are clamped like the global tracker', () async {
      final h = FailureDetectorTestHarness(
        pingTimeout: const Duration(minutes: 5),
      );
      final target = h.addPeer('target');

      final probe = h.detector.probeNewPeer(target.id);
      await h.flush();

      // Simulated 2-minute wall-clock jump before the Ack lands.
      await h.timePort.advance(const Duration(minutes: 2));
      h.detector.handleAck(
        Ack(sender: target.id, sequence: 1),
        timestampMs: h.timePort.nowMs,
      );
      await h.flush();
      expect(await probe, isTrue);

      final estimate = h.peerRegistry.getPeer(target.id)!.metrics.rttEstimate;
      expect(estimate, isNotNull);
      expect(
        estimate!.smoothedRtt,
        equals(const Duration(seconds: 30)),
        reason:
            'a wall-clock jump must not seed the per-peer estimate with '
            'an unbounded first sample',
      );
    });
  });
}
