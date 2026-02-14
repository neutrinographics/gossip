import 'package:test/test.dart';
import 'package:gossip/src/domain/services/rtt_tracker.dart';
import 'package:gossip/src/domain/value_objects/rtt_estimate.dart';

void main() {
  group('RttTracker', () {
    group('construction', () {
      test('creates with default initial estimate', () {
        final tracker = RttTracker();

        expect(
          tracker.estimate.smoothedRtt,
          equals(const Duration(milliseconds: 500)),
        );
        expect(
          tracker.estimate.rttVariance,
          equals(const Duration(milliseconds: 250)),
        );
      });

      test('creates with custom initial estimate', () {
        final tracker = RttTracker(
          initialEstimate: RttEstimate(
            smoothedRtt: const Duration(milliseconds: 200),
            rttVariance: const Duration(milliseconds: 50),
          ),
        );

        expect(
          tracker.estimate.smoothedRtt,
          equals(const Duration(milliseconds: 200)),
        );
        expect(
          tracker.estimate.rttVariance,
          equals(const Duration(milliseconds: 50)),
        );
      });
    });

    group('recordSample', () {
      test('first sample initializes estimate directly', () {
        final tracker = RttTracker();

        tracker.recordSample(const Duration(milliseconds: 200));

        expect(
          tracker.estimate.smoothedRtt,
          equals(const Duration(milliseconds: 200)),
        );
      });

      test('subsequent samples apply EWMA smoothing', () {
        final tracker = RttTracker(
          initialEstimate: RttEstimate(
            smoothedRtt: const Duration(milliseconds: 200),
            rttVariance: const Duration(milliseconds: 50),
          ),
        );
        // Mark as having received first sample
        tracker.recordSample(const Duration(milliseconds: 200));

        // Now record a different sample
        tracker.recordSample(const Duration(milliseconds: 300));

        // Should be smoothed, not jump directly to 300
        expect(tracker.estimate.smoothedRtt.inMilliseconds, lessThan(300));
        expect(tracker.estimate.smoothedRtt.inMilliseconds, greaterThan(200));
      });

      test('clamps samples to minimum bound', () {
        final tracker = RttTracker();

        // Very small RTT should be clamped to minimum (50ms)
        tracker.recordSample(const Duration(milliseconds: 10));

        expect(
          tracker.estimate.smoothedRtt.inMilliseconds,
          greaterThanOrEqualTo(50),
        );
      });

      test('clamps samples to maximum bound', () {
        final tracker = RttTracker();

        // Very large RTT should be clamped to maximum (30s)
        tracker.recordSample(const Duration(seconds: 60));

        expect(
          tracker.estimate.smoothedRtt.inMilliseconds,
          lessThanOrEqualTo(30000),
        );
      });

      test('ignores negative samples', () {
        final tracker = RttTracker();
        final initialEstimate = tracker.estimate;

        // Negative sample should be ignored
        tracker.recordSample(const Duration(milliseconds: -100));

        expect(tracker.estimate, equals(initialEstimate));
      });

      test('tracks sample count', () {
        final tracker = RttTracker();

        expect(tracker.sampleCount, equals(0));

        tracker.recordSample(const Duration(milliseconds: 100));
        expect(tracker.sampleCount, equals(1));

        tracker.recordSample(const Duration(milliseconds: 150));
        expect(tracker.sampleCount, equals(2));
      });
    });

    group('suggestedTimeout', () {
      test('delegates to estimate', () {
        final tracker = RttTracker(
          initialEstimate: RttEstimate(
            smoothedRtt: const Duration(milliseconds: 300),
            rttVariance: const Duration(milliseconds: 75),
          ),
        );

        // timeout = 300 + 4 * 75 = 600ms
        expect(
          tracker.suggestedTimeout(),
          equals(const Duration(milliseconds: 600)),
        );
      });

      test('respects custom bounds', () {
        final tracker = RttTracker(
          initialEstimate: RttEstimate(
            smoothedRtt: const Duration(milliseconds: 50),
            rttVariance: const Duration(milliseconds: 10),
          ),
        );

        final timeout = tracker.suggestedTimeout(
          minTimeout: const Duration(milliseconds: 100),
        );

        expect(timeout, equals(const Duration(milliseconds: 100)));
      });
    });

    group('smoothedRtt', () {
      test('returns current smoothed RTT', () {
        final tracker = RttTracker(
          initialEstimate: RttEstimate(
            smoothedRtt: const Duration(milliseconds: 250),
            rttVariance: const Duration(milliseconds: 50),
          ),
        );

        expect(tracker.smoothedRtt, equals(const Duration(milliseconds: 250)));
      });
    });

    group('rttVariance', () {
      test('returns current RTT variance', () {
        final tracker = RttTracker(
          initialEstimate: RttEstimate(
            smoothedRtt: const Duration(milliseconds: 250),
            rttVariance: const Duration(milliseconds: 75),
          ),
        );

        expect(tracker.rttVariance, equals(const Duration(milliseconds: 75)));
      });
    });

    group('hasReceivedSamples', () {
      test('returns false initially', () {
        final tracker = RttTracker();

        expect(tracker.hasReceivedSamples, isFalse);
      });

      test('returns true after recording a sample', () {
        final tracker = RttTracker();

        tracker.recordSample(const Duration(milliseconds: 100));

        expect(tracker.hasReceivedSamples, isTrue);
      });
    });

    group('reset', () {
      test('resets to initial estimate', () {
        final tracker = RttTracker();

        tracker.recordSample(const Duration(milliseconds: 100));
        tracker.recordSample(const Duration(milliseconds: 150));

        tracker.reset();

        expect(
          tracker.estimate.smoothedRtt,
          equals(const Duration(milliseconds: 500)),
        );
        expect(tracker.sampleCount, equals(0));
        expect(tracker.hasReceivedSamples, isFalse);
      });

      test('resets to custom initial estimate', () {
        final initialEstimate = RttEstimate(
          smoothedRtt: const Duration(milliseconds: 500),
          rttVariance: const Duration(milliseconds: 100),
        );
        final tracker = RttTracker(initialEstimate: initialEstimate);

        tracker.recordSample(const Duration(milliseconds: 100));
        tracker.reset();

        expect(
          tracker.estimate.smoothedRtt,
          equals(const Duration(milliseconds: 500)),
        );
      });
    });

    group('convergence', () {
      test('converges to stable RTT over many samples', () {
        final tracker = RttTracker();

        // Simulate stable 150ms RTT with small jitter
        for (var i = 0; i < 50; i++) {
          final jitter = (i % 3 - 1) * 10; // -10, 0, or +10ms
          tracker.recordSample(Duration(milliseconds: 150 + jitter));
        }

        // Should converge close to 150ms
        expect(tracker.smoothedRtt.inMilliseconds, closeTo(150, 20));
        // Variance should be low due to consistent samples
        expect(tracker.rttVariance.inMilliseconds, lessThan(50));
      });

      test('adapts to changing network conditions', () {
        final tracker = RttTracker();

        // Start with low latency
        for (var i = 0; i < 20; i++) {
          tracker.recordSample(const Duration(milliseconds: 100));
        }
        expect(tracker.smoothedRtt.inMilliseconds, closeTo(100, 20));

        // Switch to high latency
        for (var i = 0; i < 50; i++) {
          tracker.recordSample(const Duration(milliseconds: 500));
        }

        // Should adapt to new latency
        expect(tracker.smoothedRtt.inMilliseconds, closeTo(500, 50));
      });
    });
  });
}
