import 'dart:math';

import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:test/test.dart';

import 'failure_detector_test_harness.dart';

/// H3: the main probe selection must round-robin over a shuffled order so
/// every probable peer is probed once per cycle. Pure-random selection
/// gives geometric coverage (E[rounds to probe a specific dead peer] =
/// n-1, with a heavy tail), which makes SWIM detection latency scale
/// O(n · threshold) — minutes at n=8. Round-robin bounds it to ~(n-1)
/// rounds per peer.
void main() {
  group('FailureDetector probe selection (H3)', () {
    test('round-robins: every block of n selections covers all probable '
        'peers exactly once', () {
      // Seeded so the pre-fix random selection is deterministically a
      // non-permutation (red), while round-robin is a permutation for
      // any seed (green).
      final h = FailureDetectorTestHarness(random: Random(1234));
      const n = 5;
      final ids = {for (var i = 0; i < n; i++) h.addPeer('peer$i').id};

      for (var cycle = 0; cycle < 4; cycle++) {
        final block = [
          for (var i = 0; i < n; i++) h.detector.selectRandomPeer()!.id,
        ];
        expect(
          block.toSet(),
          equals(ids),
          reason: 'cycle $cycle must cover every probable peer exactly once',
        );
      }
    });

    test('a specific peer is always selected within n rounds (bounded '
        'worst-case coverage)', () {
      final h = FailureDetectorTestHarness(random: Random(7));
      const n = 6;
      final ids = [for (var i = 0; i < n; i++) h.addPeer('peer$i').id];
      final target = ids[3];

      // Over any window of n consecutive selections, the target appears.
      for (var start = 0; start < 3; start++) {
        final window = <NodeId>[];
        for (var i = 0; i < n; i++) {
          window.add(h.detector.selectRandomPeer()!.id);
        }
        expect(
          window,
          contains(target),
          reason: 'window $start must include the target within n rounds',
        );
      }
    });

    test('a peer under a probing hold is never selected', () {
      final h = FailureDetectorTestHarness(random: Random(99));
      final ids = [for (var i = 0; i < 4; i++) h.addPeer('peer$i').id];
      h.detector.setProbingHold(ids[2], h.timePort.nowMs + 100000);

      final selected = <NodeId>[];
      for (var i = 0; i < 12; i++) {
        final peer = h.detector.selectRandomPeer();
        if (peer != null) selected.add(peer.id);
      }

      expect(selected, isNot(contains(ids[2])));
      expect(selected.toSet(), equals({ids[0], ids[1], ids[3]}));
    });

    test('returns null when there are no probable peers', () {
      final h = FailureDetectorTestHarness();
      expect(h.detector.selectRandomPeer(), isNull);
    });
  });
}
