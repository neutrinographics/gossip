import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/sync/domain/aggregates/stalled_range_registry.dart';
import 'package:test/test.dart';

void main() {
  final peer = NodeId('peer-1');
  final otherPeer = NodeId('peer-2');
  final channelId = ChannelId('ch');
  final streamId = StreamId('st');
  final author = NodeId('author-x');
  final otherAuthor = NodeId('author-y');

  StalledRangeRegistry registry() => StalledRangeRegistry();

  group('shapeSince', () {
    test('a recorded gap shapes the author to the never-lower max', () {
      final r = registry();
      r.recordGap(
        peer,
        channelId,
        streamId,
        author,
        expectedNext: 6,
        advertisedMax: 208,
        nowMs: 0,
      );

      final base = VersionVector({author: 5, otherAuthor: 3});
      final shaped = r.shapeSince(
        peer,
        channelId,
        streamId,
        base,
        digestCeiling: VersionVector({author: 210}),
        nowMs: 1000,
      );

      expect(
        shaped[author],
        210,
        reason: 'digest ceiling above advertisedMax wins the max',
      );
      expect(shaped[otherAuthor], 3, reason: 'other authors untouched');

      final noCeiling = r.shapeSince(peer, channelId, streamId, base, nowMs: 1000);
      expect(noCeiling[author], 208, reason: 'advertisedMax without a digest');
    });

    test('other peers and streams are unaffected', () {
      final r = registry();
      r.recordGap(
        peer,
        channelId,
        streamId,
        author,
        expectedNext: 6,
        advertisedMax: 208,
        nowMs: 0,
      );

      final base = VersionVector({author: 5});
      expect(r.shapeSince(otherPeer, channelId, streamId, base, nowMs: 0), base);
      expect(
        r.shapeSince(peer, channelId, StreamId('other'), base, nowMs: 0),
        base,
      );
    });

    test(
      'is a pure query: stale entries contribute nothing and repeated '
      'calls return the same answer',
      () {
        final r = registry();
        r.recordGap(
          peer,
          channelId,
          streamId,
          author,
          expectedNext: 6,
          advertisedMax: 208,
          nowMs: 0,
        );

        // Our coverage moved past the recorded expectation (the range
        // arrived from elsewhere): the entry is stale and must not shape,
        // even though nothing has evicted it.
        final advanced = VersionVector({author: 150});
        final first = r.shapeSince(peer, channelId, streamId, advanced, nowMs: 0);
        final second = r.shapeSince(peer, channelId, streamId, advanced, nowMs: 0);
        expect(first, advanced);
        expect(second, advanced);

        // And the non-stale view still shapes afterwards — no state changed.
        final base = VersionVector({author: 5});
        expect(r.shapeSince(peer, channelId, streamId, base, nowMs: 0)[author], 208);
      },
    );

    test('an open probe window unshapes the author', () {
      final r = registry();
      r.recordGap(
        peer,
        channelId,
        streamId,
        author,
        expectedNext: 6,
        advertisedMax: 208,
        nowMs: 0,
      );
      final base = VersionVector({author: 5});

      // Before the window: suppressed.
      expect(
        r.shapeSince(peer, channelId, streamId, base, nowMs: 29999)[author],
        208,
      );
      // Window open at initialBackoff (30s): the request IS the probe.
      expect(
        r.shapeSince(peer, channelId, streamId, base, nowMs: 30000)[author],
        5,
      );
    });

    test('re-recording doubles the backoff up to the cap', () {
      final r = registry();
      final base = VersionVector({author: 5});
      r.recordGap(
        peer,
        channelId,
        streamId,
        author,
        expectedNext: 6,
        advertisedMax: 208,
        nowMs: 0,
      );
      // Probe at 30s fails; re-record doubles to 60s.
      r.recordGap(
        peer,
        channelId,
        streamId,
        author,
        expectedNext: 6,
        advertisedMax: 209,
        nowMs: 30000,
      );
      expect(
        r.shapeSince(peer, channelId, streamId, base, nowMs: 89999)[author],
        209,
        reason: 'still suppressed inside the doubled window',
      );
      expect(
        r.shapeSince(peer, channelId, streamId, base, nowMs: 90000)[author],
        5,
      );

      // Many re-records: the window never exceeds maxBackoff (10min).
      var t = 90000;
      for (var i = 0; i < 10; i++) {
        r.recordGap(
          peer,
          channelId,
          streamId,
          author,
          expectedNext: 6,
          advertisedMax: 209,
          nowMs: t,
        );
        t += 600000; // jump a full cap each time
      }
      r.recordGap(
        peer,
        channelId,
        streamId,
        author,
        expectedNext: 6,
        advertisedMax: 209,
        nowMs: t,
      );
      expect(
        r.shapeSince(peer, channelId, streamId, base, nowMs: t + 600000)[author],
        5,
        reason: 'probe window must open within maxBackoff',
      );
    });
  });

  group('commands', () {
    test('evictSatisfied removes exactly the passed-expectation entries', () {
      final r = registry();
      r.recordGap(
        peer,
        channelId,
        streamId,
        author,
        expectedNext: 6,
        advertisedMax: 208,
        nowMs: 0,
      );
      r.recordGap(
        peer,
        channelId,
        streamId,
        otherAuthor,
        expectedNext: 3,
        advertisedMax: 40,
        nowMs: 0,
      );

      // author's range arrived (coverage now 150); otherAuthor still stalled.
      r.evictSatisfied(
        peer,
        channelId,
        streamId,
        VersionVector({author: 150, otherAuthor: 2}),
      );

      final base = VersionVector({author: 150, otherAuthor: 2});
      final shaped = r.shapeSince(peer, channelId, streamId, base, nowMs: 0);
      expect(shaped[author], 150, reason: 'evicted — no shaping');
      expect(shaped[otherAuthor], 40, reason: 'survivor still shapes');
    });

    test('clearForPeer and clearAll drop the right entries', () {
      final r = registry();
      r.recordGap(
        peer,
        channelId,
        streamId,
        author,
        expectedNext: 6,
        advertisedMax: 208,
        nowMs: 0,
      );
      r.recordGap(
        otherPeer,
        channelId,
        streamId,
        author,
        expectedNext: 6,
        advertisedMax: 208,
        nowMs: 0,
      );

      r.clearForPeer(peer);
      final base = VersionVector({author: 5});
      expect(r.shapeSince(peer, channelId, streamId, base, nowMs: 0), base);
      expect(
        r.shapeSince(otherPeer, channelId, streamId, base, nowMs: 0)[author],
        208,
      );

      r.clearAll();
      expect(r.shapeSince(otherPeer, channelId, streamId, base, nowMs: 0), base);
    });
  });
}
