import 'dart:math';

import 'package:test/test.dart';

import 'failure_detector_test_harness.dart';

/// Two-tier pacing for the probe loop: all-healthy rounds stretch the
/// interval toward the existing 30s cap; any miss or membership change
/// snaps it back. (Owner decision: minutes-scale half-open detection in
/// a deep-idle mesh is acceptable — hard disconnects surface via the
/// transport instantly.)
void main() {
  group('FailureDetector quiescence pacing', () {
    test('answered probe rounds grow the effective interval', () async {
      final h = FailureDetectorTestHarness();
      h.startListening(); // required for the detector to process Acks
      h.addAnsweringPeer('peer1'); // auto-acks pings
      final base = h.detector.effectiveProbeInterval;

      for (var i = 0; i < 4; i++) {
        await h.detector.performProbeRound();
      }

      expect(h.detector.effectiveProbeInterval, greaterThan(base));
      h.stopListening();
    });

    test('a missed probe snaps the interval back to base', () async {
      // Seeded so the round-robin shuffle (FailureDetector.selectRandomPeer)
      // is deterministic: with two probable peers, seed 0 visits peer1
      // before deadpeer in the first post-add cycle (verified empirically
      // — see task-6-report.md). This replaces the brief's blind
      // "3 rounds and hope the miss lands" loop, which both risked
      // flaking on peer selection and would hang forever on the miss
      // round: InMemoryTimePort's delay() never resolves without an
      // explicit advance(), so a round that times out needs one.
      final h = FailureDetectorTestHarness(random: Random(0));
      h.startListening(); // required for the detector to process Acks
      h.addAnsweringPeer('peer1');
      final base = h.detector.effectiveProbeInterval;
      for (var i = 0; i < 4; i++) {
        await h.detector.performProbeRound();
      }
      expect(h.detector.effectiveProbeInterval, greaterThan(base));

      h.addSilentPeer('deadpeer'); // never acks

      // Age peer1's contact past the current interval (WIRE4-3): the loop
      // above never advanced simulated time, so peer1's lastContactMs sits
      // exactly at nowMs and would otherwise be suppressed as "still
      // fresh" — dropping it from the probable set entirely and breaking
      // the seed-0 round-robin assumption below (deadpeer would be the
      // only candidate left, hanging this round on an unawaited timeout).
      await h.timePort.advance(
        h.detector.effectiveProbeInterval + const Duration(milliseconds: 1),
      );

      // First round of the new post-add cycle lands on peer1 (answered):
      // proves the interval keeps growing after the peer is merely added
      // — adding a peer via the harness does not call probeNewPeer, so no
      // news() fires from membership alone.
      await h.detector.performProbeRound();
      expect(h.detector.effectiveProbeInterval, greaterThan(base));

      // Second round of the cycle is guaranteed to land on deadpeer: a
      // genuine miss (direct probe times out, then the only reachable
      // peer — peer1 — is asked to indirect-probe on our behalf but never
      // forwards an Ack, since it's a dumb auto-Ack stub, not a real
      // detector). Drive both timeouts explicitly.
      final missRound = h.detector.performProbeRound();
      await h.flush();
      await h.advancePastTimeout(timeout: h.detector.effectivePingTimeout);
      await missRound;

      expect(h.detector.effectiveProbeInterval, base);
      h.stopListening();
    });

    test('start() resets the pacer after a pause (stop/start)', () async {
      // Final-review fix: FailureDetector.start() must reset the pacer,
      // mirroring GossipEngine.start()'s "a restart is news" comment.
      // Without this, pausing and resuming (e.g. Coordinator pause/resume)
      // can resume mid-backoff — up to ~30s stale — into a world that may
      // have changed while stopped.
      final h = FailureDetectorTestHarness();
      h.startListening();
      h.addAnsweringPeer('peer1');
      h.detector.start();
      final base = h.detector.effectiveProbeInterval;

      for (var i = 0; i < 4; i++) {
        await h.detector.performProbeRound();
      }
      expect(h.detector.effectiveProbeInterval, greaterThan(base));

      h.detector.stop();
      h.detector.start();

      expect(
        h.detector.effectiveProbeInterval,
        base,
        reason: 'a restart is news — must not resume mid-backoff into a '
            'stale world',
      );

      h.detector.stop();
      h.stopListening();
    });

    test('a static probeInterval bypasses the pacer', () async {
      final h = FailureDetectorTestHarness(
        probeInterval: const Duration(seconds: 2),
      );
      h.startListening(); // required for the detector to process Acks
      h.addAnsweringPeer('peer1');
      for (var i = 0; i < 4; i++) {
        await h.detector.performProbeRound();
      }
      expect(h.detector.effectiveProbeInterval, const Duration(seconds: 2));
      h.stopListening();
    });
  });
}
