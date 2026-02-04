import 'package:gossip/src/domain/events/domain_event.dart';
import 'package:gossip/src/protocol/messages/ack.dart';
import 'package:gossip/src/protocol/messages/ping.dart';
import 'package:test/test.dart';

import 'failure_detector_test_harness.dart';

void main() {
  group('FailureDetector message handling', () {
    late FailureDetectorTestHarness h;
    late TestPeer peer;

    setUp(() {
      h = FailureDetectorTestHarness();
      peer = h.addPeer('peer1');
    });

    test('handlePing returns an Ack with matching sequence', () {
      final ping = Ping(sender: peer.id, sequence: 42);
      final ack = h.detector.handlePing(ping);

      expect(ack.sender, equals(h.localNode));
      expect(ack.sequence, equals(42));
    });

    test('handleAck updates peer last contact time', () {
      final peerBefore = h.peerRegistry.getPeer(peer.id)!;
      final initialContact = peerBefore.lastContactMs;

      final laterMs = DateTime.now().millisecondsSinceEpoch + 100;
      final ack = Ack(sender: peer.id, sequence: 1);
      h.detector.handleAck(ack, timestampMs: laterMs);

      final peerAfter = h.peerRegistry.getPeer(peer.id)!;
      expect(peerAfter.lastContactMs, equals(laterMs));
      expect(peerAfter.lastContactMs, greaterThan(initialContact));
    });

    test('recordProbeFailure increments failed probe count', () {
      expect(h.peerRegistry.getPeer(peer.id)!.failedProbeCount, equals(0));

      h.detector.recordProbeFailure(peer.id);

      expect(h.peerRegistry.getPeer(peer.id)!.failedProbeCount, equals(1));
    });

    test('checkPeerHealth marks peer as suspected after failure threshold', () {
      final h = FailureDetectorTestHarness(failureThreshold: 3);
      final peer = h.addPeer('peer1');

      h.detector.recordProbeFailure(peer.id);
      h.detector.recordProbeFailure(peer.id);
      h.detector.recordProbeFailure(peer.id);
      h.detector.checkPeerHealth(peer.id, occurredAt: DateTime.now());

      expect(
        h.peerRegistry.getPeer(peer.id)!.status,
        equals(PeerStatus.suspected),
      );
    });
  });
}
