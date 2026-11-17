// Translated from gossip-kt
// `src/test/kotlin/com/neutrinographics/gossip/sync/domain/services/DigestScopingTest.kt`
// (d902a61).
import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/sync/domain/services/digest_scoping.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';
import 'package:gossip/src/sync/domain/value_objects/stream_digest.dart';

void main() {
  group('DigestScoping', () {
    final c1 = ChannelId('c1');
    final c2 = ChannelId('c2');
    final c3 = ChannelId('c3');

    ChannelDigest digest(ChannelId id) => ChannelDigest(
      channelId: id,
      streams: [
        StreamDigest(
          streamId: StreamId('s'),
          version: VersionVector({NodeId('a'): 1}),
        ),
      ],
    );

    test('a channel the peer has shown gets our digest, one it has not gets '
        'an announcement', () {
      final scoped = DigestScoping.scope(
        [digest(c1), digest(c2), digest(c3)],
        {c2},
      );
      expect(scoped.digests, [digest(c2)]);
      expect(scoped.announced, [c1, c3]);
    });

    test('a peer that has shown nothing is announced everything and digested '
        'nothing', () {
      final scoped = DigestScoping.scope([digest(c1), digest(c2)], {});
      expect(scoped.digests, isEmpty);
      expect(scoped.announced, [c1, c2]);
    });

    test('a channel the peer has shown but we no longer hold is neither '
        'digested nor announced', () {
      final scoped = DigestScoping.scope([digest(c1)], {c1, c2});
      expect(scoped.digests, [digest(c1)]);
      expect(scoped.announced, isEmpty);
    });

    test('order is the order we hold them in, within each list', () {
      final scoped = DigestScoping.scope(
        [digest(c3), digest(c1), digest(c2)],
        {c1, c3},
      );
      expect(scoped.digests.map((d) => d.channelId), [c3, c1]);
      expect(scoped.announced, [c2]);
    });

    test('a digest with no streams for a shown channel is still a digest '
        'here', () {
      // The wire renders it as an empty list and the peer reads an
      // announcement — the rulings accept that reading.
      final bare = ChannelDigest(channelId: c1, streams: const []);
      expect(DigestScoping.scope([bare], {c1}).digests, [bare]);
    });
  });
}
