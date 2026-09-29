import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/sync/domain/aggregates/outstanding_pulls.dart';
import 'package:gossip/src/sync/domain/entities/pull_request.dart';
import 'package:gossip/src/sync/domain/services/legacy_correlation.dart';
import 'package:gossip/src/sync/domain/services/outstanding_pull_tracker.dart';
import 'package:gossip/src/sync/domain/value_objects/answered_pull.dart';
import 'package:test/test.dart';

/// The content rule a peer that has never named a request is judged by, in
/// isolation from the tracker's own cases: what a response can be taken to
/// answer from what it carries alone.
///
/// [LegacyCorrelation] is transitional, so these are the pins that go with
/// it — re-homed from the bridge's tests onto identity-bearing requests.
void main() {
  final peer = NodeId('peer-a');
  final channel = ChannelId('c');
  final stream = StreamId('s');
  final authorA = NodeId('author-a');
  final authorB = NodeId('author-b');
  final authorC = NodeId('author-c');

  ({OutstandingPulls state, PullRequest request}) issue(
    OutstandingPulls pulls, {
    required VersionVector since,
    required Set<NodeId> wanted,
    Set<NodeId> carrying = const {},
    required int nowMs,
  }) => OutstandingPullTracker.issue(
    pulls,
    peer: peer,
    channel: channel,
    stream: stream,
    since: since,
    wanted: wanted,
    carrying: carrying,
    nowMs: nowMs,
  );

  /// One request of ours, built the way the engine builds one.
  PullRequest request(
    VersionVector since, {
    Set<NodeId>? wanted,
    int nowMs = 0,
  }) => issue(
    OutstandingPulls.initial,
    since: since,
    wanted: wanted ?? since.entries.keys.toSet(),
    nowMs: nowMs,
  ).request;

  ({OutstandingPulls state, AnsweredPull? answered}) answer(
    OutstandingPulls pulls, {
    Map<NodeId, int> firstByAuthor = const {},
    VersionVector floor = VersionVector.empty,
    bool hasMore = false,
    bool marksPartialPages = true,
    required int nowMs,
  }) => LegacyCorrelation.answer(
    pulls,
    sender: peer,
    channel: channel,
    stream: stream,
    firstByAuthor: firstByAuthor,
    floor: floor,
    hasMore: hasMore,
    marksPartialPages: marksPartialPages,
    nowMs: nowMs,
  );

  group('answers: what a response can be taken to answer', () {
    test('a response starting one past what each author was asked for answers '
        'the pull', () {
      final since = VersionVector({authorA: 5, authorB: 2});

      expect(
        LegacyCorrelation.answers(request(since), {
          authorA: 6,
          authorB: 3,
        }, VersionVector.empty),
        isTrue,
      );
    });

    test('a floor covering the start answers the pull', () {
      final since = VersionVector({authorA: 5});

      expect(
        LegacyCorrelation.answers(request(since), {
          authorA: 9,
        }, VersionVector({authorA: 8})),
        isTrue,
        reason:
            'the peer compacted everything below where it starts, and '
            'says so',
      );
      expect(
        LegacyCorrelation.answers(request(since), {
          authorA: 9,
        }, VersionVector({authorA: 9})),
        isTrue,
        reason: 'a floor at the start withholds nothing either',
      );
      expect(
        LegacyCorrelation.answers(request(since), {
          authorA: 9,
        }, VersionVector({authorA: 12})),
        isTrue,
        reason: 'nor does one beyond it',
      );
    });

    test('an author starting above what was asked for with no floor to explain '
        'it is no answer', () {
      final since = VersionVector({authorA: 5, authorB: 2});

      expect(
        LegacyCorrelation.answers(request(since), {
          authorA: 6,
          authorB: 4,
        }, VersionVector.empty),
        isFalse,
        reason: 'one author out of two is enough',
      );
      expect(
        LegacyCorrelation.answers(request(since), {
          authorA: 6,
          authorB: 4,
        }, VersionVector({authorB: 2})),
        isFalse,
        reason: 'a floor short of the hole explains nothing',
      );
    });

    test('a response carrying no entries answers the pull', () {
      expect(
        LegacyCorrelation.answers(
          request(VersionVector({authorA: 5})),
          const {},
          VersionVector.empty,
        ),
        isTrue,
        reason:
            'a reply from the peer we asked with nothing to give has '
            'answered it',
      );
    });

    test('an author the pull holds nothing of is judged from sequence one', () {
      final forBoth = request(
        VersionVector({authorA: 5}),
        wanted: {authorA, authorB},
      );

      expect(
        LegacyCorrelation.answers(forBoth, {authorB: 1}, VersionVector.empty),
        isTrue,
      );
      expect(
        LegacyCorrelation.answers(forBoth, {authorB: 3}, VersionVector.empty),
        isFalse,
      );
    });

    test('a response speaking only to an author the pull was not for is no '
        'answer', () {
      final forA = request(
        VersionVector({authorA: 5, authorB: 2}),
        wanted: {authorA},
      );

      expect(
        LegacyCorrelation.answers(forA, {authorB: 3}, VersionVector.empty),
        isFalse,
        reason:
            'B\'s next entry begins where we hold B, but the pull was '
            'for A',
      );
      expect(
        LegacyCorrelation.answers(forA, {
          authorA: 6,
          authorB: 3,
        }, VersionVector.empty),
        isTrue,
        reason: 'an answer carrying A may carry B alongside',
      );
      expect(
        LegacyCorrelation.answers(forA, {
          authorB: 3,
        }, VersionVector({authorA: 7})),
        isTrue,
        reason:
            'a floor past what we hold of A speaks to A without carrying '
            'it',
      );
      expect(
        LegacyCorrelation.answers(forA, {
          authorB: 3,
        }, VersionVector({authorA: 5})),
        isFalse,
        reason: 'a floor no further than what we hold says nothing new about A',
      );
    });

    test('answers and addressed are functions of their inputs and leave them '
        'alone', () {
      final since = VersionVector({authorA: 5, authorB: 2});
      final floor = VersionVector({authorA: 7});
      final first = {authorA: 8, authorB: 3};
      final forBoth = request(since, wanted: {authorA, authorB});
      final firstBefore = {...first};

      final answers = [
        for (var i = 0; i < 3; i++)
          LegacyCorrelation.answers(forBoth, first, floor),
      ];
      final addressed = [
        for (var i = 0; i < 3; i++)
          LegacyCorrelation.addressed(forBoth, first, floor),
      ];

      expect(
        answers,
        equals([true, true, true]),
        reason: 'the same inputs answer the same every time',
      );
      expect(addressed, equals(List.filled(3, {authorA, authorB})));
      expect(since, equals(VersionVector({authorA: 5, authorB: 2})));
      expect(floor, equals(VersionVector({authorA: 7})));
      expect(first, equals(firstBefore));
      expect(forBoth.wanted, equals({authorA, authorB}));
    });
  });

  group('answer: which outstanding request a response settles', () {
    test('no outstanding request can be its answer, so nothing is answered '
        'and the set stands', () {
      final pulls = OutstandingPulls.initial;

      final settled = answer(pulls, firstByAuthor: {authorA: 99}, nowMs: 100);

      expect(settled.answered, isNull);
      expect(settled.state, same(pulls));
    });

    test('a push of an author the live request was not for leaves it '
        'outstanding', () {
      // The racing push a mesh makes commonest: the sender's own newest
      // entry, beginning exactly where we hold that author, against a pull
      // that never asked about it.
      final issued = issue(
        OutstandingPulls.initial,
        since: VersionVector({authorA: 5, authorB: 2}),
        wanted: {authorA},
        nowMs: 0,
      );

      final settled = answer(
        issued.state,
        firstByAuthor: {authorB: 3},
        nowMs: 100,
      );

      expect(settled.answered, isNull);
      expect(
        settled.state.requests.keys,
        equals([issued.request.id]),
        reason: 'the pull is still owed, and still for A',
      );
      expect(
        settled.state.requests[issued.request.id]!.wanted,
        equals({authorA}),
      );
    });

    test('an empty response answers the oldest request to that key', () {
      final since = VersionVector({authorA: 5});
      final older = issue(
        OutstandingPulls.initial,
        since: since,
        wanted: {authorA},
        nowMs: 0,
      );
      final newer = issue(
        older.state,
        since: since,
        wanted: {authorA},
        nowMs: 10,
      );

      final settled = answer(newer.state, nowMs: 100);

      expect(
        settled.answered,
        equals(const AnsweredPull(elapsedMs: 100, remaining: {})),
      );
      expect(
        settled.state.requests.keys,
        equals([newer.request.id]),
        reason: 'the older is retired; the newer stands, unread',
      );
    });

    test('when two requests to one key both match, the older is answered and '
        'the newer untouched', () {
      final since = VersionVector({authorA: 5});
      final older = issue(
        OutstandingPulls.initial,
        since: since,
        wanted: {authorA},
        nowMs: 0,
      );
      final newer = issue(
        older.state,
        since: since,
        wanted: {authorA},
        nowMs: 10,
      );

      final settled = answer(
        newer.state,
        firstByAuthor: {authorA: 6},
        nowMs: 100,
      );

      expect(
        settled.answered,
        equals(const AnsweredPull(elapsedMs: 100, remaining: {})),
        reason: 'measured from the older request, the one overdue',
      );
      expect(settled.state.requests.keys, equals([newer.request.id]));
      expect(
        settled.state.requests[newer.request.id]!.wanted,
        equals({authorA}),
        reason: 'the newer is not read at all',
      );
    });

    test('oldest-first is by issue reading, not by position — an older request '
        'added later is still the one answered', () {
      // The order the aggregate keeps is issue order, which in production is
      // also time order, so a pin that issues the older request first cannot
      // tell whether the rule sorts by issue reading or merely walks the map.
      // This one can: the chronologically older request is added second.
      final since = VersionVector({authorA: 5});
      final addedFirstButNewer = issue(
        OutstandingPulls.initial,
        since: since,
        wanted: {authorA},
        nowMs: 50,
      );
      final addedSecondButOlder = issue(
        addedFirstButNewer.state,
        since: since,
        wanted: {authorA},
        nowMs: 10,
      );

      final settled = answer(
        addedSecondButOlder.state,
        firstByAuthor: {authorA: 6},
        nowMs: 100,
      );

      expect(
        settled.answered,
        equals(const AnsweredPull(elapsedMs: 90, remaining: {})),
        reason: 'measured from the older request\'s own issue',
      );
      expect(
        settled.state.requests.keys,
        equals([addedFirstButNewer.request.id]),
        reason:
            'the older request is answered although it sits later in the '
            'map',
      );
    });

    test('a page carrying an author the continuation was carrying is the drain '
        'going on, without being required', () {
      final since = VersionVector({authorA: 2, authorB: 0});
      final continuation = issue(
        OutstandingPulls.initial,
        since: since,
        wanted: {authorB},
        carrying: {authorA},
        nowMs: 0,
      );

      expect(
        LegacyCorrelation.answers(continuation.request, {
          authorA: 3,
        }, VersionVector.empty),
        isTrue,
        reason: 'more of A continues the drain',
      );

      final moreOfA = answer(
        continuation.state,
        firstByAuthor: {authorA: 3},
        hasMore: true,
        nowMs: 10,
      );
      expect(
        moreOfA.answered!.remaining,
        equals({authorB}),
        reason: 'recognised; B is still owed to the next continuation',
      );
      expect(
        moreOfA.state.requests[continuation.request.id],
        isNull,
        reason: 'handed on, as any page with more to come',
      );

      final notCarried = issue(
        OutstandingPulls.initial,
        since: since,
        wanted: {authorB},
        nowMs: 0,
      );
      expect(
        LegacyCorrelation.answers(notCarried.request, {
          authorA: 3,
        }, VersionVector.empty),
        isFalse,
        reason:
            'the same page against a pull that neither wants nor carries A '
            'is a push',
      );
    });

    test(
      'a request past its deadline is no candidate, whatever the content',
      () {
        final expired = issue(
          OutstandingPulls.initial,
          since: VersionVector({authorA: 5}),
          wanted: {authorA},
          nowMs: 0,
        );
        final deadlineMs = OutstandingPullTracker.effectiveTimeout(
          expired.state,
        ).inMilliseconds;

        final settled = answer(
          expired.state,
          firstByAuthor: {authorA: 6},
          nowMs: deadlineMs + 1,
        );

        expect(
          settled.answered,
          isNull,
          reason:
              'a push that happens to fit a long-expired request answers '
              'nothing',
        );
        expect(
          settled.state,
          same(expired.state),
          reason: 'the expired request is left for the next issue to sweep',
        );
      },
    );

    test('a partial answer narrows what is still wanted and leaves the request '
        'outstanding', () {
      final issued = issue(
        OutstandingPulls.initial,
        since: VersionVector({authorA: 5, authorB: 2}),
        wanted: {authorA, authorB},
        nowMs: 0,
      );

      final settled = answer(
        issued.state,
        firstByAuthor: {authorA: 6},
        nowMs: 100,
      );

      expect(
        settled.answered!.remaining,
        equals({authorB}),
        reason: 'answered for A; B still to come',
      );
      expect(
        settled.state.requests[issued.request.id]!.wanted,
        equals({authorB}),
        reason: 'the request stays, narrowed to B',
      );
      expect(
        settled.state.sampleCount,
        equals(0),
        reason: 'the round trip is measured to the response that completes it',
      );
    });

    test('where the dialect cannot mark a page partial, a partial answer is '
        'the whole answer: the request is retired and the next round asks '
        'for the rest', () {
      final issued = issue(
        OutstandingPulls.initial,
        since: VersionVector({authorA: 5, authorB: 2}),
        wanted: {authorA, authorB},
        nowMs: 0,
      );

      final settled = answer(
        issued.state,
        firstByAuthor: {authorA: 6},
        marksPartialPages: false,
        nowMs: 100,
      );

      expect(
        settled.state.requests,
        isEmpty,
        reason: 'the peer will send nothing more for this request',
      );
      expect(
        settled.answered!.remaining,
        equals({authorB}),
        reason: 'what the answer left out is still truthfully reported',
      );
      expect(
        settled.state.sampleCount,
        equals(0),
        reason: 'shown to be the answer only in part, so not measured',
      );
    });

    test('narrowing a continuation keeps what the page before it was '
        'carrying', () {
      // The next page of a legacy drain is recognised by what the page before
      // it carried, so a narrowed continuation that forgot its carried author
      // would stop recognising its own drain.
      final continuation = issue(
        OutstandingPulls.initial,
        since: VersionVector({authorA: 2}),
        wanted: {authorB, authorC},
        carrying: {authorA},
        nowMs: 0,
      );

      final settled = answer(
        continuation.state,
        firstByAuthor: {authorB: 1},
        nowMs: 100,
      );

      expect(settled.answered!.remaining, equals({authorC}));
      expect(
        settled.state.requests[continuation.request.id]!.carrying,
        equals({authorA}),
      );
    });

    test('the completing answer retires the request and samples the round trip '
        'from its own issue', () {
      final issued = issue(
        OutstandingPulls.initial,
        since: VersionVector({authorA: 5, authorB: 2}),
        wanted: {authorA, authorB},
        nowMs: 0,
      );
      final partly = answer(
        issued.state,
        firstByAuthor: {authorA: 6},
        nowMs: 100,
      );

      final settled = answer(
        partly.state,
        firstByAuthor: {authorA: 6, authorB: 3},
        nowMs: 400,
      );

      expect(settled.answered!.remaining, isEmpty);
      expect(
        settled.answered!.elapsedMs,
        equals(400),
        reason:
            'measured from the request\'s own issue, not from the partial '
            'answer',
      );
      expect(settled.state.requests, isEmpty);
      expect(settled.state.sampleCount, equals(1));
    });

    test('a floor past what we hold accounts for an author without carrying '
        'it', () {
      final issued = issue(
        OutstandingPulls.initial,
        since: VersionVector({authorA: 5, authorB: 2}),
        wanted: {authorA, authorB},
        nowMs: 0,
      );

      final settled = answer(
        issued.state,
        firstByAuthor: {authorA: 6},
        floor: VersionVector({authorB: 9}),
        nowMs: 100,
      );

      expect(
        settled.answered!.remaining,
        isEmpty,
        reason: 'B\'s missing range is gone, says the sender',
      );
      expect(settled.state.requests, isEmpty);
    });

    test('a page with more to come hands the rest to the continuation instead '
        'of keeping the request', () {
      final issued = issue(
        OutstandingPulls.initial,
        since: VersionVector({authorA: 5, authorB: 2}),
        wanted: {authorA, authorB},
        nowMs: 0,
      );

      final settled = answer(
        issued.state,
        firstByAuthor: {authorA: 6},
        hasMore: true,
        nowMs: 100,
      );

      expect(
        settled.answered!.remaining,
        equals({authorB}),
        reason: 'what the continuation is still for',
      );
      expect(
        settled.state.requests,
        isEmpty,
        reason: 'the request does not stand twice',
      );
      expect(
        settled.state.sampleCount,
        equals(0),
        reason: 'authors are still owed; nothing is measured yet',
      );
    });

    test('answer returns a new value and leaves the one it was given '
        'untouched', () {
      final issued = issue(
        OutstandingPulls.initial,
        since: VersionVector({authorA: 5, authorB: 2}),
        wanted: {authorA, authorB},
        nowMs: 0,
      );
      final input = issued.state;

      final transitions = <OutstandingPulls Function(OutstandingPulls)>[
        (p) => answer(p, firstByAuthor: {authorA: 6}, nowMs: 100).state,
        (p) => answer(
          p,
          firstByAuthor: {authorA: 6, authorB: 3},
          nowMs: 100,
        ).state,
        (p) => answer(
          p,
          firstByAuthor: {authorA: 6},
          hasMore: true,
          nowMs: 100,
        ).state,
        (p) => answer(p, nowMs: 100).state,
      ];

      for (final transition in transitions) {
        final before = [
          for (final held in input.requests.values) {...held.wanted},
          input.requests.length,
          input.sampleCount,
        ];

        final after = transition(input);

        expect(
          [
            for (final held in input.requests.values) {...held.wanted},
            input.requests.length,
            input.sampleCount,
          ],
          equals(before),
          reason: 'the input value is untouched',
        );
        expect(after, isNot(same(input)));
      }
    });
  });
}
