import 'dart:async';
import 'dart:typed_data';

import 'package:gossip/src/shared/domain/interfaces/message_port.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/sync/domain/messages/delta_request.dart';
import 'package:gossip/src/sync/domain/messages/delta_response.dart';
import 'package:gossip/src/sync/domain/messages/digest_response.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';
import 'package:gossip/src/sync/domain/value_objects/request_id.dart';
import 'package:gossip/src/sync/domain/value_objects/stream_digest.dart';
import 'package:gossip/src/sync/infrastructure/sync_message_codec.dart';
import 'package:test/test.dart';

import 'gossip_engine_test_harness.dart';

/// How a delta response is tied to the pull that solicited it, and what
/// follows from the answer — the engine's half of request identity.
///
/// Two régimes are pinned side by side, and both are real in a deployment
/// mid-rollout. A peer that echoes the request it answers is settled by that
/// reference alone, whatever the response carries. A peer that has never
/// echoed one — a phone on a pin that predates identity — is judged by the
/// transitional content rule, whose cases are a mesh's: every peer writes,
/// so a peer's push of its own newest entry is the commonest response there
/// is, and it is indistinguishable by content from part of an answer.
void main() {
  final channelId = ChannelId('ch1');
  final streamId = StreamId('s1');
  final authorA = NodeId('author-a');
  final authorB = NodeId('author-b');
  final third = NodeId('author-c');

  LogEntry entryOf(NodeId author, int seq) => LogEntry(
    author: author,
    sequence: seq,
    timestamp: Hlc(1000 + seq, 0),
    payload: Uint8List.fromList([seq % 256]),
  );

  DigestResponse digestResponseOf(NodeId sender, VersionVector version) =>
      DigestResponse(
        sender: sender,
        digests: [
          ChannelDigest(
            channelId: channelId,
            streams: [StreamDigest(streamId: streamId, version: version)],
          ),
        ],
      );

  DeltaResponse responseOf(
    NodeId sender,
    List<LogEntry> entries, {
    bool hasMore = false,
    VersionVector floor = VersionVector.empty,
    RequestId? inReplyTo,
  }) => DeltaResponse(
    sender: sender,
    channelId: channelId,
    streamId: streamId,
    entries: entries,
    hasMore: hasMore,
    floor: floor,
    inReplyTo: inReplyTo,
  );

  group('a peer that has never named a request (transitional)', () {
    test('a racing push of an author the pull was not for leaves the pull in '
        'flight', () async {
      final h = GossipEngineTestHarness();
      final peer = h.addPeer('peer1');
      h.createChannel('ch1', streamIds: ['s1']);
      await h.entryRepository.appendAll(channelId, streamId, [
        entryOf(authorA, 1),
        entryOf(authorA, 2),
      ]);

      // The peer is ahead on authorB only; the pull is for that author.
      final pull = await h.armPull(
        peer,
        channelId: channelId,
        streamId: streamId,
        peerVersion: VersionVector({authorA: 2, authorB: 3}),
      );
      expect(pull.wanted, equals({authorB}));
      await h.timePort.advance(const Duration(milliseconds: 500));

      // The peer writes: its push begins one past what we hold of authorA.
      await h.engine.handleDeltaResponse(
        responseOf(peer.id, [entryOf(authorA, 3)]),
      );

      expect(h.errors, isEmpty);
      expect(
        (await h.entryRepository.getAll(
          channelId,
          streamId,
        )).where((e) => e.author == authorA).map((e) => e.sequence),
        equals([1, 2, 3]),
        reason: 'the push is merged as the push it is',
      );
      expect(
        h.engine.outstandingPullCount,
        1,
        reason: 'the pull for the author we are missing stays in flight',
      );
      expect(
        h.engine.effectivePendingRequestTimeout,
        const Duration(seconds: 8),
        reason: 'a push is no round-trip measurement',
      );

      // The real answer completes it and IS measured.
      await h.engine.handleDeltaResponse(
        responseOf(peer.id, [
          entryOf(authorB, 1),
          entryOf(authorB, 2),
          entryOf(authorB, 3),
        ]),
      );
      expect(h.engine.outstandingPullCount, 0);
      expect(
        h.engine.effectivePendingRequestTimeout,
        isNot(const Duration(seconds: 8)),
        reason: 'the answer is a round-trip sample',
      );
    });

    test(
      "a push of an author the pull WAS for answers that author only, and "
      'the true answer completes the pull and its floor is adopted',
      () async {
        final h = GossipEngineTestHarness();
        final peer = h.addPeer('peer1');
        h.createChannel('ch1', streamIds: ['s1']);
        await h.entryRepository.appendAll(channelId, streamId, [
          entryOf(authorA, 1),
          entryOf(authorA, 2),
        ]);

        final pull = await h.armPull(
          peer,
          channelId: channelId,
          streamId: streamId,
          peerVersion: VersionVector({authorA: 3, authorB: 3}),
        );
        expect(pull.wanted, equals({authorA, authorB}));

        // Exactly what the pull asked for authorA — and no more.
        await h.engine.handleDeltaResponse(
          responseOf(peer.id, [entryOf(authorA, 3)]),
        );
        expect(
          h.engine.outstandingPullCount,
          1,
          reason:
              'what the push accounted for is answered; the pull is still '
              'for the rest',
        );
        await h.timePort.advance(const Duration(milliseconds: 500));

        await h.engine.handleDeltaResponse(
          responseOf(peer.id, [
            entryOf(authorB, 1),
            entryOf(authorB, 2),
            entryOf(authorB, 3),
          ], floor: VersionVector({third: 4})),
        );

        expect(h.errors, isEmpty);
        expect(
          h.engine.outstandingPullCount,
          0,
          reason: 'the answer retires it',
        );
        expect(
          await h.entryRepository.getCompactionFloor(channelId, streamId),
          VersionVector({third: 4}),
          reason: "the answer's floor is adopted",
        );
      },
    );

    test('a paged answer completes when its second page carries only the '
        'other author', () async {
      final h = GossipEngineTestHarness();
      final peer = h.addPeer('peer1');
      h.createChannel('ch1', streamIds: ['s1']);

      await h.armPull(
        peer,
        channelId: channelId,
        streamId: streamId,
        peerVersion: VersionVector({authorA: 3, authorB: 3}),
      );

      // The first page carries authorA only, and there is more.
      await h.engine.handleDeltaResponse(
        responseOf(peer.id, [
          entryOf(authorA, 1),
          entryOf(authorA, 2),
          entryOf(authorA, 3),
        ], hasMore: true),
      );
      expect(
        h.engine.outstandingPullCount,
        1,
        reason: 'the drain is for what the page left owed',
      );
      await h.timePort.advance(const Duration(milliseconds: 500));

      // The next page carries authorB only, with a floor for a third author.
      await h.engine.handleDeltaResponse(
        responseOf(peer.id, [
          entryOf(authorB, 1),
          entryOf(authorB, 2),
          entryOf(authorB, 3),
        ], floor: VersionVector({third: 4})),
      );

      expect(h.errors, isEmpty);
      expect(
        h.engine.outstandingPullCount,
        0,
        reason: "the drain's answer retires it",
      );
      expect(
        await h.entryRepository.getCompactionFloor(channelId, streamId),
        VersionVector({third: 4}),
      );
      expect((await h.entryRepository.getAll(channelId, streamId)).length, 6);
    });

    test('a drain recognises a page that continues the author the previous '
        'page carried', () async {
      final h = GossipEngineTestHarness();
      final peer = h.addPeer('peer1');
      h.createChannel('ch1', streamIds: ['s1']);

      await h.armPull(
        peer,
        channelId: channelId,
        streamId: streamId,
        peerVersion: VersionVector({authorA: 4, authorB: 2}),
      );

      // Page 1: authorA's first two, more to come.
      await h.engine.handleDeltaResponse(
        responseOf(peer.id, [
          entryOf(authorA, 1),
          entryOf(authorA, 2),
        ], hasMore: true),
      );
      // Page 2: more of authorA, still more to come — neither an author
      // still owed nor a push.
      final afterPageTwo = await h.engine.handleDeltaResponse(
        responseOf(peer.id, [
          entryOf(authorA, 3),
          entryOf(authorA, 4),
        ], hasMore: true),
      );
      expect(
        afterPageTwo?.since[authorA],
        4,
        reason:
            'page 2 was the drain going on: a fresh continuation asks from '
            'where it left us',
      );
      // Page 3: authorB, the end, with a floor to prove it was taken as the
      // answer.
      await h.engine.handleDeltaResponse(
        responseOf(peer.id, [
          entryOf(authorB, 1),
          entryOf(authorB, 2),
        ], floor: VersionVector({third: 3})),
      );

      expect(h.errors, isEmpty);
      expect(
        h.engine.outstandingPullCount,
        0,
        reason: 'the drain completes: nothing outstanding',
      );
      expect(
        await h.entryRepository.getCompactionFloor(channelId, streamId),
        VersionVector({third: 3}),
      );
      expect((await h.entryRepository.getAll(channelId, streamId)).length, 6);
    });
  });

  group('a peer that names the request it answers', () {
    test('a response naming our request is its answer whatever it carries, '
        'and a hole in it is a diagnosed stall', () async {
      final h = GossipEngineTestHarness();
      final peer = h.addPeer('peer1');
      h.createChannel('ch1', streamIds: ['s1']);
      await h.entryRepository.appendAll(channelId, streamId, [
        entryOf(authorA, 1),
        entryOf(authorA, 2),
      ]);

      final pull = await h.armPull(
        peer,
        channelId: channelId,
        streamId: streamId,
        peerVersion: VersionVector({authorA: 20}),
      );

      // Begins at 11 — far above where the pull asked. Content alone would
      // read this as someone else's page; the reference says otherwise.
      await h.engine.handleDeltaResponse(
        responseOf(peer.id, [entryOf(authorA, 11)], inReplyTo: pull.id),
      );

      expect(
        h.engine.outstandingPullCount,
        0,
        reason: 'the request it names is retired',
      );
      expect(
        h.errors.where((e) => e.message.contains('sequence hole')),
        hasLength(1),
        reason: 'the hole is a diagnosed stall, not a misclassification',
      );
    });

    test('a response naming a request we do not hold is a push, and still '
        'says how the peer answers', () async {
      final h = GossipEngineTestHarness();
      final peer = h.addPeer('peer1');
      h.createChannel('ch1', streamIds: ['s1']);

      await h.engine.handleDeltaResponse(
        responseOf(
          peer.id,
          [entryOf(authorA, 1)],
          inReplyTo: RequestId('never-ours'),
          floor: VersionVector({third: 4}),
        ),
      );

      expect(h.engine.outstandingPullCount, 0);
      expect(
        await h.entryRepository.getCompactionFloor(channelId, streamId),
        VersionVector.empty,
        reason: 'a push cannot move our floor',
      );
      expect(
        h.logs.where((l) => l.contains('answers by reference')),
        hasLength(1),
      );
    });

    test('once a peer has named a request, a response naming none is a push '
        'even where a pull asked exactly there', () async {
      final h = GossipEngineTestHarness();
      final peer = h.addPeer('peer1');
      h.createChannel('ch1', streamIds: ['s1']);

      // First, the peer names a request: from now on it answers by
      // reference.
      final first = await h.armPull(
        peer,
        channelId: channelId,
        streamId: streamId,
        peerVersion: VersionVector({authorA: 1}),
      );
      await h.engine.handleDeltaResponse(
        responseOf(peer.id, [entryOf(authorA, 1)], inReplyTo: first.id),
      );

      final second = await h.armPull(
        peer,
        channelId: channelId,
        streamId: streamId,
        peerVersion: VersionVector({authorA: 3}),
      );
      expect(second.wanted, equals({authorA}));

      // Contiguous, beginning exactly where the pull asked — the racing
      // push the content rule had to reason about. It is simply a push.
      await h.engine.handleDeltaResponse(
        responseOf(peer.id, [
          entryOf(authorA, 2),
        ], floor: VersionVector({third: 4})),
      );

      expect(
        h.engine.outstandingPullCount,
        1,
        reason: 'the pull it named nothing about is still owed',
      );
      expect(
        await h.entryRepository.getCompactionFloor(channelId, streamId),
        VersionVector.empty,
        reason: 'a push cannot move our floor',
      );
    });

    test('how a peer answers is reported once per peer', () async {
      final h = GossipEngineTestHarness();
      final byReference = h.addPeer('peer-ref');
      final byContent = h.addPeer('peer-legacy');
      h.createChannel('ch1', streamIds: ['s1']);

      for (var round = 0; round < 2; round++) {
        final pull = await h.armPull(
          byReference,
          channelId: channelId,
          streamId: streamId,
          peerVersion: VersionVector({authorA: round + 1}),
        );
        await h.engine.handleDeltaResponse(
          responseOf(byReference.id, [
            entryOf(authorA, round + 1),
          ], inReplyTo: pull.id),
        );
      }
      for (var round = 0; round < 2; round++) {
        await h.armPull(
          byContent,
          channelId: channelId,
          streamId: streamId,
          peerVersion: VersionVector({authorB: round + 1}),
        );
        await h.engine.handleDeltaResponse(
          responseOf(byContent.id, [entryOf(authorB, round + 1)]),
        );
      }

      expect(
        h.logs.where((l) => l.contains('answers by reference')),
        hasLength(1),
      );
      expect(
        h.logs.where((l) => l.contains('correlated by content (legacy)')),
        hasLength(1),
      );
    });
  });

  group('on the wire', () {
    test('every pull names itself, every answer names the pull, and a push '
        'names none', () async {
      final port = _ScriptedPort();
      final h = GossipEngineTestHarness(messagePort: port);
      final peer = h.addPeer('peer1');
      h.createChannel('ch1', streamIds: ['s1']);
      h.startListening();
      h.engine.start();
      addTearDown(() async {
        h.engine.stop();
        h.stopListening();
        await port.close();
      });

      // A pull, planned from the peer's digest and put on the wire.
      await h.engine.performGossipRound();
      await h.flush(3);
      port.deliver(
        peer.id,
        h.codec.encode(digestResponseOf(peer.id, VersionVector({authorA: 2}))),
      );
      await h.flush(3);

      final pulls = port.decoded(h.codec).whereType<DeltaRequest>().toList();
      expect(pulls, hasLength(1));
      expect(
        pulls.single.requestId,
        isNotNull,
        reason: 'a pull on the wire names itself',
      );

      // The peer asks us for the same stream, naming its own request.
      port.deliver(
        peer.id,
        h.codec.encode(
          DeltaRequest(
            sender: peer.id,
            channelId: channelId,
            streamId: streamId,
            since: VersionVector.empty,
            requestId: RequestId('theirs-1'),
          ),
        ),
      );
      await h.flush(3);

      final answers = port.decoded(h.codec).whereType<DeltaResponse>().toList();
      expect(answers, hasLength(1));
      expect(
        answers.single.inReplyTo,
        equals(RequestId('theirs-1')),
        reason: 'an answer names the request it answers',
      );

      // A local write fans out as a push.
      h.engine.notifyLocalWrite(channelId, streamId, entryOf(h.localNode, 1));
      await h.timePort.advance(const Duration(seconds: 1));
      await h.flush(5);

      final pushes = port
          .decoded(h.codec)
          .whereType<DeltaResponse>()
          .skip(1)
          .toList();
      expect(pushes, isNotEmpty, reason: 'the write was pushed');
      expect(
        pushes.every((push) => push.inReplyTo == null),
        isTrue,
        reason: 'a push answers nobody, so it names no request',
      );
    });

    test('a continuation the transport refuses is taken back, and a pull to '
        'another stream of the same peer is untouched', () async {
      final port = _ScriptedPort();
      final h = GossipEngineTestHarness(messagePort: port);
      final peer = h.addPeer('peer1');
      h.createChannel('ch1', streamIds: ['s1', 's2']);
      h.startListening();
      h.engine.start();
      addTearDown(() async {
        h.engine.stop();
        h.stopListening();
        await port.close();
      });

      // Two pulls to one peer, for two streams.
      await h.armPull(
        peer,
        channelId: channelId,
        streamId: StreamId('s2'),
        peerVersion: VersionVector({authorA: 3}),
      );
      await h.armPull(
        peer,
        channelId: channelId,
        streamId: streamId,
        peerVersion: VersionVector({authorA: 3}),
      );
      expect(h.engine.outstandingPullCount, 2);

      // The answer claims more, and the transport refuses the drain.
      port.refuse = true;
      port.deliver(
        peer.id,
        h.codec.encode(
          responseOf(peer.id, [entryOf(authorA, 1)], hasMore: true),
        ),
      );
      await h.flush(5);

      expect(h.errors, isNotEmpty, reason: 'the refused drain is reported');
      expect(
        h.engine.outstandingPullCount,
        1,
        reason:
            'the drain is taken back by its own identity; the pull the peer '
            'did receive is still owed',
      );
    });
  });
}

/// A port whose incoming stream the test drives directly and whose sends are
/// recorded — and refused on demand, the shape of a transport that drops at
/// the moment a continuation should go out.
class _ScriptedPort implements MessagePort {
  final _incoming = StreamController<IncomingMessage>.broadcast();
  final List<Uint8List> sent = [];
  bool refuse = false;

  void deliver(NodeId from, Uint8List bytes) => _incoming.add(
    IncomingMessage(sender: from, bytes: bytes, receivedAt: DateTime.now()),
  );

  List<Object?> decoded(SyncMessageCodec codec) =>
      sent.map(codec.decode).toList();

  @override
  Future<void> send(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  }) async {
    if (refuse) throw StateError('transport down');
    sent.add(bytes);
  }

  @override
  Stream<IncomingMessage> get incoming => _incoming.stream;

  @override
  Future<void> close() => _incoming.close();

  @override
  int get totalPendingSendCount => 0;

  @override
  int pendingSendCount(NodeId peer) => 0;
}
