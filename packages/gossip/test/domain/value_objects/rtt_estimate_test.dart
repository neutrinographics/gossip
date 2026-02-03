import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/rtt_estimate.dart';

void main() {
  group('RttEstimate', () {
    group('construction', () {
      test('creates with default initial values', () {
        final estimate = RttEstimate.initial();

        expect(estimate.smoothedRtt, equals(const Duration(seconds: 1)));
        expect(estimate.rttVariance, equals(const Duration(milliseconds: 500)));
      });

      test('creates with custom initial values', () {
        final estimate = RttEstimate(
          smoothedRtt: const Duration(milliseconds: 200),
          rttVariance: const Duration(milliseconds: 50),
        );

        expect(estimate.smoothedRtt, equals(const Duration(milliseconds: 200)));
        expect(estimate.rttVariance, equals(const Duration(milliseconds: 50)));
      });

      test('throws ArgumentError when smoothedRtt is negative', () {
        expect(
          () => RttEstimate(
            smoothedRtt: const Duration(milliseconds: -1),
            rttVariance: const Duration(milliseconds: 50),
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('throws ArgumentError when rttVariance is negative', () {
        expect(
          () => RttEstimate(
            smoothedRtt: const Duration(milliseconds: 100),
            rttVariance: const Duration(milliseconds: -1),
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('accepts zero for smoothedRtt', () {
        final estimate = RttEstimate(
          smoothedRtt: Duration.zero,
          rttVariance: const Duration(milliseconds: 50),
        );
        expect(estimate.smoothedRtt, equals(Duration.zero));
      });

      test('accepts zero for rttVariance', () {
        final estimate = RttEstimate(
          smoothedRtt: const Duration(milliseconds: 100),
          rttVariance: Duration.zero,
        );
        expect(estimate.rttVariance, equals(Duration.zero));
      });
    });

    group('update', () {
      test(
        'first sample sets smoothedRtt directly when isFirstSample is true',
        () {
          final estimate = RttEstimate.initial();
          final updated = estimate.update(
            const Duration(milliseconds: 200),
            isFirstSample: true,
          );

          expect(
            updated.smoothedRtt,
            equals(const Duration(milliseconds: 200)),
          );
        },
      );

      test('applies EWMA smoothing on subsequent samples', () {
        // Start with smoothedRtt=200ms, variance=50ms
        final estimate = RttEstimate(
          smoothedRtt: const Duration(milliseconds: 200),
          rttVariance: const Duration(milliseconds: 50),
        );

        // New sample of 300ms
        final updated = estimate.update(const Duration(milliseconds: 300));

        // EWMA: newRtt = alpha * sample + (1 - alpha) * oldRtt
        // With alpha=0.125: newRtt = 0.125 * 300 + 0.875 * 200 = 37.5 + 175 = 212.5
        expect(
          updated.smoothedRtt.inMilliseconds,
          closeTo(212, 1), // Allow small rounding difference
        );
      });

      test('updates variance using RFC 6298 formula', () {
        final estimate = RttEstimate(
          smoothedRtt: const Duration(milliseconds: 200),
          rttVariance: const Duration(milliseconds: 50),
        );

        // Sample = 300ms, deviation = |300 - 200| = 100ms
        final updated = estimate.update(const Duration(milliseconds: 300));

        // Variance update: newVar = (1-beta)*oldVar + beta*|sample - smoothedRtt|
        // With beta=0.25: newVar = 0.75 * 50 + 0.25 * 100 = 37.5 + 25 = 62.5
        expect(updated.rttVariance.inMilliseconds, closeTo(62, 1));
      });

      test('variance decreases when samples are consistent', () {
        var estimate = RttEstimate(
          smoothedRtt: const Duration(milliseconds: 200),
          rttVariance: const Duration(milliseconds: 100),
        );

        // Apply several samples close to the smoothed RTT
        for (var i = 0; i < 10; i++) {
          estimate = estimate.update(const Duration(milliseconds: 200));
        }

        // Variance should decrease toward zero
        expect(estimate.rttVariance.inMilliseconds, lessThan(50));
      });

      test('smoothedRtt converges to sample value over time', () {
        var estimate = RttEstimate(
          smoothedRtt: const Duration(milliseconds: 1000),
          rttVariance: const Duration(milliseconds: 200),
        );

        // Apply many samples of 200ms
        for (var i = 0; i < 50; i++) {
          estimate = estimate.update(const Duration(milliseconds: 200));
        }

        // Should converge close to 200ms
        expect(estimate.smoothedRtt.inMilliseconds, closeTo(200, 10));
      });
    });

    group('suggestedTimeout', () {
      test('returns smoothedRtt plus 4x variance', () {
        final estimate = RttEstimate(
          smoothedRtt: const Duration(milliseconds: 200),
          rttVariance: const Duration(milliseconds: 50),
        );

        // timeout = 200 + 4 * 50 = 400ms
        expect(
          estimate.suggestedTimeout(),
          equals(const Duration(milliseconds: 400)),
        );
      });

      test('returns at least minTimeout', () {
        final estimate = RttEstimate(
          smoothedRtt: const Duration(milliseconds: 50),
          rttVariance: const Duration(milliseconds: 10),
        );

        // Raw timeout = 50 + 4 * 10 = 90ms, but min is 200ms
        expect(
          estimate.suggestedTimeout(),
          equals(const Duration(milliseconds: 200)),
        );
      });

      test('returns at most maxTimeout', () {
        final estimate = RttEstimate(
          smoothedRtt: const Duration(seconds: 10),
          rttVariance: const Duration(seconds: 5),
        );

        // Raw timeout = 10000 + 4 * 5000 = 30000ms, but max is 10000ms
        expect(
          estimate.suggestedTimeout(),
          equals(const Duration(seconds: 10)),
        );
      });

      test('respects custom min and max bounds', () {
        final estimate = RttEstimate(
          smoothedRtt: const Duration(milliseconds: 50),
          rttVariance: const Duration(milliseconds: 10),
        );

        final timeout = estimate.suggestedTimeout(
          minTimeout: const Duration(milliseconds: 100),
          maxTimeout: const Duration(milliseconds: 500),
        );

        expect(timeout, equals(const Duration(milliseconds: 100)));
      });
    });

    group('equality', () {
      test('two RttEstimates with same values are equal', () {
        final a = RttEstimate(
          smoothedRtt: const Duration(milliseconds: 200),
          rttVariance: const Duration(milliseconds: 50),
        );
        final b = RttEstimate(
          smoothedRtt: const Duration(milliseconds: 200),
          rttVariance: const Duration(milliseconds: 50),
        );

        expect(a, equals(b));
      });

      test('two RttEstimates with different smoothedRtt are not equal', () {
        final a = RttEstimate(
          smoothedRtt: const Duration(milliseconds: 200),
          rttVariance: const Duration(milliseconds: 50),
        );
        final b = RttEstimate(
          smoothedRtt: const Duration(milliseconds: 300),
          rttVariance: const Duration(milliseconds: 50),
        );

        expect(a, isNot(equals(b)));
      });

      test('two RttEstimates with different variance are not equal', () {
        final a = RttEstimate(
          smoothedRtt: const Duration(milliseconds: 200),
          rttVariance: const Duration(milliseconds: 50),
        );
        final b = RttEstimate(
          smoothedRtt: const Duration(milliseconds: 200),
          rttVariance: const Duration(milliseconds: 100),
        );

        expect(a, isNot(equals(b)));
      });

      test('hashCode is consistent with equality', () {
        final a = RttEstimate(
          smoothedRtt: const Duration(milliseconds: 200),
          rttVariance: const Duration(milliseconds: 50),
        );
        final b = RttEstimate(
          smoothedRtt: const Duration(milliseconds: 200),
          rttVariance: const Duration(milliseconds: 50),
        );

        expect(a.hashCode, equals(b.hashCode));
      });
    });

    group('toString', () {
      test('returns human-readable representation', () {
        final estimate = RttEstimate(
          smoothedRtt: const Duration(milliseconds: 200),
          rttVariance: const Duration(milliseconds: 50),
        );

        expect(estimate.toString(), contains('200'));
        expect(estimate.toString(), contains('50'));
      });
    });
  });
}
