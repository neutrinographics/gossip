import 'dart:typed_data';

import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/version_vector.dart';
import 'package:gossip/src/protocol/messages/delta_request.dart';
import 'package:gossip/src/protocol/messages/delta_response.dart';
import 'package:test/test.dart';

import 'gossip_engine_test_harness.dart';

/// COR3-2: the protocol layer must not ingest or serve data for channels
/// and streams this node does not have. Without the guard, a reactive push
/// for a channel we never joined is silently stored (unbounded phantom
/// storage, never advertised, never compacted) and served back to anyone
/// who asks — crossing the membership boundary the product is built on.
void main() {
  final ourChannel = ChannelId('ours');
  final otherChannel = ChannelId('not-ours');
  final streamId = StreamId('s1');
  final author = NodeId('author-a');

  LogEntry entryOf(int seq) => LogEntry(
    author: author,
    sequence: seq,
    timestamp: Hlc(1000 + seq, 0),
    payload: Uint8List.fromList([seq]),
  );

  group('ingestion scope', () {
    test('a delta response for a channel we do not have is not stored',
        () async {
      final h = GossipEngineTestHarness();
      final peer = h.addPeer('peer1');
      h.createChannel('ours', streamIds: ['s1']);

      await h.engine.handleDeltaResponse(
        DeltaResponse(
          sender: peer.id,
          channelId: otherChannel,
          streamId: streamId,
          entries: [entryOf(1), entryOf(2)],
        ),
      );

      expect(
        await h.entryRepository.entryCount(otherChannel, streamId),
        equals(0),
        reason: 'a non-member must not accumulate phantom channel data',
      );
      expect(h.mergedEntries, isEmpty);
      expect(h.errors, isEmpty, reason: 'routine under partial overlap');
    });

    test(
      'a delta response for a stream we have not created is not stored',
      () async {
        final h = GossipEngineTestHarness();
        final peer = h.addPeer('peer1');
        h.createChannel('ours', streamIds: ['s1']);

        await h.engine.handleDeltaResponse(
          DeltaResponse(
            sender: peer.id,
            channelId: ourChannel,
            streamId: StreamId('never-created'),
            entries: [entryOf(1)],
          ),
        );

        expect(
          await h.entryRepository.entryCount(
            ourChannel,
            StreamId('never-created'),
          ),
          equals(0),
          reason: 'stream creation is a local decision (ADR)',
        );
        expect(h.mergedEntries, isEmpty);
        expect(h.errors, isEmpty);
      },
    );

    test('a delta response for our channel and stream still merges',
        () async {
      final h = GossipEngineTestHarness();
      final peer = h.addPeer('peer1');
      h.createChannel('ours', streamIds: ['s1']);

      await h.engine.handleDeltaResponse(
        DeltaResponse(
          sender: peer.id,
          channelId: ourChannel,
          streamId: streamId,
          entries: [entryOf(1)],
        ),
      );

      expect(await h.entryRepository.entryCount(ourChannel, streamId), 1);
      expect(h.mergedEntries, hasLength(1));
    });
  });

  group('serving scope', () {
    test(
      'a delta request for a channel we do not have gets an empty response',
      () async {
        final h = GossipEngineTestHarness();
        final peer = h.addPeer('peer1');
        h.createChannel('ours', streamIds: ['s1']);

        // Simulate leftover phantom data (e.g. persisted by a version
        // without the ingestion guard): it must not be served.
        await h.entryRepository.append(otherChannel, streamId, entryOf(1));

        final response = await h.engine.handleDeltaRequest(
          DeltaRequest(
            sender: peer.id,
            channelId: otherChannel,
            streamId: streamId,
            since: VersionVector.empty,
          ),
        );

        expect(
          response.entries,
          isEmpty,
          reason: 'we are not a member of this channel',
        );
        expect(response.hasMore, isFalse);
      },
    );
  });
}
