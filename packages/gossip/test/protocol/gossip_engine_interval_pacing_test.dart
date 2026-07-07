import 'package:test/test.dart';

import 'gossip_engine_test_harness.dart';

/// M4: the gossip round interval must not be paced off the single fastest
/// peer's SRTT. Using the min let one fast peer pin the whole loop to a fast
/// cadence, over-driving slower links (each uniform-random round is ~(n-1)/n
/// likely to target a slower peer carrying a potentially large payload).
void main() {
  group('GossipEngine interval pacing (M4)', () {
    test(
      'paces off the median peer SRTT, not the global minimum',
      () {
        final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
        final fast = h.addPeer('fast');
        final mid = h.addPeer('mid');
        final slow = h.addPeer('slow');
        h.peerRegistry.recordPeerRtt(fast.id, const Duration(milliseconds: 100));
        h.peerRegistry.recordPeerRtt(mid.id, const Duration(seconds: 1));
        h.peerRegistry.recordPeerRtt(slow.id, const Duration(seconds: 2));

        // median SRTT = 1s; interval = 1s * 2 = 2s. The old min-based pacing
        // would give 100ms * 2 = 200ms.
        expect(
          h.engine.effectiveGossipInterval,
          equals(const Duration(seconds: 2)),
        );
      },
    );

    test(
      'a single fast peer does not pin the loop to a fast cadence',
      () {
        final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
        final fast = h.addPeer('fast');
        final slow1 = h.addPeer('slow1');
        final slow2 = h.addPeer('slow2');
        h.peerRegistry.recordPeerRtt(fast.id, const Duration(milliseconds: 100));
        h.peerRegistry.recordPeerRtt(slow1.id, const Duration(seconds: 2));
        h.peerRegistry.recordPeerRtt(slow2.id, const Duration(seconds: 2));

        // Median is a slow peer (2s) -> interval = 2s * 2 = 4s, not the 200ms
        // the fast peer would have pinned it to under min-based pacing.
        expect(
          h.engine.effectiveGossipInterval,
          equals(const Duration(seconds: 4)),
        );
      },
    );
  });
}
