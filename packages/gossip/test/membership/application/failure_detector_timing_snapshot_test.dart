import 'package:gossip/src/shared/domain/services/rtt_tracker.dart';
import 'package:gossip/src/shared/domain/value_objects/rtt_estimate.dart';
import 'package:test/test.dart';

import 'failure_detector_test_harness.dart';

/// Behavior net for `FailureDetector.timingSnapshot` — the membership-owned
/// read model `Coordinator.getAdaptiveTimingStatus` assembles its RTT/timing
/// fields from. Mirrors the per-peer selection and global-tracker fallback
/// that previously lived inline in the coordinator.
void main() {
  group('FailureDetector.timingSnapshot', () {
    test('pairs the min-SRTT peer with that SAME peer\'s variance, not the '
        'independently-smallest variance across peers', () {
      final h = FailureDetectorTestHarness();
      final fast = h.addPeer('fast');
      final other = h.addPeer('other');

      // fast: two samples. First sample (100ms) initializes smoothedRtt
      // =100ms, variance=50ms (RFC 6298 first-sample rule). The second
      // sample (500ms) is a big jump, so EWMA lands at smoothedRtt=150ms,
      // variance=137.5ms -- the jump inflates fast's variance past
      // other's, even though fast keeps the smaller smoothed RTT.
      h.peerRegistry.recordPeerRtt(fast.id, const Duration(milliseconds: 100));
      h.peerRegistry.recordPeerRtt(fast.id, const Duration(milliseconds: 500));

      // other: single sample, so variance = sample / 2 = 100ms -- smaller
      // than fast's 137.5ms.
      h.peerRegistry.recordPeerRtt(other.id, const Duration(milliseconds: 200));

      final snapshot = h.detector.timingSnapshot();

      // Sanity check on the fixture itself: fast really is the min-SRTT
      // peer, and its variance really is the larger one -- otherwise this
      // test can't distinguish paired selection from unpaired selection.
      final fastEstimate = snapshot.perPeerRtt[fast.id]!;
      final otherEstimate = snapshot.perPeerRtt[other.id]!;
      expect(fastEstimate.smoothedRtt, lessThan(otherEstimate.smoothedRtt));
      expect(fastEstimate.rttVariance, greaterThan(otherEstimate.rttVariance));

      expect(snapshot.smoothedRtt, equals(const Duration(milliseconds: 150)));
      expect(
        snapshot.rttVariance,
        equals(const Duration(microseconds: 137500)),
        reason:
            'must pair the min-SRTT peer\'s own variance, not the '
            'independently-smallest variance across all peers',
      );
    });

    test('falls back to the global tracker when no peer has an RTT estimate '
        '-- all four fields fall back together', () {
      final rttTracker = RttTracker(
        initialEstimate: RttEstimate(
          smoothedRtt: const Duration(milliseconds: 300),
          rttVariance: const Duration(milliseconds: 75),
        ),
      );
      rttTracker.recordSample(const Duration(milliseconds: 320));
      final h = FailureDetectorTestHarness(rttTracker: rttTracker);
      // A registered peer with no RTT sample yet must not contribute to
      // perPeerRtt or defeat the fallback.
      h.addPeer('peer1');

      final snapshot = h.detector.timingSnapshot();

      expect(snapshot.perPeerRtt, isEmpty);
      expect(snapshot.smoothedRtt, equals(rttTracker.smoothedRtt));
      expect(snapshot.rttVariance, equals(rttTracker.rttVariance));
      expect(snapshot.sampleCount, equals(rttTracker.sampleCount));
      expect(snapshot.hasSamples, equals(rttTracker.hasReceivedSamples));
      expect(snapshot.hasSamples, isTrue);
    });

    test(
      'perPeerRtt contains an entry only for peers with an RTT estimate',
      () {
        final h = FailureDetectorTestHarness();
        final withRtt = h.addPeer('withRtt');
        final withoutRtt = h.addPeer('withoutRtt');
        h.peerRegistry.recordPeerRtt(
          withRtt.id,
          const Duration(milliseconds: 120),
        );

        final snapshot = h.detector.timingSnapshot();

        expect(snapshot.perPeerRtt, hasLength(1));
        expect(
          snapshot.perPeerRtt[withRtt.id]!.smoothedRtt,
          equals(const Duration(milliseconds: 120)),
        );
        expect(snapshot.perPeerRtt.containsKey(withoutRtt.id), isFalse);
        expect(snapshot.sampleCount, equals(1));
        expect(snapshot.hasSamples, isTrue);
      },
    );

    test(
      'carries this detector\'s own effective ping timeout and probe interval',
      () {
        final rttTracker = RttTracker(
          initialEstimate: RttEstimate(
            smoothedRtt: const Duration(milliseconds: 300),
            rttVariance: const Duration(milliseconds: 75),
          ),
        );
        final h = FailureDetectorTestHarness(rttTracker: rttTracker);

        final snapshot = h.detector.timingSnapshot();

        expect(snapshot.pingTimeout, equals(h.detector.effectivePingTimeout));
        expect(
          snapshot.probeInterval,
          equals(h.detector.effectiveProbeInterval),
        );
      },
    );
  });
}
