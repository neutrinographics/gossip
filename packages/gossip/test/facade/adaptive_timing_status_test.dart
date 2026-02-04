import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/rtt_estimate.dart';
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

    test('perPeerRtt defaults to empty map', () {
      final status = AdaptiveTimingStatus(
        smoothedRtt: const Duration(seconds: 1),
        rttVariance: const Duration(milliseconds: 500),
        rttSampleCount: 0,
        hasRttSamples: false,
        effectiveGossipInterval: const Duration(seconds: 2),
        effectivePingTimeout: const Duration(seconds: 3),
        effectiveProbeInterval: const Duration(seconds: 9),
        totalPendingSendCount: 0,
      );

      expect(status.perPeerRtt, isEmpty);
    });

    test('perPeerRtt stores per-peer RTT estimates', () {
      final fastPeer = NodeId('fast');
      final slowPeer = NodeId('slow');
      final fastRtt = RttEstimate(
        smoothedRtt: const Duration(milliseconds: 100),
        rttVariance: const Duration(milliseconds: 25),
      );
      final slowRtt = RttEstimate(
        smoothedRtt: const Duration(milliseconds: 3000),
        rttVariance: const Duration(milliseconds: 500),
      );

      final status = AdaptiveTimingStatus(
        smoothedRtt: const Duration(milliseconds: 100),
        rttVariance: const Duration(milliseconds: 25),
        rttSampleCount: 10,
        hasRttSamples: true,
        effectiveGossipInterval: const Duration(milliseconds: 200),
        effectivePingTimeout: const Duration(milliseconds: 200),
        effectiveProbeInterval: const Duration(milliseconds: 600),
        totalPendingSendCount: 0,
        perPeerRtt: {fastPeer: fastRtt, slowPeer: slowRtt},
      );

      expect(status.perPeerRtt, hasLength(2));
      expect(status.perPeerRtt[fastPeer], equals(fastRtt));
      expect(status.perPeerRtt[slowPeer], equals(slowRtt));
    });
  });
}
