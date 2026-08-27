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
        expect(
          h.detector.nextProbeTarget()!.id,
          stale.id,
          reason: 'only the stale peer needs a probe',
        );
      }
    });

    test('when every peer is fresh, no probe fires at all', () async {
      final h = FailureDetectorTestHarness();
      final a = h.addAnsweringPeer('a');
      final b = h.addAnsweringPeer('b');
      h.peerRegistry.updatePeerContact(a.id, h.timePort.nowMs);
      h.peerRegistry.updatePeerContact(b.id, h.timePort.nowMs);

      expect(h.detector.nextProbeTarget(), isNull);

      final sentBefore = h.sentMessageCount;
      await h.detector.performProbeRound();
      expect(
        h.sentMessageCount,
        sentBefore,
        reason: 'an all-fresh round must be radio silence',
      );
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

    // Final-review fix: freshness-only suppression keys on INBOUND evidence.
    // Under asymmetric one-way loss (our probes to a peer die, but the
    // peer's own traffic to us — e.g. its own unreachable-probing pings —
    // keeps arriving), lastContactMs is perpetually refreshed and we would
    // NEVER probe that peer, so a genuine failure is never detected. The
    // fix bounds suppression: every peer must be actually probed at least
    // once per 2-minute cap window regardless of freshness.
    test('a continuously fresh peer is still probed once the suppression '
        'cap elapses', () async {
      final h = FailureDetectorTestHarness();
      h.startListening(); // required for the detector to process Acks
      final peer = h.addAnsweringPeer('peer');

      // A never-probed peer's cap anchors at epoch 0 while the harness
      // clock starts at t=60s, so the cap expires at absolute t=120s.
      // These two rounds run at t=60s and t=90s — inside the window, where
      // continuous freshness alone suppresses the probe, exactly as
      // WIRE4-3 intends.
      for (var i = 0; i < 2; i++) {
        h.peerRegistry.updatePeerContact(peer.id, h.timePort.nowMs);
        await h.detector.performProbeRound();
        await h.timePort.advance(const Duration(seconds: 30));
      }
      expect(
        h.sentMessageCount,
        0,
        reason: 'still within the cap window — suppression holds',
      );

      // Reach absolute t=120s (the cap boundary for a never-probed peer)
      // while the peer keeps looking freshly contacted (simulating one-way
      // loss: our probes to it die, but its own traffic keeps refreshing
      // lastContactMs). The first round of this loop trips the cap.
      for (var i = 0; i < 3; i++) {
        h.peerRegistry.updatePeerContact(peer.id, h.timePort.nowMs);
        await h.detector.performProbeRound();
        await h.timePort.advance(const Duration(seconds: 30));
      }

      expect(
        h.sentMessageCount,
        greaterThan(0),
        reason:
            'the cap must force an actual probe within 2 minutes '
            'despite continuous freshness, or one-way loss to this peer '
            'would never be detected',
      );

      h.stopListening();
    });
  });
}
