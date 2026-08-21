import 'package:test/test.dart';

import 'failure_detector_test_harness.dart';

/// WIRE4-3: gossip traffic is liveness evidence. lastContactMs — updated
/// by every inbound message, previously write-only — finally gets a
/// reader: peers heard from within the current probe interval are not
/// probed, and an all-fresh round sends nothing.
void main() {
  group('FailureDetector probe suppression', () {
    test('a peer heard from within the interval is not selected', () {
      final h = FailureDetectorTestHarness();
      final fresh = h.addAnsweringPeer('fresh');
      final stale = h.addAnsweringPeer('stale');
      h.peerRegistry.updatePeerContact(fresh.id, h.timePort.nowMs);
      // stale's lastContactMs stays 0 (never heard from).

      for (var i = 0; i < 4; i++) {
        expect(h.detector.selectRandomPeer()!.id, stale.id,
            reason: 'only the stale peer needs a probe');
      }
    });

    test('when every peer is fresh, no probe fires at all', () async {
      final h = FailureDetectorTestHarness();
      final a = h.addAnsweringPeer('a');
      final b = h.addAnsweringPeer('b');
      h.peerRegistry.updatePeerContact(a.id, h.timePort.nowMs);
      h.peerRegistry.updatePeerContact(b.id, h.timePort.nowMs);

      expect(h.detector.selectRandomPeer(), isNull);

      final sentBefore = h.sentMessageCount;
      await h.detector.performProbeRound();
      expect(h.sentMessageCount, sentBefore,
          reason: 'an all-fresh round must be radio silence');
    });

    test('suppression does not mark fresh peers as failed', () async {
      final h = FailureDetectorTestHarness();
      final a = h.addAnsweringPeer('a');
      h.peerRegistry.updatePeerContact(a.id, h.timePort.nowMs);

      for (var i = 0; i < 10; i++) {
        await h.detector.performProbeRound();
      }

      expect(h.peerRegistry.getPeer(a.id)!.failedProbeCount, 0);
    });
  });
}
