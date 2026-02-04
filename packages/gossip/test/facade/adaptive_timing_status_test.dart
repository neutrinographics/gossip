import 'package:gossip/src/facade/adaptive_timing_status.dart';
import 'package:test/test.dart';

void main() {
  group('AdaptiveTimingStatus', () {
    test('stores all fields correctly', () {
      final status = AdaptiveTimingStatus(
        smoothedRtt: const Duration(milliseconds: 300),
        rttVariance: const Duration(milliseconds: 50),
        rttSampleCount: 42,
        hasRttSamples: true,
        effectiveGossipInterval: const Duration(milliseconds: 600),
        effectivePingTimeout: const Duration(milliseconds: 500),
        effectiveProbeInterval: const Duration(milliseconds: 1500),
        totalPendingSendCount: 3,
      );

      expect(status.smoothedRtt, equals(const Duration(milliseconds: 300)));
      expect(status.rttVariance, equals(const Duration(milliseconds: 50)));
      expect(status.rttSampleCount, equals(42));
      expect(status.hasRttSamples, isTrue);
      expect(
        status.effectiveGossipInterval,
        equals(const Duration(milliseconds: 600)),
      );
      expect(
        status.effectivePingTimeout,
        equals(const Duration(milliseconds: 500)),
      );
      expect(
        status.effectiveProbeInterval,
        equals(const Duration(milliseconds: 1500)),
      );
      expect(status.totalPendingSendCount, equals(3));
    });

    test('supports const construction', () {
      const status = AdaptiveTimingStatus(
        smoothedRtt: Duration(seconds: 1),
        rttVariance: Duration(milliseconds: 500),
        rttSampleCount: 0,
        hasRttSamples: false,
        effectiveGossipInterval: Duration(seconds: 2),
        effectivePingTimeout: Duration(seconds: 3),
        effectiveProbeInterval: Duration(seconds: 9),
        totalPendingSendCount: 0,
      );

      expect(status.rttSampleCount, equals(0));
      expect(status.hasRttSamples, isFalse);
    });
  });
}
