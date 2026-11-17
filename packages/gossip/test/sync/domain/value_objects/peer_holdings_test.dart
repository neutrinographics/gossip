// Translated from gossip-kt
// `src/test/kotlin/com/neutrinographics/gossip/sync/domain/values/PeerHoldingsTest.kt`
// (d902a61).
import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/sync/domain/value_objects/peer_holdings.dart';

void main() {
  group('PeerHoldings', () {
    final peer = NodeId('peer-a');
    final other = NodeId('peer-b');
    final c1 = ChannelId('c1');
    final c2 = ChannelId('c2');
    final c3 = ChannelId('c3');

    test('a peer that has shown nothing holds nothing', () {
      expect(PeerHoldings.initial.of(peer), isEmpty);
    });

    test('learning a name adds it and keeps what was learned before', () {
      final h = PeerHoldings.initial.learn(peer, [c1]).learn(peer, [c2]);
      expect(h.of(peer), {c1, c2});
    });

    test('learning an empty list changes nothing and creates no entry', () {
      final h = PeerHoldings.initial.learn(peer, const []);
      expect(h, PeerHoldings.initial);
      expect(h.byPeer.containsKey(peer), isFalse);
    });

    test('a name learned once is never removed by a later message that '
        'omits it', () {
      final h = PeerHoldings.initial.learn(peer, [c1, c2]).learn(peer, [c3]);
      expect(h.of(peer), {c1, c2, c3});
    });

    test('forgetting a peer removes only that peer', () {
      final h = PeerHoldings.initial
          .learn(peer, [c1])
          .learn(other, [c2])
          .forget(peer);
      expect(h.of(peer), isEmpty);
      expect(h.of(other), {c2});
    });

    test('forgetting an unknown peer is the same value', () {
      final h = PeerHoldings.initial.learn(other, [c2]);
      expect(h.forget(peer), h);
    });

    test('every transition answers a new value and leaves its input '
        'untouched', () {
      final before = PeerHoldings.initial.learn(peer, [c1]);
      final snapshot = {
        for (final e in before.byPeer.entries) e.key: Set.of(e.value),
      };
      before.learn(peer, [c2]);
      before.forget(peer);
      expect(before.byPeer, snapshot);
    });

    test('the map and its sets are unmodifiable views', () {
      final h = PeerHoldings.initial.learn(peer, [c1]);
      expect(() => h.byPeer[other] = {c2}, throwsUnsupportedError);
      expect(() => h.of(peer).add(c2), throwsUnsupportedError);
    });
  });
}
