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

    test('markProbed re-arms at issue time with doubled backoff', () {
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

      // The window opens at 30s; the probing request is issued and marked.
      r.markProbed(peer, channelId, streamId, 30000);

      // Re-armed immediately — a lost or empty probe response can never
      // leave the record permanently probe-due.
      expect(
        r.shapeSince(peer, channelId, streamId, base, nowMs: 30001)[author],
        208,
        reason: 'suppressed again the moment the probe is issued',
      );
      // Doubled: next window opens 60s after the probe.
      expect(
        r.shapeSince(peer, channelId, streamId, base, nowMs: 89999)[author],
        208,
      );
      expect(
        r.shapeSince(peer, channelId, streamId, base, nowMs: 90000)[author],
        5,
      );

      // Many probes: the window never exceeds maxBackoff (10min).
      var t = 90000;
      for (var i = 0; i < 10; i++) {
        r.markProbed(peer, channelId, streamId, t);
        t += 600000; // jump a full cap each time
      }
      expect(
        r.shapeSince(peer, channelId, streamId, base, nowMs: t + 600000)[author],
        5,
        reason: 'probe window must open within maxBackoff',
      );
    });

    test('markProbed leaves a still-suppressed record untouched', () {
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

      // A request issued while suppressed is not a probe for this author.
      r.markProbed(peer, channelId, streamId, 10000);

      final base = VersionVector({author: 5});
      expect(
        r.shapeSince(peer, channelId, streamId, base, nowMs: 30000)[author],
        5,
        reason: 'the original 30s window still opens on schedule',
      );
    });

    test(
      're-recording refreshes evidence without touching the probe '
      'schedule: expectation moves, advertisedMax is monotonic',
      () {
        final r = registry();
        r.recordGap(
          peer,
          channelId,
          streamId,
          author,
          expectedNext: 6,
          advertisedMax: 1000,
          nowMs: 0,
        );

        // Mid-drain chunks re-record within the window: no doubling, and a
        // smaller chunk maximum must never lower the stored one.
        r.recordGap(
          peer,
          channelId,
          streamId,
          author,
          expectedNext: 8,
          advertisedMax: 300,
          nowMs: 1000,
        );

        // The fresh expectation keeps the record live at the new coverage
        // (the peer backfilled 6..7; the hole moved to 8).
        final base = VersionVector({author: 7});
        expect(
          r.shapeSince(peer, channelId, streamId, base, nowMs: 2000)[author],
          1000,
          reason: 'expectation refreshed to 8; advertisedMax stays 1000',
        );
        // And the probe window still opens at the ORIGINAL 30s — chunks are
        // not probe failures.
        expect(
          r.shapeSince(peer, channelId, streamId, base, nowMs: 30000)[author],
          7,
          reason: 'window unchanged by re-records',
        );
      },
    );
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
