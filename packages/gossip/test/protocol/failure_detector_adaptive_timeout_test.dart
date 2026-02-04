import 'package:gossip/src/domain/services/rtt_tracker.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/rtt_estimate.dart';
import 'package:test/test.dart';

import 'failure_detector_test_harness.dart';

void main() {
  group('FailureDetector adaptive timeouts', () {
    test(
      'effectivePingTimeout uses RTT-based timeout when estimate provided',
      () {
        final rttTracker = RttTracker(
          initialEstimate: RttEstimate(
            smoothedRtt: const Duration(milliseconds: 100),
            rttVariance: const Duration(milliseconds: 25),
          ),
        );
        final h = FailureDetectorTestHarness(rttTracker: rttTracker);

        // timeout = 100 + 4 * 25 = 200ms (minimum bound)
        expect(
          h.detector.effectivePingTimeout,
          equals(const Duration(milliseconds: 200)),
        );
      },
    );

    test(
      'effectivePingTimeout uses initial conservative value before samples',
      () {
        final h = FailureDetectorTestHarness();

        // Before samples, should use initial estimate (1s + 4 * 500ms = 3s)
        expect(
          h.detector.effectivePingTimeout.inMilliseconds,
          greaterThanOrEqualTo(2000),
        );
      },
    );

    test('effectivePingTimeout respects minimum bound of 200ms', () {
      final rttTracker = RttTracker(
        initialEstimate: RttEstimate(
          smoothedRtt: const Duration(milliseconds: 20),
          rttVariance: const Duration(milliseconds: 5),
        ),
      );
      rttTracker.recordSample(const Duration(milliseconds: 20));

      final h = FailureDetectorTestHarness(rttTracker: rttTracker);

      // Raw timeout = 20 + 4 * 5 = 40ms, but min is 200ms
      expect(
        h.detector.effectivePingTimeout,
        equals(const Duration(milliseconds: 200)),
      );
    });

    test('effectivePingTimeout respects maximum bound of 10s', () {
      final rttTracker = RttTracker(
        initialEstimate: RttEstimate(
          smoothedRtt: const Duration(seconds: 5),
          rttVariance: const Duration(seconds: 3),
        ),
      );
      rttTracker.recordSample(const Duration(seconds: 5));

      final h = FailureDetectorTestHarness(rttTracker: rttTracker);

      // Raw timeout = 5000 + 4 * 3000 = 17000ms, but max is 10000ms
      expect(
        h.detector.effectivePingTimeout,
        equals(const Duration(seconds: 10)),
      );
    });

    test('effectiveProbeInterval is 3x effectivePingTimeout', () {
      final rttTracker = RttTracker(
        initialEstimate: RttEstimate(
          smoothedRtt: const Duration(milliseconds: 200),
          rttVariance: const Duration(milliseconds: 50),
        ),
      );
      final h = FailureDetectorTestHarness(rttTracker: rttTracker);

      // pingTimeout = 200 + 4 * 50 = 400ms
      // probeInterval = 3 * 400 = 1200ms
      expect(
        h.detector.effectiveProbeInterval,
        equals(const Duration(milliseconds: 1200)),
      );
    });

    test('effectiveProbeInterval respects minimum bound of 500ms', () {
      final rttTracker = RttTracker(
        initialEstimate: RttEstimate(
          smoothedRtt: const Duration(milliseconds: 20),
          rttVariance: const Duration(milliseconds: 5),
        ),
      );
      rttTracker.recordSample(const Duration(milliseconds: 20));

      final h = FailureDetectorTestHarness(rttTracker: rttTracker);

      // pingTimeout = 200ms (minimum), probeInterval = 3 * 200 = 600ms
      expect(
        h.detector.effectiveProbeInterval.inMilliseconds,
        greaterThanOrEqualTo(500),
      );
    });

    test('effectiveProbeInterval respects maximum bound of 30s', () {
      final rttTracker = RttTracker(
        initialEstimate: RttEstimate(
          smoothedRtt: const Duration(seconds: 8),
          rttVariance: const Duration(seconds: 2),
        ),
      );
      rttTracker.recordSample(const Duration(seconds: 8));

      final h = FailureDetectorTestHarness(rttTracker: rttTracker);

      // pingTimeout = 10s (max), probeInterval = 3 * 10 = 30s (at max)
      expect(
        h.detector.effectiveProbeInterval,
        equals(const Duration(seconds: 30)),
      );
    });

    test('effectivePingTimeoutForPeer uses per-peer RTT when available', () {
      final h = FailureDetectorTestHarness();
      final peer = h.addPeer('peer1');

      // Seed per-peer RTT: 100ms SRTT → timeout = 100 + 4*50 = 300ms
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 100));

      final peerTimeout = h.detector.effectivePingTimeoutForPeer(peer.id);
      expect(peerTimeout.inMilliseconds, lessThan(1000));
      expect(peerTimeout.inMilliseconds, greaterThanOrEqualTo(200));
    });

    test(
      'effectivePingTimeoutForPeer falls back to global when no per-peer estimate',
      () {
        final h = FailureDetectorTestHarness();
        final peer = h.addPeer('peer1');

        final peerTimeout = h.detector.effectivePingTimeoutForPeer(peer.id);
        expect(peerTimeout, equals(h.detector.effectivePingTimeout));
      },
    );

    test(
      'effectivePingTimeoutForPeer falls back to global for unknown peer',
      () {
        final h = FailureDetectorTestHarness();

        final timeout = h.detector.effectivePingTimeoutForPeer(
          NodeId('unknown'),
        );
        expect(timeout, equals(h.detector.effectivePingTimeout));
      },
    );

    test('probe round uses per-peer timeout for known peer with RTT', () async {
      final h = FailureDetectorTestHarness();
      final peer = h.addPeer('peer1');

      // Seed per-peer RTT: 100ms → timeout ~300ms (clamped to min 200ms)
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 100));

      h.startListening();

      final pingFuture = h.expectPing(peer);
      final probeRoundFuture = h.detector.performProbeRound();
      final ping = await pingFuture;

      // Respond within per-peer timeout
      await h.sendAck(
        peer,
        ping.sequence,
        afterDelay: const Duration(milliseconds: 50),
      );
      await probeRoundFuture;

      expect(h.peerRegistry.getPeer(peer.id)!.failedProbeCount, equals(0));

      h.stopListening();
    });

    test('timeout adapts as RTT samples are collected', () async {
      final h = FailureDetectorTestHarness();
      final peer = h.addPeer('peer1');

      h.startListening();

      // Initial timeout (conservative, no samples)
      final initialTimeout = h.detector.effectivePingTimeout;
      expect(initialTimeout.inMilliseconds, greaterThanOrEqualTo(2000));

      // Simulate several fast RTT samples
      for (var i = 0; i < 10; i++) {
        final pingFuture = h.expectPing(peer);
        final probeRoundFuture = h.detector.performProbeRound();
        final ping = await pingFuture;

        await h.sendAck(
          peer,
          ping.sequence,
          afterDelay: const Duration(milliseconds: 100),
        );
        await probeRoundFuture;
      }

      // After samples, timeout should be much lower
      final adaptedTimeout = h.detector.effectivePingTimeout;
      expect(
        adaptedTimeout.inMilliseconds,
        lessThan(initialTimeout.inMilliseconds),
      );
      expect(adaptedTimeout.inMilliseconds, lessThanOrEqualTo(500));

      h.stopListening();
    });
  });
}
