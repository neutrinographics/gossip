import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:gossip/src/sync/domain/aggregates/channel_aggregate.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';
import 'package:gossip/src/sync/domain/value_objects/stream_digest.dart';

import 'gossip_engine_test_harness.dart';

/// WIRE4-5: a converged DigestResponse used to echo back version vectors
/// the requester provably already had — the single largest pure-redundancy
/// item on the idle wire. Pairs the requester dominates are now omitted.
void main() {
  group('DigestResponse dominance filter', () {
    test('omits streams the requester already dominates', () async {
      final h = GossipEngineTestHarness();
      final channelId = ChannelId('ch');
      final streamId = StreamId('s');
      final channel = await h.createChannelWithStream(channelId, streamId);
      // Local store: entry seq 1 by us -> our VV = {local: 1}.
      await h.appendLocalEntry(channelId, streamId, sequence: 1);

      // Requester advertises {local: 1} — it has everything we have.
      final request = DigestRequest(
        sender: h.addPeer('peer1').id,
        digests: [
          ChannelDigest(
            channelId: channelId,
            streams: [
              StreamDigest(
                streamId: streamId,
                version: VersionVector({h.localNode: 1}),
              ),
            ],
          ),
        ],
      );

      final response = await h.engine.handleDigestRequest(request, [channel]);

      expect(
        response.digests,
        isEmpty,
        reason:
            'the requester dominates us: echoing our vector back '
            'is pure redundancy',
      );
    });

    test('includes streams where the requester is behind', () async {
      final h = GossipEngineTestHarness();
      final channelId = ChannelId('ch');
      final streamId = StreamId('s');
      final channel = await h.createChannelWithStream(channelId, streamId);
      await h.appendLocalEntry(channelId, streamId, sequence: 1);
      await h.appendLocalEntry(channelId, streamId, sequence: 2);

      // Requester only has seq 1 — it must be told about our state.
      final request = DigestRequest(
        sender: h.addPeer('peer1').id,
        digests: [
          ChannelDigest(
            channelId: channelId,
            streams: [
              StreamDigest(
                streamId: streamId,
                version: VersionVector({h.localNode: 1}),
              ),
            ],
          ),
        ],
      );

      final response = await h.engine.handleDigestRequest(request, [channel]);

      expect(response.digests, hasLength(1));
      expect(response.digests.single.streams.single.version[h.localNode], 2);
    });
  });

  /// The dominance filter compares the requester's advertised version
  /// against our own — which [handleDigestRequest] always computes from
  /// [EntryRepository.getVersionVector] (the monotonic high-water mark),
  /// never from physical storage. Compaction prunes storage but never
  /// regresses that mark, so a requester below our compaction floor is
  /// necessarily also below our reported version and can never dominate it
  /// — the filter must never mistake "we pruned some of our own history"
  /// for "the requester already has it".
  group('DigestResponse dominance filter × compaction floor', () {
    final channelId = ChannelId('ch');
    final streamId = StreamId('s');
    final author = NodeId('author-a');

    LogEntry entryOf(int seq) => LogEntry(
      author: author,
      sequence: seq,
      timestamp: Hlc(1000 + seq, 0),
      payload: Uint8List.fromList([seq]),
    );

    /// Harness with a stream holding seq 1..5 by [author], compacted so
    /// 1..3 are pruned (floor 3, survivors 4..5). The stream's reported
    /// version stays {author: 5} regardless — the high-water mark, not the
    /// physical remainder.
    Future<(GossipEngineTestHarness, ChannelAggregate)>
    compactedHarness() async {
      final h = GossipEngineTestHarness();
      final channel = h.createChannel('ch', streamIds: ['s']);
      for (var i = 1; i <= 5; i++) {
        await h.entryRepository.append(channelId, streamId, entryOf(i));
      }
      final all = await h.entryRepository.getAll(channelId, streamId);
      await h.entryRepository.removeEntries(
        channelId,
        streamId,
        all.take(3).map((e) => e.id).toList(),
      );
      return (h, channel);
    }

    DigestRequest requestFrom(String peerName, VersionVector version) =>
        DigestRequest(
          sender: NodeId(peerName),
          digests: [
            ChannelDigest(
              channelId: channelId,
              streams: [StreamDigest(streamId: streamId, version: version)],
            ),
          ],
        );

    test('a requester below the compaction floor is still advertised — the '
        'dominance filter never hides a floored responder', () async {
      final (h, channel) = await compactedHarness();
      h.addPeer('peer1');

      // Requester only knows about seq 1 — below the floor (3).
      final request = requestFrom('peer1', VersionVector({author: 1}));
      final response = await h.engine.handleDigestRequest(request, [channel]);

      expect(
        response.digests,
        hasLength(1),
        reason:
            'a below-floor requester still needs the stream '
            'advertised so it can pull and receive the floor + survivors '
            '— hiding it here would strand it forever',
      );
      expect(
        response.digests.single.streams.single.version[author],
        equals(5),
        reason:
            'the advertised version is the high-water mark, not the '
            'physical remainder',
      );
    });

    test('a requester exactly at the post-compaction high-water mark is '
        'omitted — converged, nothing left to pull', () async {
      final (h, channel) = await compactedHarness();
      h.addPeer('peer1');

      // Requester already claims seq 5 — dominates our vector exactly.
      final request = requestFrom('peer1', VersionVector({author: 5}));
      final response = await h.engine.handleDigestRequest(request, [channel]);

      expect(
        response.digests,
        isEmpty,
        reason:
            'the requester dominates us: echoing the vector back is '
            'pure redundancy, regardless of the stream ever having been '
            'compacted',
      );
    });
  });
}
