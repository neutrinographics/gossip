import 'dart:typed_data';

import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/sync/domain/messages/delta_response.dart';
import 'package:gossip/src/sync/domain/messages/digest_response.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';
import 'package:gossip/src/sync/domain/value_objects/stream_digest.dart';
import 'package:test/test.dart';

import 'gossip_engine_test_harness.dart';

/// G5: expose a coarse in-sync signal so apps can show "syncing…" vs "up to
/// date". outstandingPullCount = delta requests in flight; mergedBatchCount =
/// monotonic activity counter.
void main() {
  final channelId = ChannelId('ch1');
  final streamId = StreamId('s1');

  DigestResponse digestFrom(NodeId peerId, {int seq = 3}) => DigestResponse(
    sender: peerId,
    digests: [
      ChannelDigest(
        channelId: channelId,
        streams: [
          StreamDigest(
            streamId: streamId,
            version: VersionVector({peerId: seq}),
          ),
        ],
      ),
    ],
  );

  group('GossipEngine sync-activity signal (G5)', () {
    test('outstandingPullCount tracks in-flight delta requests', () async {
      final h = GossipEngineTestHarness();
      final peer = h.addPeer('peerA');
      h.createChannel('ch1', streamIds: ['s1']);

      expect(h.engine.outstandingPullCount, equals(0));

      // A digest showing the peer is ahead arms a pending pull.
      await h.engine.handleDigestResponse(digestFrom(peer.id));
      expect(h.engine.outstandingPullCount, equals(1));

      // The response clears it.
      await h.engine.handleDeltaResponse(
        DeltaResponse(
          sender: peer.id,
          channelId: channelId,
          streamId: streamId,
          entries: const [],
        ),
      );
      expect(h.engine.outstandingPullCount, equals(0));
    });

    test('outstandingPullCount excludes expired pending pulls', () async {
      final h = GossipEngineTestHarness();
      final peer = h.addPeer('peerA');
      h.createChannel('ch1', streamIds: ['s1']);

      await h.engine.handleDigestResponse(digestFrom(peer.id));
      expect(h.engine.outstandingPullCount, equals(1));

      // The peer never answers. Once the pending timeout elapses the pull
      // is dead — it must not report "syncing…" forever (COR3-12).
      await h.timePort.advance(
        h.engine.effectivePendingRequestTimeout + const Duration(seconds: 1),
      );
      expect(h.engine.outstandingPullCount, equals(0));
    });

    test(
      'mergedBatchCount increments only when new entries are merged',
      () async {
        final h = GossipEngineTestHarness();
        final peer = h.addPeer('peerA');
        final author = NodeId('author-1');
        h.createChannel('ch1', streamIds: ['s1']);

        expect(h.engine.mergedBatchCount, equals(0));

        // An empty response merges nothing.
        await h.engine.handleDeltaResponse(
          DeltaResponse(
            sender: peer.id,
            channelId: channelId,
            streamId: streamId,
            entries: const [],
          ),
        );
        expect(h.engine.mergedBatchCount, equals(0));

        // A response with a fresh contiguous entry counts as one merged batch.
        await h.engine.handleDeltaResponse(
          DeltaResponse(
            sender: peer.id,
            channelId: channelId,
            streamId: streamId,
            entries: [
              LogEntry(
                author: author,
                sequence: 1,
                timestamp: Hlc(1000, 0),
                payload: Uint8List.fromList([1]),
              ),
            ],
          ),
        );
        expect(h.engine.mergedBatchCount, equals(1));
      },
    );
  });
}
