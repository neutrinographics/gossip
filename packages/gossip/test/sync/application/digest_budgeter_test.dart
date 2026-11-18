import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_version.dart';
import 'package:gossip/src/sync/application/digest_budgeter.dart';
import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:gossip/src/sync/domain/services/digest_scoping.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';
import 'package:gossip/src/sync/domain/value_objects/stream_digest.dart';
import 'package:gossip/src/sync/infrastructure/sync_message_codec.dart';
import 'package:test/test.dart';

/// Translated from gossip-kt's `DigestBudgeterTest.kt`
/// (src/test/kotlin/com/neutrinographics/gossip/sync/application/). Sizes are
/// measured through the real codec, so the budgets below are derived from
/// encoded requests, not guessed.
void main() {
  final localNode = NodeId('local');
  final codec = SyncMessageCodec(wireVersion: WireVersion.v2);
  final peerA = NodeId('peer-a');
  final peerB = NodeId('peer-b');

  // The rotation lives inside the budgeter; its effects are observed through
  // the windows it hands out.

  DigestBudgeter budgeter(
    int maxMessageBytes, {
    int announceBudgetBytes = 1024,
  }) => DigestBudgeter(
    codec: codec,
    localNode: localNode,
    maxMessageBytes: maxMessageBytes,
    announceBudgetBytes: announceBudgetBytes,
  );

  StreamDigest streamDigest(String name, int authors) => StreamDigest(
    streamId: StreamId(name),
    version: VersionVector({
      for (var a = 1; a <= authors; a++) NodeId('author-$a'): 1,
    }),
  );

  ChannelDigest channel(int i, {int streams = 1, int authors = 5}) =>
      ChannelDigest(
        channelId: ChannelId('channel-$i'),
        streams: [
          for (var s = 1; s <= streams; s++) streamDigest('stream-$s', authors),
        ],
      );

  List<ChannelDigest> channels(int from, int count) => [
    for (var i = from; i < from + count; i++) channel(i),
  ];

  ChannelId announceId(int i) =>
      ChannelId('chan-${i.toString().padLeft(31, '0')}');

  int encodedSize(
    List<ChannelDigest> digests, [
    List<ChannelId> announced = const [],
  ]) => codec
      .encode(
        DigestRequest(
          sender: localNode,
          digests: digests,
          announced: announced,
        ),
      )
      .length;

  ScopedDigests scoped(
    List<ChannelDigest> digests, [
    List<ChannelId> announced = const [],
  ]) => ScopedDigests(digests: digests, announced: announced);

  List<(ChannelId, StreamId)> pairs(List<ChannelDigest> digests) => [
    for (final d in digests)
      for (final s in d.streams) (d.channelId, s.streamId),
  ];

  test('a digest set that fits the budget passes through unchanged and '
      'moves no rotation', () {
    final digests = [for (var i = 1; i <= 3; i++) channel(i, streams: 2)];
    final b = budgeter(30 * 1024);

    for (var round = 0; round < 2; round++) {
      final fitted = b.fitRequest(scoped(digests), peerA);

      expect(fitted.digests, equals(digests));
      expect(fitted.oversized, isEmpty);
    }
  });

  // One budgeter sees a list that fits whole, then a longer one that does
  // not: had the whole fit stamped its items, the window would skip them.
  test('a request that fits whole stamps nothing', () {
    final b = budgeter(encodedSize(channels(1, 3)) + 5);

    expect(b.fitRequest(scoped(channels(1, 2)), peerA).digests, hasLength(2));
    final window = b.fitRequest(scoped(channels(1, 10)), peerA).digests;

    expect(window.first.channelId, equals(ChannelId('channel-1')));
  });

  test('a response that fits whole stamps nothing', () {
    final b = budgeter(encodedSize(channels(1, 3)) + 5);

    expect(b.fitResponse(channels(1, 2), peerA).digests, hasLength(2));
    final window = b.fitResponse(channels(1, 10), peerA).digests;

    expect(window.first.channelId, equals(ChannelId('channel-1')));
  });

  test('an over-budget request selects a rotated window that wraps past the '
      'end on the next call', () {
    final digests = [for (var i = 1; i <= 10; i++) channel(i)];
    final budget = encodedSize(digests.take(3).toList()) + 5;
    final b = budgeter(budget);

    final windows = [
      for (var i = 0; i < 8; i++)
        pairs(b.fitRequest(scoped(digests), peerA).digests),
    ];

    expect(
      windows.every((w) => w.isNotEmpty && w.length < 10),
      isTrue,
      reason: 'each call a window, not the whole set',
    );
    final seen = windows.expand((w) => w).toList();
    final expected = [
      for (var i = 0; i < seen.length; i++) pairs([digests[i % 10]]).single,
    ];
    expect(seen, equals(expected));
    expect(seen.length, greaterThan(10), reason: 'the walk went past the end');
  });

  test('a fitted request stamps only the request list, and a fitted response '
      'only the response list', () {
    final digests = [for (var i = 1; i <= 10; i++) channel(i)];
    final tight = budgeter(encodedSize(digests.take(3).toList()) + 5);

    // After a request the response list is still unstamped: the first
    // response window is the head of the list, as on a fresh peer.
    tight.fitRequest(scoped(digests), peerA);
    final firstResponse = tight.fitResponse(digests, peerA).digests;
    expect(
      pairs(firstResponse).first,
      equals(pairs([digests.first]).single),
      reason: 'a request must not have moved the response rotation',
    );

    // And the other way round: a response did not move the request rotation,
    // so the next request continues from its own first window.
    final secondRequest = tight.fitRequest(scoped(digests), peerA).digests;
    final firstWindowLength = pairs(firstResponse).length;
    expect(
      pairs(secondRequest).first,
      equals(pairs([digests[firstWindowLength]]).single),
      reason: 'a response must not have moved the request rotation',
    );
  });

  // Codex, PR #20: engine-wide request/response cursors let alternating peers
  // each be handed the same window forever. Two identical lists that split
  // into exactly two windows make it exact.
  (List<ChannelDigest>, int) twoWindowDigests() {
    final digests = [for (var i = 1; i <= 4; i++) channel(i)];
    return (digests, encodedSize(digests.take(2).toList()) + 2);
  }

  test('each peer has its own request rotation, so alternating peers each '
      'see both windows', () {
    final (digests, budget) = twoWindowDigests();
    final b = budgeter(budget);

    final forA = <(ChannelId, StreamId)>{};
    final forB = <(ChannelId, StreamId)>{};
    for (var i = 0; i < 2; i++) {
      forA.addAll(pairs(b.fitRequest(scoped(digests), peerA).digests));
      forB.addAll(pairs(b.fitRequest(scoped(digests), peerB).digests));
    }

    expect(forA, equals(pairs(digests).toSet()), reason: 'peer A missed one');
    expect(forB, equals(pairs(digests).toSet()), reason: 'peer B missed one');
  });

  test('each peer has its own response rotation, so alternating peers each '
      'see both windows', () {
    final (digests, budget) = twoWindowDigests();
    final b = budgeter(budget);

    final forA = <(ChannelId, StreamId)>{};
    final forB = <(ChannelId, StreamId)>{};
    for (var i = 0; i < 2; i++) {
      forA.addAll(pairs(b.fitResponse(digests, peerA).digests));
      forB.addAll(pairs(b.fitResponse(digests, peerB).digests));
    }

    expect(forA, equals(pairs(digests).toSet()), reason: 'peer A missed one');
    expect(forB, equals(pairs(digests).toSet()), reason: 'peer B missed one');
  });

  // Codex, PR #20 (third pass): a position into a list that changes shape
  // skips or starves. These scenarios fail under a positional cursor and pass
  // under least-recently-sent.
  test('alternating response lists that each need two windows are each '
      'answered in full', () {
    final listA = channels(1, 4);
    final listB = channels(5, 4);
    final b = budgeter(encodedSize(listA.take(2).toList()) + 2);

    final answeredA = <(ChannelId, StreamId)>{};
    final answeredB = <(ChannelId, StreamId)>{};
    for (var i = 0; i < 2; i++) {
      answeredA.addAll(pairs(b.fitResponse(listA, peerA).digests));
      answeredB.addAll(pairs(b.fitResponse(listB, peerA).digests));
    }

    expect(answeredA, equals(pairs(listA).toSet()), reason: 'A not answered');
    expect(answeredB, equals(pairs(listB).toSet()), reason: 'B not answered');
  });

  test('a request list that loses and regains items still offers every item '
      'that has not been offered', () {
    final full = channels(1, 6);
    final b = budgeter(encodedSize(full.take(3).toList()) + 5);

    final first = b.fitRequest(scoped(full), peerA).digests;
    final second = b.fitRequest(scoped(full.skip(2).toList()), peerA).digests;
    final restored = b.fitRequest(scoped(full), peerA).digests;

    List<ChannelId> ids(List<ChannelDigest> d) => [
      for (final c in d) c.channelId,
    ];
    expect(ids(first), equals(ids(full.take(3).toList())));
    expect(
      ids(second),
      equals(ids(full.skip(3).toList())),
      reason: 'unseen items must come before any repeat',
    );
    expect(
      ids(restored),
      equals(ids(full.take(3).toList())),
      reason: 'then the ones offered longest ago',
    );
  });

  test('announcements that the peer shows between windows are not skipped '
      'past', () {
    final ids = [for (var i = 1; i <= 30; i++) announceId(i)];
    final b = budgeter(30 * 1024);

    final first = b.fitRequest(scoped(const [], ids), peerA).announced;
    expect(
      first.length,
      allOf(greaterThanOrEqualTo(1), lessThanOrEqualTo(24)),
      reason: 'the first window must not hold every id',
    );
    final firstFive = first.take(5).toSet();
    final remaining = [
      for (final id in ids)
        if (!firstFive.contains(id)) id,
    ];
    final second = b.fitRequest(scoped(const [], remaining), peerA).announced;

    final unannounced = [
      for (final id in remaining)
        if (!first.contains(id)) id,
    ];
    expect(
      second.length,
      lessThanOrEqualTo(unannounced.length),
      reason: 'the scenario needs enough unannounced ids',
    );
    expect(
      second,
      equals(unannounced.take(second.length).toList()),
      reason: 'the next window must continue with the ids not yet announced',
    );
  });

  test('a stream whose digest alone exceeds the budget is skipped and '
      'reported as oversized, and the rest still go', () {
    final small = channels(1, 4);
    final huge = ChannelDigest(
      channelId: ChannelId('channel-huge'),
      streams: [streamDigest('stream-huge', 300)],
    );
    final digests = [...small.take(2), huge, ...small.skip(2)];
    final budget = encodedSize(small) + 5;
    expect(encodedSize([huge]), greaterThan(budget));

    final fitted = budgeter(budget).fitRequest(scoped(digests), peerA);

    expect(fitted.oversized, hasLength(1));
    expect(fitted.oversized.single.channel, equals(ChannelId('channel-huge')));
    expect(fitted.oversized.single.streamId, equals(StreamId('stream-huge')));
    expect(fitted.oversized.single.cost, greaterThan(budget));
    expect([
      for (final d in fitted.digests) d.channelId,
    ], equals([for (final d in small) d.channelId]));
  });

  test('the fitted request always encodes within maxMessageBytes', () {
    final digests = [for (var i = 1; i <= 40; i++) channel(i, streams: 3)];
    final announced = [for (var i = 1; i <= 30; i++) announceId(i)];

    for (final budget in [1024, 4096, 30 * 1024]) {
      final b = budgeter(budget);
      for (var round = 0; round < 6; round++) {
        final f = b.fitRequest(scoped(digests, announced), peerA);
        final size = encodedSize(f.digests, f.announced);
        expect(size, lessThanOrEqualTo(budget), reason: 'budget $budget');
      }
    }
  });

  test('the fitted response always encodes within maxMessageBytes', () {
    final digests = [for (var i = 1; i <= 40; i++) channel(i, streams: 3)];

    for (final budget in [1024, 4096, 30 * 1024]) {
      final b = budgeter(budget);
      for (var round = 0; round < 6; round++) {
        final f = b.fitResponse(digests, peerA);
        expect(
          encodedSize(f.digests),
          lessThanOrEqualTo(budget),
          reason: 'budget $budget',
        );
      }
    }
  });

  test('announcements that fit the announce budget all go, in order, and '
      'are all stamped as sent', () {
    final ids = [for (var i = 1; i <= 3; i++) announceId(i)];
    final b = budgeter(30 * 1024);

    final fitted = b.fitRequest(scoped(const [], ids), peerA);

    expect(fitted.announced, equals(ids));
    expect(fitted.unannounceable, isEmpty);
    // Stamped: a never-sent id sorts before the three that went; with
    // nothing stamped the list order would put the three first.
    final more = [...ids, announceId(4)];
    expect(
      b.fitRequest(scoped(const [], more), peerA).announced,
      equals([announceId(4), ...ids]),
    );
  });

  test('announcements over the announce budget are rotated so every channel '
      'is named across successive requests and none repeats before the '
      'cycle completes', () {
    final ids = [for (var i = 1; i <= 36; i++) announceId(i)];
    final b = budgeter(30 * 1024);
    final base = encodedSize(const []);

    final calls = [
      for (var i = 0; i < 4; i++)
        b.fitRequest(scoped(const [], ids), peerA).announced,
    ];

    for (final named in calls) {
      expect(named, isNotEmpty);
      expect(
        encodedSize(const [], named) - base,
        lessThanOrEqualTo(1024),
        reason: 'announcements over their budget',
      );
    }
    final afterThree = calls.take(3).expand((c) => c).toSet();
    expect(afterThree, equals(ids.toSet()));
    final firstCycle = calls.expand((c) => c).take(ids.length).toList();
    expect(
      firstCycle.toSet(),
      hasLength(ids.length),
      reason: 'an id repeated before the cycle completed',
    );
  });

  test('each peer has its own announce rotation, so alternating peers each '
      'see every channel', () {
    final ids = [for (var i = 1; i <= 30; i++) announceId(i)];
    final b = budgeter(30 * 1024);

    final forA = <List<ChannelId>>[];
    final forB = <List<ChannelId>>[];
    for (var i = 0; i < 4; i++) {
      forA.add(b.fitRequest(scoped(const [], ids), peerA).announced);
      forB.add(b.fitRequest(scoped(const [], ids), peerB).announced);
    }

    for (final calls in [forA, forB]) {
      expect(
        calls.take(3).expand((c) => c).toSet(),
        equals(ids.toSet()),
        reason: 'a peer missed channels in its first three requests',
      );
    }
  });

  test("one peer's requests do not touch another peer's announce "
      'rotation', () {
    final ids = [for (var i = 1; i <= 30; i++) announceId(i)];
    final b = budgeter(30 * 1024);

    b.fitRequest(scoped(const [], ids), peerA);
    b.fitRequest(scoped(const [], ids), peerA);

    final first = b.fitRequest(scoped(const [], ids), peerB).announced;
    expect(
      first,
      equals(ids.take(first.length).toList()),
      reason: 'peer B starts from the first channel',
    );
  });

  test('an announce budget of zero never announces and reports nothing', () {
    final ids = [for (var i = 1; i <= 5; i++) announceId(i)];
    final b = budgeter(30 * 1024, announceBudgetBytes: 0);

    final fitted = b.fitRequest(scoped(const [], ids), peerA);

    expect(fitted.announced, isEmpty);
    expect(fitted.unannounceable, isEmpty);
  });

  test('announcements are not spent when the digests fill the message', () {
    final digests = channels(1, 3);
    final ids = [for (var i = 1; i <= 5; i++) announceId(i)];
    final announceCost =
        encodedSize(const [], [ids.first]) - encodedSize(const []);
    final budget = encodedSize(digests) + announceCost - 1;
    final b = budgeter(budget);

    final fitted = b.fitRequest(scoped(digests, ids), peerA);

    expect(fitted.digests, equals(digests));
    expect(fitted.announced, isEmpty);
    expect(fitted.unannounceable, isEmpty);
    expect(
      b.fitRequest(scoped(const [], ids), peerA).announced.first,
      equals(ids.first),
      reason: 'nothing was stamped for the announcements',
    );
  });

  test('an announcement alone over the announce budget is skipped and '
      'reported, not selected', () {
    final small = ChannelId('c');
    final big = announceId(1);
    final smallCost =
        encodedSize(const [], [small]) - encodedSize(const []) + 1;

    final fitted = budgeter(
      30 * 1024,
      announceBudgetBytes: smallCost,
    ).fitRequest(scoped(const [], [big, small]), peerA);

    expect(fitted.announced, equals([small]));
    expect(fitted.unannounceable, equals([big]));
  });

  test("a positive announce budget below every announcement's cost "
      'announces nothing and reports nothing, round after round', () {
    final ids = [for (var i = 1; i <= 3; i++) announceId(i)];
    final b = budgeter(30 * 1024, announceBudgetBytes: 20);

    for (var round = 0; round < 3; round++) {
      final fitted = b.fitRequest(scoped(const [], ids), peerA);

      expect(fitted.announced, isEmpty);
      expect(fitted.unannounceable, isEmpty);
    }
  });

  test('an announce budget above the room the digests left is clamped to '
      'that room', () {
    final digests = channels(1, 3);
    final ids = [for (var i = 1; i <= 36; i++) announceId(i)];
    final announceCost =
        encodedSize(const [], [ids.first]) - encodedSize(const []);
    final budget = encodedSize(digests) + announceCost * 4 + 2;

    final fitted = budgeter(budget).fitRequest(scoped(digests, ids), peerA);

    expect(fitted.announced, isNotEmpty, reason: 'none announced');
    expect(fitted.announced.length, lessThan(ids.length));
    expect(
      encodedSize(fitted.digests, fitted.announced),
      lessThanOrEqualTo(budget),
    );
    expect(
      fitted.announced,
      equals(ids.take(fitted.announced.length).toList()),
    );
  });

  test('a stream digest whose standalone message is exactly maxMessageBytes '
      'is sent in some rotation and never reported oversized', () {
    final exact = ChannelDigest(
      channelId: ChannelId('channel-exact'),
      streams: [streamDigest('stream-exact', 12)],
    );
    final small = channel(1);
    final budget = encodedSize([exact]);
    expect(
      encodedSize([exact, small]),
      greaterThan(budget),
      reason: 'the pair must force the windowing path',
    );
    final b = budgeter(budget);

    final calls = [
      for (var i = 0; i < 3; i++) b.fitRequest(scoped([exact, small]), peerA),
    ];

    expect(calls.every((c) => c.oversized.isEmpty), isTrue);
    expect(
      calls.any((c) => c.digests.any((d) => d.channelId == exact.channelId)),
      isTrue,
      reason: 'the exact-fit digest was never sent',
    );
    for (final c in calls) {
      expect(encodedSize(c.digests, c.announced), lessThanOrEqualTo(budget));
    }
  });

  test('an exact-fit window encodes to exactly maxMessageBytes', () {
    final digests = channels(1, 3);
    final budget = encodedSize(digests.take(2).toList());

    final fitted = budgeter(budget).fitRequest(scoped(digests), peerA);

    expect(fitted.digests, hasLength(2));
    expect(encodedSize(fitted.digests, fitted.announced), equals(budget));
  });

  test('an announcement that exactly fills the announce budget is '
      'announced, not reported', () {
    final id = announceId(1);
    final cost = encodedSize(const [], [id]) - encodedSize(const []);

    final fitted = budgeter(
      30 * 1024,
      announceBudgetBytes: cost,
    ).fitRequest(scoped(const [], [id, announceId(2)]), peerA);

    expect(fitted.announced, equals([id]));
    expect(fitted.unannounceable, isEmpty);
  });

  test('an announcement after selected digests is charged the separator '
      'that joins it to them', () {
    final digests = channels(1, 3);
    final ids = [for (var i = 1; i <= 36; i++) announceId(i)];
    final one = encodedSize(digests, [ids.first]);

    final fitted = budgeter(one).fitRequest(scoped(digests, ids), peerA);

    expect(fitted.announced, equals([ids.first]));
    expect(encodedSize(fitted.digests, fitted.announced), equals(one));
  });

  test('an empty channel digest survives the over-budget path', () {
    final empty = ChannelDigest(
      channelId: ChannelId('channel-empty'),
      streams: const [],
    );
    final digests = [
      empty,
      for (var i = 1; i <= 8; i++) channel(i, authors: 20),
    ];
    final budget = encodedSize(digests) ~/ 2;
    expect(encodedSize(digests), greaterThan(budget));
    final b = budgeter(budget);

    final calls = [for (var i = 0; i < 4; i++) b.fitResponse(digests, peerA)];

    expect(
      calls.first.digests.any(
        (d) => d.channelId == empty.channelId && d.streams.isEmpty,
      ),
      isTrue,
      reason: 'empty digest missing from the first answer',
    );
    expect(
      calls.any((c) => c.digests.any((d) => d.channelId == empty.channelId)),
      isTrue,
    );
    for (final c in calls) {
      expect(encodedSize(c.digests), lessThanOrEqualTo(budget));
    }
  });

  test('forget returns a peer to the start of every list, and reset every '
      'peer', () {
    final digests = channels(1, 4);
    final budget = encodedSize(digests.take(2).toList()) + 2;
    final b = budgeter(budget);
    final head = pairs(b.fitRequest(scoped(digests), peerA).digests);
    b.fitRequest(scoped(digests), peerB);

    b.forget(peerA);
    expect(pairs(b.fitRequest(scoped(digests), peerA).digests), equals(head));

    b.fitRequest(scoped(digests), peerB);
    b.reset();
    expect(pairs(b.fitRequest(scoped(digests), peerB).digests), equals(head));
  });

  group('the results are values', () {
    final huge = ChannelDigest(
      channelId: ChannelId('channel-huge'),
      streams: [streamDigest('stream-huge', 300)],
    );
    List<ChannelDigest> input() => [...channels(1, 4), huge];
    int budget() => encodedSize(channels(1, 4)) + 5;

    test('FittedRequest built twice from the same inputs is equal', () {
      final one = budgeter(budget()).fitRequest(scoped(input()), peerA);
      final two = budgeter(budget()).fitRequest(scoped(input()), peerA);

      expect(one.oversized, isNotEmpty);
      expect(one, two);
      expect(one.hashCode, two.hashCode);
      expect(
        one,
        isNot(budgeter(30 * 1024).fitRequest(scoped(input()), peerA)),
      );
    });

    test('FittedResponse built twice from the same inputs is equal', () {
      final one = budgeter(budget()).fitResponse(input(), peerA);
      final two = budgeter(budget()).fitResponse(input(), peerA);

      expect(one.oversized, isNotEmpty);
      expect(one, two);
      expect(one.hashCode, two.hashCode);
      expect(one, isNot(budgeter(30 * 1024).fitResponse(input(), peerA)));
    });

    test('OversizedDigest built twice from the same inputs is equal', () {
      final one = budgeter(budget()).fitResponse(input(), peerA).oversized;
      final two = budgeter(budget()).fitResponse(input(), peerA).oversized;

      expect(one.single, two.single);
      expect(one.single.hashCode, two.single.hashCode);
      expect(
        one.single,
        isNot(
          OversizedDigest(
            channel: one.single.channel,
            streamId: one.single.streamId,
            cost: one.single.cost + 1,
          ),
        ),
      );
    });
  });
}
