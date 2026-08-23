import 'dart:math';

import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:test/test.dart';

import 'gossip_engine_test_harness.dart';

/// L1: gossip partner selection must prefer the least-recently-synced peer
/// (the previously-dead lastAntiEntropyMs field), so coverage is bounded to
/// ~(n-1) rounds instead of pure-random's geometric distribution — the same
/// win H3 gave SWIM probing. A never-gossiped peer counts as most stale.
void main() {
  group('GossipEngine partner selection (L1)', () {
    test(
      'rotates through peers (least-recently-synced): every peer is gossiped '
      'exactly once within n rounds',
      () async {
        // Seeded so the tiebreak is deterministic; coverage is guaranteed for
        // any seed because a never-gossiped peer always outranks a gossiped
        // one, but pure-random selection would not cover all n in n rounds.
        final h = GossipEngineTestHarness(random: Random(12345));
        final peers = [
          h.addPeer('a'),
          h.addPeer('b'),
          h.addPeer('c'),
          h.addPeer('d'),
        ];
        h.createChannel('ch1', streamIds: ['s1']);

        final caps = {for (final p in peers) p.id: h.captureMessages(p)};

        for (var round = 0; round < peers.length; round++) {
          await h.engine.performGossipRound();
          await h.flush();
        }

        for (final p in peers) {
          final digestRequests = caps[p.id]!.$1
              .whereType<DigestRequest>()
              .length;
          expect(
            digestRequests,
            equals(1),
            reason:
                'peer ${p.id.value} must be gossiped exactly once per cycle',
          );
        }

        for (final entry in caps.values) {
          await entry.$2.cancel();
        }
      },
    );

    test('records the anti-entropy timestamp for the selected peer', () async {
      final h = GossipEngineTestHarness();
      final a = h.addPeer('a');
      h.createChannel('ch1', streamIds: ['s1']);

      expect(h.peerRegistry.getPeer(a.id)!.lastAntiEntropyMs, isNull);

      await h.engine.performGossipRound();
      await h.flush();

      expect(
        h.peerRegistry.getPeer(a.id)!.lastAntiEntropyMs,
        isNotNull,
        reason: 'gossiping with a peer must mark it recently-synced',
      );
    });
  });
}
