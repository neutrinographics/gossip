import 'package:gossip/src/membership/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/membership/domain/services/probe_timing_policy.dart';
import 'package:gossip/src/shared/domain/services/rtt_tracker.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/rtt_estimate.dart';
import 'package:test/test.dart';

/// Transplanted from failure_detector_adaptive_timeout_test.dart and
/// failure_detector_pacing_test.dart (CC5-13 detector slice): these pin
/// the same formulas/semantics the detector relied on before the
/// extraction, now against [ProbeTimingPolicy] directly.
void main() {
  late NodeId localNode;
  late PeerRegistry peerRegistry;

  setUp(() {
    localNode = NodeId('local');
    peerRegistry = PeerRegistry(localNode: localNode);
  });

  group('ProbeTimingPolicy adaptive ping timeout', () {
    test('delegates to rttTracker.suggestedTimeout(min:, max:)', () {
      final rttTracker = RttTracker(
        initialEstimate: RttEstimate(
          smoothedRtt: const Duration(milliseconds: 300),
          rttVariance: const Duration(milliseconds: 75),
        ),
      );
      final policy = ProbeTimingPolicy(
        peerRegistry: peerRegistry,
        rttTracker: rttTracker,
      );

      // 300 + 4*75 = 600ms
      expect(
        policy.effectivePingTimeout,
        equals(const Duration(milliseconds: 600)),
      );
    });

    test('respects the 500ms floor', () {
      final rttTracker = RttTracker(
        initialEstimate: RttEstimate(
          smoothedRtt: const Duration(milliseconds: 20),
          rttVariance: const Duration(milliseconds: 5),
        ),
      );
      final policy = ProbeTimingPolicy(
        peerRegistry: peerRegistry,
        rttTracker: rttTracker,
      );

      // Raw = 20 + 4*5 = 40ms, floored to 500ms.
      expect(
        policy.effectivePingTimeout,
        equals(const Duration(milliseconds: 500)),
      );
    });

    test('respects the 10s ceiling', () {
      final rttTracker = RttTracker(
        initialEstimate: RttEstimate(
          smoothedRtt: const Duration(seconds: 5),
          rttVariance: const Duration(seconds: 3),
        ),
      );
      final policy = ProbeTimingPolicy(
        peerRegistry: peerRegistry,
        rttTracker: rttTracker,
      );

      // Raw = 5000 + 4*3000 = 17000ms, capped to 10s.
      expect(policy.effectivePingTimeout, equals(const Duration(seconds: 10)));
    });
  });

  group('ProbeTimingPolicy per-peer ping timeout', () {
    test('prefers the per-peer RTT estimate over the global one', () {
      final policy = ProbeTimingPolicy(
        peerRegistry: peerRegistry,
        rttTracker: RttTracker(), // global stays at the 1500ms cold-start
      );
      final peerId = NodeId('peer1');
      peerRegistry.addPeer(peerId, occurredAt: DateTime.now());
      peerRegistry.recordPeerRtt(peerId, const Duration(milliseconds: 100));

      // Per-peer first sample: SRTT=100ms, RTTVAR=50ms -> raw 300ms,
      // floored to 500ms -- still well under the 1500ms global fallback,
      // proving the per-peer estimate (not the global one) gated this.
      expect(
        policy.effectivePingTimeoutForPeer(peerId),
        equals(const Duration(milliseconds: 500)),
      );
      expect(
        policy.effectivePingTimeoutForPeer(peerId),
        lessThan(policy.effectivePingTimeout),
      );
    });

    test('falls back to the global estimate for an unknown peer', () {
      final rttTracker = RttTracker(
        initialEstimate: RttEstimate(
          smoothedRtt: const Duration(milliseconds: 300),
          rttVariance: const Duration(milliseconds: 75),
        ),
      );
      final policy = ProbeTimingPolicy(
        peerRegistry: peerRegistry,
        rttTracker: rttTracker,
      );

      expect(
        policy.effectivePingTimeoutForPeer(NodeId('ghost')),
        equals(policy.effectivePingTimeout),
      );
    });
  });

  group('ProbeTimingPolicy static override (ADR-013 regression)', () {
    test('a static probeInterval must NOT pin the ping timeout', () {
      final rttTracker = RttTracker(
        initialEstimate: RttEstimate(
          smoothedRtt: const Duration(milliseconds: 300),
          rttVariance: const Duration(milliseconds: 75),
        ),
      );
      final policy = ProbeTimingPolicy(
        peerRegistry: peerRegistry,
        rttTracker: rttTracker,
        staticProbeInterval: const Duration(seconds: 3),
      );

      // Ping timeout stays adaptive (600ms) — must not snap to whatever
      // fallback a naive "any static knob means static everything"
      // implementation would use.
      expect(
        policy.effectivePingTimeout,
        equals(const Duration(milliseconds: 600)),
        reason: 'setting probeInterval must not pin ping timeout',
      );
    });

    test('a static pingTimeout must NOT pin the probe interval', () {
      final policy = ProbeTimingPolicy(
        peerRegistry: peerRegistry,
        rttTracker: RttTracker(),
        staticPingTimeout: const Duration(milliseconds: 800),
      );

      // Probe interval stays adaptive: 3 * 800ms = 2400ms.
      expect(
        policy.effectiveProbeInterval,
        equals(const Duration(milliseconds: 2400)),
        reason: 'setting pingTimeout must not pin probe interval',
      );
    });

    test('both knobs static take effect independently', () {
      final policy = ProbeTimingPolicy(
        peerRegistry: peerRegistry,
        rttTracker: RttTracker(),
        staticPingTimeout: const Duration(milliseconds: 700),
        staticProbeInterval: const Duration(seconds: 4),
      );

      expect(
        policy.effectivePingTimeout,
        equals(const Duration(milliseconds: 700)),
      );
      expect(policy.effectiveProbeInterval, equals(const Duration(seconds: 4)));
    });
  });

  group('ProbeTimingPolicy interval formula + pacer', () {
    test('is clamp(3x effective ping timeout) when the pacer is fresh', () {
      final rttTracker = RttTracker(
        initialEstimate: RttEstimate(
          smoothedRtt: const Duration(milliseconds: 300),
          rttVariance: const Duration(milliseconds: 75),
        ),
      );
      final policy = ProbeTimingPolicy(
        peerRegistry: peerRegistry,
        rttTracker: rttTracker,
      );

      // pingTimeout = 600ms, interval = 3 * 600 = 1800ms.
      expect(
        policy.effectiveProbeInterval,
        equals(const Duration(milliseconds: 1800)),
      );
    });

    test('respects the 500ms floor', () {
      final rttTracker = RttTracker(
        initialEstimate: RttEstimate(
          smoothedRtt: const Duration(milliseconds: 20),
          rttVariance: const Duration(milliseconds: 5),
        ),
      );
      rttTracker.recordSample(const Duration(milliseconds: 20));
      final policy = ProbeTimingPolicy(
        peerRegistry: peerRegistry,
        rttTracker: rttTracker,
      );

      expect(
        policy.effectiveProbeInterval.inMilliseconds,
        greaterThanOrEqualTo(500),
      );
    });

    test('respects the 30s ceiling', () {
      final rttTracker = RttTracker(
        initialEstimate: RttEstimate(
          smoothedRtt: const Duration(seconds: 8),
          rttVariance: const Duration(seconds: 2),
        ),
      );
      rttTracker.recordSample(const Duration(seconds: 8));
      final policy = ProbeTimingPolicy(
        peerRegistry: peerRegistry,
        rttTracker: rttTracker,
      );

      // pingTimeout = 10s (capped), 3*10s = 30s (exactly the ceiling).
      expect(
        policy.effectiveProbeInterval,
        equals(const Duration(seconds: 30)),
      );
    });

    test('quietRound() stretches the interval; news() snaps it back', () {
      final rttTracker = RttTracker(
        initialEstimate: RttEstimate(
          smoothedRtt: const Duration(milliseconds: 300),
          rttVariance: const Duration(milliseconds: 75),
        ),
      );
      final policy = ProbeTimingPolicy(
        peerRegistry: peerRegistry,
        rttTracker: rttTracker,
      );
      final base = policy.effectiveProbeInterval;

      policy.quietRound();
      expect(policy.effectiveProbeInterval, greaterThan(base));

      policy.news();
      expect(policy.effectiveProbeInterval, equals(base));
    });

    test('a static probeInterval bypasses the pacer entirely', () {
      final policy = ProbeTimingPolicy(
        peerRegistry: peerRegistry,
        rttTracker: RttTracker(),
        staticProbeInterval: const Duration(seconds: 2),
      );

      policy.quietRound();
      policy.quietRound();
      policy.quietRound();

      expect(policy.effectiveProbeInterval, equals(const Duration(seconds: 2)));
    });
  });
}
