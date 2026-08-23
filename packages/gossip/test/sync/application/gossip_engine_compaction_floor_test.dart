import 'dart:typed_data';

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
import 'package:gossip/src/sync/domain/value_objects/stream_digest.dart';
import 'package:test/test.dart';

import 'gossip_engine_test_harness.dart';

/// COR3-1: compaction-aware sync. A responder that compacted entries below
/// a requester's position reports its per-author floor in the
/// DeltaResponse; the requester adopts the floor as truncated history so
/// the surviving entries merge contiguously — instead of being dropped by
/// the contiguity guard forever while full pages are futilely re-sent
/// every round.
void main() {
  final channelId = ChannelId('ch1');
  final streamId = StreamId('s1');
  final authorA = NodeId('author-a');

  LogEntry entryOf(NodeId author, int seq, int tsMs) => LogEntry(
    author: author,
    sequence: seq,
    timestamp: Hlc(tsMs, 0),
    payload: Uint8List.fromList([seq]),
  );

  /// Harness holding seqs 1..upTo by [authorA], with 1..pruned compacted.
  Future<GossipEngineTestHarness> compactedHarness({
    required int upTo,
    required int pruned,
  }) async {
    final h = GossipEngineTestHarness();
    h.createChannel('ch1', streamIds: ['s1']);
    for (var i = 1; i <= upTo; i++) {
      await h.entryRepository.append(
        channelId,
        streamId,
        entryOf(authorA, i, 1000 + i),
      );
    }
    final all = await h.entryRepository.getAll(channelId, streamId);
    await h.entryRepository.removeEntries(
      channelId,
      streamId,
      all.take(pruned).map((e) => e.id).toList(),
    );
    return h;
  }

  group('responder side', () {
    test(
      'a request from below the floor gets the floor and the survivors',
      () async {
        final h = await compactedHarness(upTo: 5, pruned: 3);
        final requester = h.addPeer('joiner');

        // A fresh joiner asks for everything.
        final response = await h.engine.handleDeltaRequest(
          DeltaRequest(
            sender: requester.id,
            channelId: channelId,
            streamId: streamId,
            since: VersionVector.empty,
          ),
        );

        expect(response.entries.map((e) => e.sequence), equals([4, 5]));
        expect(
          response.floor[authorA],
          equals(3),
          reason:
              'the requester must learn that 1..3 are unobtainable here, '
              'or it will drop the survivors and re-request forever',
        );
      },
    );

    test('a request at or above the floor gets no floor', () async {
      final h = await compactedHarness(upTo: 5, pruned: 3);
      final requester = h.addPeer('peer');

      final response = await h.engine.handleDeltaRequest(
        DeltaRequest(
          sender: requester.id,
          channelId: channelId,
          streamId: streamId,
          since: VersionVector({authorA: 3}),
        ),
      );

      expect(response.entries.map((e) => e.sequence), equals([4, 5]));
      expect(response.floor.entries, isEmpty);
    });
  });

  group('requester side', () {
    DigestResponse digestFrom(NodeId peerId) => DigestResponse(
      sender: peerId,
      digests: [
        ChannelDigest(
          channelId: channelId,
          streams: [
            StreamDigest(
              streamId: streamId,
              version: VersionVector({authorA: 12}),
            ),
          ],
        ),
      ],
    );

    test(
      'a solicited response with a floor is adopted: survivors merge, '
      'no error, range never re-requested',
      () async {
        final h = GossipEngineTestHarness();
        final peer = h.addPeer('peer1');
        h.createChannel('ch1', streamIds: ['s1']);

        // Arm the pending pull (the response below is solicited).
        await h.engine.handleDigestResponse(digestFrom(peer.id));

        await h.engine.handleDeltaResponse(
          DeltaResponse(
            sender: peer.id,
            channelId: channelId,
            streamId: streamId,
            entries: [entryOf(authorA, 11, 2011), entryOf(authorA, 12, 2012)],
            floor: VersionVector({authorA: 10}),
          ),
        );

        expect(
          h.mergedEntries,
          hasLength(1),
          reason: 'the survivors must merge, not be dropped as gapped',
        );
        expect(
          h.mergedEntries.single.entries.map((e) => e.sequence),
          equals([11, 12]),
        );
        expect(h.errors, isEmpty);

        final vv = await h.entryRepository.getVersionVector(
          channelId,
          streamId,
        );
        expect(
          vv[authorA],
          equals(12),
          reason: 'adopted floor + merged entries: 1..10 never re-requested',
        );
        final floor = await h.entryRepository.getCompactionFloor(
          channelId,
          streamId,
        );
        expect(
          floor[authorA],
          equals(10),
          reason: 'the adopted floor propagates when we serve others',
        );
      },
    );

    test('an UNSOLICITED response cannot move our floor', () async {
      final h = GossipEngineTestHarness();
      final peer = h.addPeer('peer1');
      h.createChannel('ch1', streamIds: ['s1']);

      // No pending pull: an unsolicited push claiming a floor must not be
      // able to make us skip history (we never asked this peer).
      await h.engine.handleDeltaResponse(
        DeltaResponse(
          sender: peer.id,
          channelId: channelId,
          streamId: streamId,
          entries: [entryOf(authorA, 11, 2011)],
          floor: VersionVector({authorA: 10}),
        ),
      );

      expect(h.mergedEntries, isEmpty);
      final floor = await h.entryRepository.getCompactionFloor(
        channelId,
        streamId,
      );
      expect(floor.entries, isEmpty, reason: 'floor adoption is opt-in');
      final vv = await h.entryRepository.getVersionVector(channelId, streamId);
      expect(vv[authorA], equals(0));
    });

    test('a repeated identical floored response is idempotent', () async {
      final h = GossipEngineTestHarness();
      final peer = h.addPeer('peer1');
      h.createChannel('ch1', streamIds: ['s1']);

      DeltaResponse floored() => DeltaResponse(
        sender: peer.id,
        channelId: channelId,
        streamId: streamId,
        entries: [entryOf(authorA, 11, 2011)],
        floor: VersionVector({authorA: 10}),
      );

      await h.engine.handleDigestResponse(digestFrom(peer.id));
      await h.engine.handleDeltaResponse(floored());
      await h.engine.handleDigestResponse(digestFrom(peer.id));
      await h.engine.handleDeltaResponse(floored());

      expect(h.mergedEntries, hasLength(1), reason: 'merged exactly once');
      expect(h.errors, isEmpty);
    });
  });

  group('stale self-authorship (COR3-4)', () {
    test(
      'a peer claiming sequences under OUR authorship beyond our own '
      'high-water mark raises our sequence floor',
      () async {
        final h = GossipEngineTestHarness();
        final peer = h.addPeer('peer1');
        h.createChannel('ch1', streamIds: ['s1']);

        // The peer's digest says WE authored up to seq 7 — but our store
        // says 0: this channel/stream identity was removed and recreated
        // (or our storage was reset). Appending from seq 1 again would
        // collide with our stale history on every peer: the new entries
        // would be permanently invisible (their VVs already cover the
        // numbers) and divergent (two payloads for one entry identity).
        await h.engine.handleDigestResponse(
          DigestResponse(
            sender: peer.id,
            digests: [
              ChannelDigest(
                channelId: channelId,
                streams: [
                  StreamDigest(
                    streamId: streamId,
                    version: VersionVector({h.localNode: 7}),
                  ),
                ],
              ),
            ],
          ),
        );

        expect(
          await h.entryRepository.latestSequence(
            channelId,
            streamId,
            h.localNode,
          ),
          equals(7),
          reason: 'the next local append must allocate seq 8, not seq 1',
        );
      },
    );
  });

  group('end to end', () {
    test(
      'late joiner converges with a compacted responder (the COR3-1 '
      'lockout scenario)',
      () async {
        // Responder: holds 4..5 after compacting 1..3.
        final responder = await compactedHarness(upTo: 5, pruned: 3);
        responder.addPeer('joiner');

        // Joiner-side harness shares nothing; simulate its pull through
        // the responder's public handlers.
        final joinerH = GossipEngineTestHarness(localName: 'joiner');
        final resp = joinerH.addPeer('local');
        joinerH.createChannel('ch1', streamIds: ['s1']);

        // Joiner learns the responder is ahead and pulls from zero.
        await joinerH.engine.handleDigestResponse(
          DigestResponse(
            sender: resp.id,
            digests: [
              ChannelDigest(
                channelId: channelId,
                streams: [
                  StreamDigest(
                    streamId: streamId,
                    version: VersionVector({authorA: 5}),
                  ),
                ],
              ),
            ],
          ),
        );
        final response = await responder.engine.handleDeltaRequest(
          DeltaRequest(
            sender: joinerH.localNode,
            channelId: channelId,
            streamId: streamId,
            since: VersionVector.empty,
          ),
        );
        // Deliver the responder's answer (rewritten to the joiner's view
        // of the sender).
        await joinerH.engine.handleDeltaResponse(
          DeltaResponse(
            sender: resp.id,
            channelId: response.channelId,
            streamId: response.streamId,
            entries: response.entries,
            hasMore: response.hasMore,
            floor: response.floor,
          ),
        );

        final all = await joinerH.entryRepository.getAll(channelId, streamId);
        expect(
          all.map((e) => e.sequence),
          equals([4, 5]),
          reason: 'the joiner must converge on the surviving history',
        );
        final vv = await joinerH.entryRepository.getVersionVector(
          channelId,
          streamId,
        );
        expect(
          vv[authorA],
          equals(5),
          reason: 'no further pull would be issued — the lockout is gone',
        );
        expect(joinerH.errors, isEmpty);
      },
    );
  });
}
