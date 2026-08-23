import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
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
}
