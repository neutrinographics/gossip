import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/sync/domain/aggregates/outstanding_pulls.dart';
import 'package:gossip/src/sync/domain/entities/pull_request.dart';
import 'package:gossip/src/sync/domain/services/legacy_correlation.dart';
import 'package:gossip/src/sync/domain/services/outstanding_pull_tracker.dart';
import 'package:gossip/src/sync/domain/value_objects/answered_pull.dart';
import 'package:gossip/src/sync/domain/value_objects/correlation.dart';
import 'package:gossip/src/sync/domain/value_objects/request_id.dart';
import 'package:test/test.dart';

/// Pulls as requests with identity, stated over values: every case starts
/// from [OutstandingPulls.initial] and threads the value one transition
/// answers into the next, and the clock arrives as the reading its caller
/// would have taken — which is what lets "8 seconds later" be a number here
/// instead of a clock to advance.
///
/// The gate, the adaptive deadline and the round-trip sampling pins are the
/// ones the per-key pull tracker this replaces carried, re-homed onto
/// identity-bearing requests. The content rule only a peer that has never
/// named a request is judged by has its own file; here it appears where a
/// response reaches it.
void main() {
  final peer = NodeId('peer-a');
  final peerB = NodeId('peer-b');
  final authorA = NodeId('author-a');
  final authorB = NodeId('author-b');
  final channel = ChannelId('c');
  final otherChannel = ChannelId('other');
  final stream = StreamId('s');
  final otherStream = StreamId('s2');

  /// What every pull here asks for: everything above what we hold of both
  /// authors.
  final since = VersionVector({authorA: 5, authorB: 2});

  /// A response that begins exactly where [since] asked, for both authors.
  final beginningWhereAsked = {authorA: 6, authorB: 3};

  ({OutstandingPulls state, PullRequest? request}) planned(
    OutstandingPulls pulls, {
    NodeId? toPeer,
    StreamId? forStream,
    required int nowMs,
  }) => OutstandingPullTracker.issueUnlessOutstanding(
    pulls,
    peer: toPeer ?? peer,
    channel: channel,
    stream: forStream ?? stream,
    since: since,
    wanted: {authorA, authorB},
    nowMs: nowMs,
  );

  ({OutstandingPulls state, PullRequest request}) issue(
    OutstandingPulls pulls, {
    NodeId? toPeer,
    StreamId? forStream,
    ChannelId? forChannel,
    Set<NodeId>? wanted,
    required int nowMs,
  }) => OutstandingPullTracker.issue(
    pulls,
    peer: toPeer ?? peer,
    channel: forChannel ?? channel,
    stream: forStream ?? stream,
    since: since,
    wanted: wanted ?? {authorA, authorB},
    nowMs: nowMs,
  );

  ({OutstandingPulls state, Correlated correlated}) answer(
    OutstandingPulls pulls, {
    RequestId? inReplyTo,
    NodeId? sender,
    Map<NodeId, int> firstByAuthor = const {},
    VersionVector floor = VersionVector.empty,
    bool hasMore = false,
    StreamId? forStream,
    required int nowMs,
  }) => OutstandingPullTracker.answer(
    pulls,
    sender: sender ?? peer,
    inReplyTo: inReplyTo,
    channel: channel,
    stream: forStream ?? stream,
    firstByAuthor: firstByAuthor,
    floor: floor,
    hasMore: hasMore,
    nowMs: nowMs,
  );

  bool outstanding(
    OutstandingPulls pulls, {
    NodeId? toPeer,
    StreamId? forStream,
    ChannelId? forChannel,
    required int nowMs,
  }) => OutstandingPullTracker.isOutstanding(
    pulls,
    peer: toPeer ?? peer,
    channel: forChannel ?? channel,
    stream: forStream ?? stream,
    nowMs: nowMs,
  );

  group('identity', () {
    test('an issued request records whom it asked, what it asked from, and '
        'what it was for', () {
      final issued = issue(
        OutstandingPulls.initial,
        wanted: {authorA},
        nowMs: 5,
      ).request;

      expect(issued.peer, equals(peer));
      expect(issued.channelId, equals(channel));
      expect(issued.streamId, equals(stream));
      expect(issued.since, equals(since));
      expect(issued.wanted, equals({authorA}));
      expect(issued.issuedAtMs, equals(5));
      expect(issued.carrying, isEmpty);
    });

    test('two pulls issued in one instant are two requests with ids of their '
        'own', () {
      final first = planned(OutstandingPulls.initial, nowMs: 0);
      final second = planned(first.state, toPeer: peerB, nowMs: 0);

      expect(first.request!.id, isNot(equals(second.request!.id)));
      expect(second.state.requests, hasLength(2));
    });

    test('a pull that is for no author and carries none is not a pull', () {
      expect(
        () => PullRequest(
          id: RequestId('x'),
          peer: peer,
          channelId: channel,
          streamId: stream,
          since: since,
          wanted: const {},
          issuedAtMs: 0,
        ),
        throwsArgumentError,
      );
      expect(
        PullRequest(
          id: RequestId('x'),
          peer: peer,
          channelId: channel,
          streamId: stream,
          since: since,
          wanted: const {},
          issuedAtMs: 0,
          carrying: {authorA},
        ).carrying,
        equals({authorA}),
      );
    });

    test('two requests to one key issued in the same instant are answered '
        'oldest first, in issue order', () {
      final first = issue(
        OutstandingPulls.initial,
        wanted: {authorA},
        nowMs: 0,
      );
      final second = issue(first.state, wanted: {authorA}, nowMs: 0);

      final answered = LegacyCorrelation.answer(
        second.state,
        sender: peer,
        channel: channel,
        stream: stream,
        firstByAuthor: {authorA: 6},
        floor: VersionVector.empty,
        hasMore: false,
        nowMs: 100,
      );

      expect(
        answered.state.requests.keys,
        equals([second.request.id]),
        reason: 'the first issued is answered; the second is untouched',
      );
    });
  });

  group('one pull planned at a time, as a query over the set', () {
    test('effectiveTimeout is 8 seconds before any sample', () {
      expect(
        OutstandingPullTracker.effectiveTimeout(OutstandingPulls.initial),
        equals(const Duration(seconds: 8)),
      );
    });

    test('a live request to the key bars planning another', () {
      final issued = planned(OutstandingPulls.initial, nowMs: 0);

      expect(outstanding(issued.state, nowMs: 7999), isTrue);
      final barred = planned(issued.state, nowMs: 7999);
      expect(barred.request, isNull);
      expect(
        barred.state,
        same(issued.state),
        reason: 'nothing is spent on a pull that was not issued',
      );
    });

    test('at exactly the deadline the request is expired, not live', () {
      final issued = planned(OutstandingPulls.initial, nowMs: 0);

      expect(
        outstanding(issued.state, nowMs: 8000),
        isFalse,
        reason:
            'the comparison is elapsed < effectiveTimeout, so at elapsed == '
            'effectiveTimeout the request no longer bars a pull',
      );
      expect(planned(issued.state, nowMs: 8000).request, isNotNull);
    });

    test('a stale request is evicted and the pull is issued', () {
      final issued = planned(OutstandingPulls.initial, nowMs: 0);

      final replaced = planned(issued.state, nowMs: 8001);

      expect(
        replaced.state.requests.keys,
        equals([replaced.request!.id]),
        reason: 'the one that expired is gone',
      );
    });

    test('a request to another peer or another stream is no bar', () {
      final issued = planned(OutstandingPulls.initial, nowMs: 0);

      expect(outstanding(issued.state, toPeer: peerB, nowMs: 0), isFalse);
      expect(
        outstanding(issued.state, forStream: otherStream, nowMs: 0),
        isFalse,
      );
      expect(planned(issued.state, toPeer: peerB, nowMs: 0).request, isNotNull);
      expect(
        planned(issued.state, forStream: otherStream, nowMs: 0).request,
        isNotNull,
      );
    });

    test('a request for another channel is no bar', () {
      final issued = issue(OutstandingPulls.initial, nowMs: 0);

      expect(
        outstanding(issued.state, forChannel: otherChannel, nowMs: 0),
        isFalse,
      );
    });

    test(
      'a continuation is owed rather than planned, so it is never gated',
      () {
        final plan = planned(OutstandingPulls.initial, nowMs: 0);
        final continuation = issue(plan.state, nowMs: 10);

        expect(
          continuation.state.requests,
          hasLength(2),
          reason: 'both are in flight, each by its own id',
        );
        expect(continuation.request.id, isNot(equals(plan.request!.id)));
      },
    );

    test('a continuation counts as outstanding, so no pull is planned beside '
        'it', () {
      final continuation = issue(OutstandingPulls.initial, nowMs: 0);

      expect(outstanding(continuation.state, nowMs: 0), isTrue);
      expect(planned(continuation.state, nowMs: 0).request, isNull);
    });
  });

  group('release', () {
    test('release takes back the request it names and leaves the other as it '
        'was', () {
      final plan = planned(OutstandingPulls.initial, nowMs: 0);
      final continuation = issue(plan.state, nowMs: 0);

      final released = OutstandingPullTracker.release(
        continuation.state,
        continuation.request.id,
      );

      expect(released.requests.keys, equals([plan.request!.id]));
      expect(outstanding(released, nowMs: 0), isTrue);
    });

    test('releasing an id we do not hold changes nothing', () {
      final issued = planned(OutstandingPulls.initial, nowMs: 0);

      final released = OutstandingPullTracker.release(
        issued.state,
        RequestId('nothing-of-ours'),
      );

      expect(released.requests.keys, equals([issued.request!.id]));
    });
  });

  group('outstandingCount', () {
    test('counts the requests in flight', () {
      expect(
        OutstandingPullTracker.outstandingCount(
          OutstandingPulls.initial,
          nowMs: 0,
        ),
        equals(0),
      );

      final one = planned(OutstandingPulls.initial, nowMs: 0);
      expect(
        OutstandingPullTracker.outstandingCount(one.state, nowMs: 0),
        equals(1),
      );

      final two = planned(one.state, toPeer: peerB, nowMs: 0);
      expect(
        OutstandingPullTracker.outstandingCount(two.state, nowMs: 0),
        equals(2),
      );
    });

    test('excludes requests past the deadline', () {
      final issued = planned(OutstandingPulls.initial, nowMs: 0);

      expect(
        OutstandingPullTracker.outstandingCount(issued.state, nowMs: 8001),
        equals(0),
        reason: 'a pull whose peer never answered is dead, not still syncing',
      );
    });

    test('excludes a request at exactly the deadline', () {
      final issued = planned(OutstandingPulls.initial, nowMs: 0);

      expect(
        OutstandingPullTracker.outstandingCount(issued.state, nowMs: 8000),
        equals(0),
      );
    });

    test('drops to zero once the request is answered', () {
      final issued = planned(OutstandingPulls.initial, nowMs: 0);
      final settled = answer(
        issued.state,
        inReplyTo: issued.request!.id,
        nowMs: 100,
      );

      expect(
        OutstandingPullTracker.outstandingCount(settled.state, nowMs: 100),
        equals(0),
      );
    });
  });

  group('a response that names a request', () {
    test('answers it, whatever it carries', () {
      final issued = planned(OutstandingPulls.initial, nowMs: 0);

      final settled = answer(
        issued.state,
        inReplyTo: issued.request!.id,
        firstByAuthor: {authorA: 99},
        nowMs: 20000,
      );

      expect(
        settled.correlated.answered,
        equals(const AnsweredPull(elapsedMs: 20000, remaining: {})),
        reason:
            'beginning above what was asked leaves a hole to record, not a '
            'pull still owed',
      );
      expect(settled.state.requests, isEmpty);
    });

    test('the round trip is measured from that request\'s own issue', () {
      final issued = planned(OutstandingPulls.initial, nowMs: 0);

      final settled = answer(
        issued.state,
        inReplyTo: issued.request!.id,
        nowMs: 20000,
      );

      // One 20s sample: SRTT 20s, RTTVAR 10s -> suggested 60s, clamped to 30s.
      expect(
        OutstandingPullTracker.effectiveTimeout(settled.state),
        equals(const Duration(seconds: 30)),
      );
    });

    test('answering by reference is what the engine learns about a peer, and '
        'only the first time', () {
      final plan = planned(OutstandingPulls.initial, nowMs: 0);
      final continuation = issue(plan.state, nowMs: 0);

      final learned = answer(
        continuation.state,
        inReplyTo: plan.request!.id,
        nowMs: 100,
      );
      expect(learned.correlated.learned, equals(Correlation.byReference));
      expect(learned.state.peers[peer], equals(Correlation.byReference));

      final again = answer(
        learned.state,
        inReplyTo: continuation.request.id,
        nowMs: 200,
      );
      expect(
        again.correlated.learned,
        isNull,
        reason: 'the fact is already known',
      );
      expect(
        again.state.requests,
        isEmpty,
        reason: 'both were answered, each by its own reference',
      );
    });

    test('naming a request we do not hold is a push, and still says how the '
        'peer answers', () {
      final issued = planned(OutstandingPulls.initial, nowMs: 0);

      final settled = answer(
        issued.state,
        inReplyTo: RequestId('nothing-of-ours'),
        firstByAuthor: beginningWhereAsked,
        nowMs: 100,
      );

      expect(settled.correlated.answered, isNull);
      expect(settled.correlated.learned, equals(Correlation.byReference));
      expect(
        settled.state.requests.keys,
        equals([issued.request!.id]),
        reason: 'the pull is still owed',
      );
      expect(
        settled.state.sampleCount,
        equals(0),
        reason: 'a push is no round trip',
      );
    });

    test('a reference to a request that went to another peer answers nothing '
        'and says nothing', () {
      final issued = planned(OutstandingPulls.initial, nowMs: 0);

      final settled = answer(
        issued.state,
        inReplyTo: issued.request!.id,
        sender: peerB,
        nowMs: 100,
      );

      expect(settled.correlated.answered, isNull);
      expect(settled.correlated.learned, isNull);
      expect(settled.state, same(issued.state));
    });

    test('a reference from the right peer for another stream is inert', () {
      final issued = planned(OutstandingPulls.initial, nowMs: 0);

      final elsewhere = answer(
        issued.state,
        inReplyTo: issued.request!.id,
        forStream: otherStream,
        firstByAuthor: {authorA: 6},
        nowMs: 100,
      );

      expect(
        elsewhere.correlated.answered,
        isNull,
        reason: 'the request asked about another stream',
      );
      expect(
        elsewhere.correlated.learned,
        isNull,
        reason: 'a misaddressed echo teaches nothing',
      );
      expect(elsewhere.state, same(issued.state));
    });

    test('once a peer has answered by reference, a response naming nothing is '
        'a push', () {
      final plan = planned(OutstandingPulls.initial, nowMs: 0);
      final correlating = answer(
        plan.state,
        inReplyTo: plan.request!.id,
        nowMs: 100,
      ).state;
      final owed = issue(correlating, nowMs: 200);

      final push = answer(
        owed.state,
        firstByAuthor: beginningWhereAsked,
        nowMs: 300,
      );

      expect(
        push.correlated.answered,
        isNull,
        reason: 'beginning exactly where a pull asked makes it no answer',
      );
      expect(push.correlated.learned, isNull);
      expect(push.state, same(owed.state));
    });
  });

  group('a peer that has never named a request', () {
    test('is answered by what the response carries', () {
      final issued = planned(OutstandingPulls.initial, nowMs: 0);

      final settled = answer(
        issued.state,
        firstByAuthor: beginningWhereAsked,
        nowMs: 100,
      );

      expect(
        settled.correlated.answered,
        equals(const AnsweredPull(elapsedMs: 100, remaining: {})),
      );
      expect(settled.state.requests, isEmpty);
      expect(settled.state.sampleCount, equals(1));
    });

    test('answering by content is learned about a peer once', () {
      final issued = planned(OutstandingPulls.initial, nowMs: 0);

      final first = answer(
        issued.state,
        firstByAuthor: beginningWhereAsked,
        nowMs: 100,
      );
      expect(first.correlated.learned, equals(Correlation.legacy));
      expect(first.state.peers[peer], equals(Correlation.legacy));

      final next = issue(first.state, nowMs: 200);
      final again = answer(
        next.state,
        firstByAuthor: beginningWhereAsked,
        nowMs: 300,
      );
      expect(
        again.correlated.answered,
        equals(const AnsweredPull(elapsedMs: 100, remaining: {})),
      );
      expect(
        again.correlated.learned,
        isNull,
        reason: 'the fact is already known',
      );
    });
  });

  group('the round trip a response teaches', () {
    test('is the elapsed reading, measured from the request\'s own issue', () {
      final issued = planned(OutstandingPulls.initial, nowMs: 0);

      final settled = answer(
        issued.state,
        inReplyTo: issued.request!.id,
        nowMs: 500,
      );

      expect(settled.correlated.answered!.elapsedMs, equals(500));
    });

    test('a reading of zero measures a clock, not a transport, so it teaches '
        'nothing', () {
      final issued = planned(OutstandingPulls.initial, nowMs: 0);

      final settled = answer(
        issued.state,
        inReplyTo: issued.request!.id,
        nowMs: 0,
      );

      expect(settled.correlated.answered!.elapsedMs, equals(0));
      expect(settled.state.sampleCount, equals(0));
      expect(
        OutstandingPullTracker.effectiveTimeout(settled.state),
        equals(const Duration(seconds: 8)),
        reason: 'the cold default is not shifted by a spurious 0ms sample',
      );
    });

    test('a positive reading moves the deadline off the cold default', () {
      final issued = planned(OutstandingPulls.initial, nowMs: 0);

      final settled = answer(
        issued.state,
        inReplyTo: issued.request!.id,
        nowMs: 6000,
      );

      expect(
        OutstandingPullTracker.effectiveTimeout(settled.state),
        greaterThan(const Duration(seconds: 6)),
        reason:
            'the deadline must exceed the observed 6s round trip so a page '
            'in flight is never re-requested mid-transmission',
      );
      expect(
        OutstandingPullTracker.effectiveTimeout(settled.state),
        isNot(equals(const Duration(seconds: 8))),
      );
    });

    test('a very fast round trip is clamped up to the 2s floor before it '
        'reaches the estimator', () {
      final issued = planned(OutstandingPulls.initial, nowMs: 0);

      // 1ms round trip: fed to the estimator unclamped, the first-sample
      // rule would set SRTT 1ms / RTTVAR 0.5ms, suggesting 3ms and clamped
      // to the 2s floor only at the very end. Clamping the SAMPLE to 2s
      // first yields SRTT 2s / RTTVAR 1s, suggesting 6s — a different,
      // larger result that only happens if the pre-estimator clamp ran.
      final settled = answer(
        issued.state,
        inReplyTo: issued.request!.id,
        nowMs: 1,
      );

      expect(
        OutstandingPullTracker.effectiveTimeout(settled.state),
        equals(const Duration(seconds: 6)),
      );
    });

    test('an extreme round trip is clamped down to the 30s ceiling', () {
      final issued = planned(OutstandingPulls.initial, nowMs: 0);

      final settled = answer(
        issued.state,
        inReplyTo: issued.request!.id,
        nowMs: 100000,
      );

      expect(
        OutstandingPullTracker.effectiveTimeout(settled.state),
        equals(const Duration(seconds: 30)),
      );
    });
  });

  group('forgetting', () {
    test('the id sequence survives every clear, so an id is never minted '
        'twice', () {
      final issued = issue(OutstandingPulls.initial, nowMs: 0);
      final before = issued.request.id;

      final cleared = [
        OutstandingPullTracker.clearAll(issued.state),
        OutstandingPullTracker.clearForPeer(issued.state, peer),
        OutstandingPullTracker.clearForChannel(issued.state, channel),
      ];

      for (final pulls in cleared) {
        expect(
          issue(pulls, nowMs: 0).request.id,
          isNot(equals(before)),
          reason: 'minted in the same instant after a clear, still a new id',
        );
      }
    });

    test('a stop clears what is outstanding and keeps what was measured', () {
      final issued = planned(OutstandingPulls.initial, nowMs: 0);
      final measured = answer(
        issued.state,
        inReplyTo: issued.request!.id,
        nowMs: 20000,
      ).state;
      final owed = issue(measured, nowMs: 20000).state;

      final cleared = OutstandingPullTracker.clearAll(owed);

      expect(cleared.requests, isEmpty);
      expect(
        cleared.peers,
        equals(owed.peers),
        reason: 'a stop is not a restart',
      );
      expect(cleared.rtt, equals(owed.rtt));
      expect(cleared.sampleCount, equals(owed.sampleCount));
    });

    test('a peer removal forgets that peer\'s pulls and how it answered '
        'them', () {
      final mine = planned(OutstandingPulls.initial, nowMs: 0);
      final correlating = answer(
        mine.state,
        inReplyTo: mine.request!.id,
        nowMs: 100,
      ).state;
      final theirs = issue(correlating, toPeer: peerB, nowMs: 100);

      final cleared = OutstandingPullTracker.clearForPeer(theirs.state, peer);

      expect(cleared.requests.keys, equals([theirs.request.id]));
      expect(
        cleared.peers[peer],
        isNull,
        reason: 'its next referenced answer teaches us again',
      );
    });

    test(
      'a channel removal clears that channel\'s pulls across every peer',
      () {
        final mine = issue(OutstandingPulls.initial, nowMs: 0);
        final theirs = issue(mine.state, toPeer: peerB, nowMs: 0);
        final elsewhere = issue(
          theirs.state,
          forChannel: otherChannel,
          nowMs: 0,
        );

        final cleared = OutstandingPullTracker.clearForChannel(
          elsewhere.state,
          channel,
        );

        expect(cleared.requests.keys, equals([elsewhere.request.id]));
      },
    );
  });

  test('every transition answers a new value and leaves the one it was given '
      'alone', () {
    final outstandingOne = planned(OutstandingPulls.initial, nowMs: 0);
    final one = outstandingOne.state;
    final request = outstandingOne.request!;

    final transitions =
        <(OutstandingPulls, OutstandingPulls Function(OutstandingPulls))>[
          (OutstandingPulls.initial, (p) => planned(p, nowMs: 0).state),
          (OutstandingPulls.initial, (p) => issue(p, nowMs: 0).state),
          (one, (p) => OutstandingPullTracker.release(p, request.id)),
          (one, (p) => answer(p, inReplyTo: request.id, nowMs: 100).state),
          (
            one,
            (p) =>
                answer(p, firstByAuthor: beginningWhereAsked, nowMs: 100).state,
          ),
          (one, OutstandingPullTracker.clearAll),
          (one, (p) => OutstandingPullTracker.clearForPeer(p, peer)),
          (one, (p) => OutstandingPullTracker.clearForChannel(p, channel)),
        ];

    for (final (input, transition) in transitions) {
      final before = snapshot(input);

      final after = transition(input);

      expect(
        snapshot(input),
        equals(before),
        reason: 'the input value is untouched',
      );
      expect(after, isNot(same(input)));
      expect(
        snapshot(after),
        isNot(equals(before)),
        reason: 'a transition answers a value of its own',
      );
    }
  });
}

/// Everything a reader can observe of [pulls], flattened so two readings of
/// one value compare as a whole — the aggregate carries no equality of its
/// own, because no production caller ever compares two pull sets.
Object snapshot(OutstandingPulls pulls) => [
  for (final request in pulls.requests.values)
    [
      request.id.value,
      request.peer,
      request.channelId,
      request.streamId,
      request.since,
      {...request.wanted},
      request.issuedAtMs,
      {...request.carrying},
    ],
  {for (final entry in pulls.peers.entries) entry.key.value: entry.value.name},
  pulls.rtt,
  pulls.sampleCount,
  pulls.nextSequence,
];
