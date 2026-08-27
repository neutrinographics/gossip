import 'dart:math';

import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/sync/domain/interfaces/peer_directory.dart';
import 'package:gossip/src/sync/domain/services/gossip_timing_policy.dart';
import 'package:gossip/src/sync/domain/value_objects/sync_partner.dart';
import 'package:test/test.dart';

/// Transplanted from gossip_engine_interval_pacing_test.dart and
/// gossip_engine_pacing_test.dart (CC5-13 engine slice): these pin the
/// same formulas/semantics `GossipEngine` relied on before the extraction,
/// now against [GossipTimingPolicy] directly.
void main() {
  group('GossipTimingPolicy static override', () {
    test('a static interval wins over adaptive enabled', () {
      final directory = _FakePeerDirectory([
        _partner('fast', const Duration(milliseconds: 100)),
      ]);
      final policy = GossipTimingPolicy(
        peerDirectory: directory,
        staticInterval: const Duration(seconds: 2),
        adaptiveEnabled: true,
      );

      // Adaptive would compute 100ms*2=200ms (clamped to 100ms floor) --
      // the static value must win regardless.
      expect(policy.effectiveInterval, equals(const Duration(seconds: 2)));
    });

    test('adaptive disabled with no static interval defaults to 500ms', () {
      final policy = GossipTimingPolicy(
        peerDirectory: _FakePeerDirectory(const []),
        adaptiveEnabled: false,
      );

      expect(
        policy.effectiveInterval,
        equals(const Duration(milliseconds: 500)),
      );
    });
  });

  group('GossipTimingPolicy adaptive formula', () {
    test('median SRTT x2 clamped to the 100ms floor', () {
      final policy = GossipTimingPolicy(
        peerDirectory: _FakePeerDirectory([
          _partner('p1', const Duration(milliseconds: 10)),
        ]),
        adaptiveEnabled: true,
      );

      // Raw = 10ms * 2 = 20ms, floored to 100ms.
      expect(
        policy.effectiveInterval,
        equals(const Duration(milliseconds: 100)),
      );
    });

    test('median SRTT x2 clamped to the 5s ceiling', () {
      final policy = GossipTimingPolicy(
        peerDirectory: _FakePeerDirectory([
          _partner('p1', const Duration(seconds: 10)),
        ]),
        adaptiveEnabled: true,
      );

      // Raw = 10s * 2 = 20s, capped to 5s.
      expect(policy.effectiveInterval, equals(const Duration(seconds: 5)));
    });

    test('no peer has an RTT estimate falls back to the 1000ms conservative '
        'default', () {
      final policy = GossipTimingPolicy(
        peerDirectory: _FakePeerDirectory([
          _partner('p1', null),
          _partner('p2', null),
        ]),
        adaptiveEnabled: true,
      );

      expect(
        policy.effectiveInterval,
        equals(const Duration(milliseconds: 1000)),
      );
    });

    test('empty reachable partners falls back to the 1000ms default', () {
      final policy = GossipTimingPolicy(
        peerDirectory: _FakePeerDirectory(const []),
        adaptiveEnabled: true,
      );

      expect(
        policy.effectiveInterval,
        equals(const Duration(milliseconds: 1000)),
      );
    });

    test('paces off the median peer SRTT, not the global minimum', () {
      final policy = GossipTimingPolicy(
        peerDirectory: _FakePeerDirectory([
          _partner('fast', const Duration(milliseconds: 100)),
          _partner('mid', const Duration(seconds: 1)),
          _partner('slow', const Duration(seconds: 2)),
        ]),
        adaptiveEnabled: true,
      );

      // median SRTT = 1s; interval = 1s * 2 = 2s. The old min-based pacing
      // would give 100ms * 2 = 200ms.
      expect(policy.effectiveInterval, equals(const Duration(seconds: 2)));
    });

    test('a single fast peer does not pin the loop to a fast cadence', () {
      final policy = GossipTimingPolicy(
        peerDirectory: _FakePeerDirectory([
          _partner('fast', const Duration(milliseconds: 100)),
          _partner('slow1', const Duration(seconds: 2)),
          _partner('slow2', const Duration(seconds: 2)),
        ]),
        adaptiveEnabled: true,
      );

      // Median is a slow peer (2s) -> interval = 2s * 2 = 4s, not the
      // 200ms the fast peer would have pinned it to under min-based pacing.
      expect(policy.effectiveInterval, equals(const Duration(seconds: 4)));
    });

    test('a single very slow outlier does not stall the whole mesh', () {
      final policy = GossipTimingPolicy(
        peerDirectory: _FakePeerDirectory([
          _partner('fast', const Duration(milliseconds: 100)),
          _partner('mid', const Duration(milliseconds: 200)),
          _partner('outlier', const Duration(seconds: 30)),
        ]),
        adaptiveEnabled: true,
      );

      // Median SRTT = 200ms -> interval = 200ms * 2 = 400ms. A max- or
      // mean-based implementation would instead be dragged toward the 30s
      // outlier and hit the 5s ceiling; the median formula is robust to an
      // outlier at either end, not just the fast one (the other two tests
      // in this group).
      expect(
        policy.effectiveInterval,
        equals(const Duration(milliseconds: 400)),
      );
    });
  });

  group('GossipTimingPolicy quiescence pacing', () {
    test('quietRound() stretches the interval; news() snaps it back', () {
      final policy = GossipTimingPolicy(
        peerDirectory: _FakePeerDirectory([
          _partner('p1', const Duration(milliseconds: 500)),
        ]),
        adaptiveEnabled: true,
      );
      final base = policy.effectiveInterval;

      policy.quietRound();
      expect(policy.effectiveInterval, greaterThan(base));

      policy.news();
      expect(policy.effectiveInterval, equals(base));
    });

    test('the paced interval clamps at the 30s ceiling', () {
      final policy = GossipTimingPolicy(
        peerDirectory: _FakePeerDirectory([
          _partner('p1', const Duration(seconds: 2)),
        ]),
        adaptiveEnabled: true,
      );

      for (var i = 0; i < 30; i++) {
        policy.quietRound();
      }

      expect(policy.effectiveInterval, equals(const Duration(seconds: 30)));
    });

    test('a static interval bypasses the pacer entirely', () {
      final policy = GossipTimingPolicy(
        peerDirectory: _FakePeerDirectory(const []),
        staticInterval: const Duration(seconds: 2),
        adaptiveEnabled: false,
      );

      policy.quietRound();
      policy.quietRound();
      policy.quietRound();

      expect(policy.effectiveInterval, equals(const Duration(seconds: 2)));
    });
  });
}

SyncPartner _partner(String id, Duration? smoothedRtt) {
  return SyncPartner(nodeId: NodeId(id), smoothedRtt: smoothedRtt);
}

/// Minimal [PeerDirectory] fake exposing only what [GossipTimingPolicy]
/// reads ([reachablePartners]) — a pure domain-layer double, deliberately
/// not routed through membership's `PeerRegistry`/`MembershipPeerDirectory`
/// so this stays a dependency-free unit test of the policy's own formulas.
class _FakePeerDirectory implements PeerDirectory {
  _FakePeerDirectory(this._partners);

  final List<SyncPartner> _partners;

  @override
  List<SyncPartner> reachablePartners() => _partners;

  @override
  SyncPartner? selectRandomPartner(Random random) =>
      _partners.isEmpty ? null : _partners.first;

  @override
  void recordContact(NodeId peer, int nowMs) {}

  @override
  void recordMessageReceived(NodeId peer, int bytes, int nowMs, int windowMs) {}

  @override
  void recordMessageSent(NodeId peer, int bytes) {}

  @override
  void recordAntiEntropy(NodeId peer, int nowMs) {}
}
