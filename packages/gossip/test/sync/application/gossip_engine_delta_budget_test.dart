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

void main() {
  final channelId = ChannelId('ch1');
  final streamId = StreamId('s1');

  LogEntry entryOf(String author, int seq, int tsMs, int payloadBytes) {
    return LogEntry(
      author: NodeId(author),
      sequence: seq,
      timestamp: Hlc(tsMs, 0),
      payload: Uint8List.fromList(List.filled(payloadBytes, 0x42)),
    );
  }

  group('GossipEngine delta size budget', () {
    test(
      'handleDeltaRequest caps the encoded DeltaResponse under the budget',
      () async {
        final h = GossipEngineTestHarness(
          maxDeltaResponseBytes: 30 * 1024,
        );
        h.createChannel('ch1', streamIds: ['s1']);

        // 20 entries x 4KB: far more than one 30KB message can carry.
        final all = <LogEntry>[];
        for (var i = 1; i <= 20; i++) {
          final entry = entryOf('author-a', i, 1000 + i, 4 * 1024);
          all.add(entry);
          await h.appendEntry(channelId, streamId, entry);
        }

        final response = await h.engine.handleDeltaRequest(
          DeltaRequest(
            sender: NodeId('peer1'),
            channelId: channelId,
            streamId: streamId,
            since: VersionVector.empty,
          ),
        );

        final encoded = h.codec.encode(response);
        expect(
          encoded.length,
          lessThanOrEqualTo(30 * 1024),
          reason: 'encoded DeltaResponse must fit the transport budget',
        );
        expect(
          response.entries,
          isNotEmpty,
          reason: 'a truncated response must still carry a first page',
        );
        expect(
          response.entries.length,
          lessThan(all.length),
          reason: 'the full set cannot fit in one message',
        );
        // The page must be a prefix of the repository order so per-author
        // sequence contiguity is preserved (no version-vector holes).
        for (var i = 0; i < response.entries.length; i++) {
          expect(response.entries[i], equals(all[i]));
        }
      },
    );

    test(
      'truncated deltas converge over repeated request cycles',
      () async {
        final h = GossipEngineTestHarness(
          maxDeltaResponseBytes: 30 * 1024,
        );
        h.createChannel('ch1', streamIds: ['s1']);

        for (var i = 1; i <= 20; i++) {
          await h.appendEntry(
            channelId,
            streamId,
            entryOf('author-a', i, 1000 + i, 4 * 1024),
          );
        }

        // Simulate the requester: re-request with an advanced version
        // vector until the responder has nothing more to give.
        final received = <LogEntry>[];
        var since = <NodeId, int>{};
        var pages = 0;
        while (pages < 20) {
          final response = await h.engine.handleDeltaRequest(
            DeltaRequest(
              sender: NodeId('peer1'),
              channelId: channelId,
              streamId: streamId,
              since: VersionVector(Map.of(since)),
            ),
          );
          if (response.entries.isEmpty) break;
          pages++;
          received.addAll(response.entries);
          for (final e in response.entries) {
            final current = since[e.author] ?? 0;
            if (e.sequence > current) since[e.author] = e.sequence;
          }
        }

        expect(received.length, equals(20));
        expect(
          pages,
          greaterThan(1),
          reason: '80KB of entries cannot arrive in a single 30KB page',
        );
      },
    );

    test(
      'an entry that can never fit emits an error and does not block '
      'other authors',
      () async {
        final h = GossipEngineTestHarness(
          maxDeltaResponseBytes: 30 * 1024,
        );
        h.createChannel('ch1', streamIds: ['s1']);

        // Author A's entry is oversized even alone (40KB raw payload);
        // it sorts FIRST by timestamp.
        final oversized = entryOf('author-a', 1, 500, 40 * 1024);
        await h.appendEntry(channelId, streamId, oversized);
        // Author B has small, deliverable entries with later timestamps.
        final small = <LogEntry>[];
        for (var i = 1; i <= 3; i++) {
          final entry = entryOf('author-b', i, 1000 + i, 100);
          small.add(entry);
          await h.appendEntry(channelId, streamId, entry);
        }

        final response = await h.engine.handleDeltaRequest(
          DeltaRequest(
            sender: NodeId('peer1'),
            channelId: channelId,
            streamId: streamId,
            since: VersionVector.empty,
          ),
        );

        expect(
          response.entries.map((e) => e.author.value),
          everyElement(equals('author-b')),
          reason: 'the poison entry must not starve other authors',
        );
        expect(response.entries.length, equals(3));
        expect(
          h.errors,
          isNotEmpty,
          reason: 'an undeliverable entry must surface via ErrorCallback',
        );
      },
    );
  });

  group('GossipEngine pending delta request dedup', () {
    test(
      'interleaved handleDigestResponse calls produce a single DeltaRequest',
      () async {
        final h = GossipEngineTestHarness();
        h.createChannel('ch1', streamIds: ['s1']);

        // Peer advertises entries we don't have.
        final digestResponse = DigestResponse(
          sender: NodeId('peer1'),
          digests: [
            ChannelDigest(
              channelId: channelId,
              streams: [
                StreamDigest(
                  streamId: streamId,
                  version: VersionVector({NodeId('peer1'): 5}),
                ),
              ],
            ),
          ],
        );

        // Fire both handlers without awaiting the first — this models two
        // DigestResponses queued back-to-back on the incoming stream.
        final futures = [
          h.engine.handleDigestResponse(digestResponse),
          h.engine.handleDigestResponse(digestResponse),
        ];
        final results = await Future.wait(futures);

        final totalRequests = results.expand((r) => r).length;
        expect(
          totalRequests,
          equals(1),
          reason: 'the pending flag must dedup interleaved digest handling',
        );
      },
    );
  });

  group('GossipEngine duplicate DeltaResponse handling', () {
    test(
      'a duplicate DeltaResponse does not re-emit EntriesMerged',
      () async {
        final h = GossipEngineTestHarness();
        h.createChannel('ch1', streamIds: ['s1']);

        final response = DeltaResponse(
          sender: NodeId('peer1'),
          channelId: channelId,
          streamId: streamId,
          entries: [
            entryOf('peer1', 1, 1001, 10),
            entryOf('peer1', 2, 1002, 10),
          ],
        );

        await h.engine.handleDeltaResponse(response);
        await h.engine.handleDeltaResponse(response);

        expect(
          h.mergedEntries.length,
          equals(1),
          reason: 'already-stored entries must not surface as merged again',
        );
      },
    );

    test(
      'a partially overlapping DeltaResponse surfaces only the new entries',
      () async {
        final h = GossipEngineTestHarness();
        h.createChannel('ch1', streamIds: ['s1']);

        await h.engine.handleDeltaResponse(
          DeltaResponse(
            sender: NodeId('peer1'),
            channelId: channelId,
            streamId: streamId,
            entries: [
              entryOf('peer1', 1, 1001, 10),
              entryOf('peer1', 2, 1002, 10),
            ],
          ),
        );

        await h.engine.handleDeltaResponse(
          DeltaResponse(
            sender: NodeId('peer1'),
            channelId: channelId,
            streamId: streamId,
            entries: [
              entryOf('peer1', 2, 1002, 10), // duplicate
              entryOf('peer1', 3, 1003, 10), // new
            ],
          ),
        );

        expect(h.mergedEntries.length, equals(2));
        expect(
          h.mergedEntries[1].entries.map((e) => e.sequence),
          equals([3]),
          reason: 'only genuinely new entries may be reported as merged',
        );
      },
    );
  });
}
