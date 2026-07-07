import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/version_vector.dart';
import 'package:gossip/src/protocol/messages/delta_request.dart';
import 'package:gossip/src/protocol/messages/digest_request.dart';
import 'package:gossip/src/protocol/messages/digest_response.dart';
import 'package:gossip/src/protocol/values/channel_digest.dart';
import 'package:gossip/src/protocol/values/stream_digest.dart';
import 'package:test/test.dart';

import 'gossip_engine_test_harness.dart';

void main() {
  final channelId = ChannelId('ch1');
  final streamId = StreamId('s1');

  group('GossipEngine push-pull reciprocation (M1)', () {
    test(
      'a DigestRequest from a peer that is ahead triggers a reciprocal '
      'DeltaRequest — each exchange is push-pull',
      () async {
        final h = GossipEngineTestHarness();
        final peer = h.addPeer('peer1');
        h.createChannel('ch1', streamIds: ['s1']);
        h.startListening();
        h.engine.start(); // reciprocation is active sync; engine must be running

        final (messages, sub) = h.captureMessages(peer);

        // The peer's DigestRequest advertises entries the responder lacks.
        await peer.port.send(
          h.localNode,
          h.codec.encode(
            DigestRequest(
              sender: peer.id,
              digests: [
                ChannelDigest(
                  channelId: channelId,
                  streams: [
                    StreamDigest(
                      streamId: streamId,
                      version: VersionVector({peer.id: 5}),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
        await h.flush();

        // Existing behaviour: responder replies with its own digest.
        expect(messages.whereType<DigestResponse>().length, equals(1));
        // New: the responder also pulls the peer's newer entries using the
        // free version vectors carried in the request (push-pull).
        final deltaRequests = messages.whereType<DeltaRequest>().toList();
        expect(
          deltaRequests.length,
          equals(1),
          reason:
              'the responder must reciprocate using the digests already in '
              'the request instead of discarding them',
        );
        expect(deltaRequests.single.channelId, equals(channelId));
        expect(deltaRequests.single.streamId, equals(streamId));

        await sub.cancel();
        h.engine.stop();
        h.stopListening();
      },
    );

    test(
      'a DigestRequest from an in-sync peer produces no reciprocal '
      'DeltaRequest (only the digest response)',
      () async {
        final h = GossipEngineTestHarness();
        final peer = h.addPeer('peer1');
        h.createChannel('ch1', streamIds: ['s1']);
        h.startListening();
        h.engine.start(); // reciprocation is active sync; engine must be running

        final (messages, sub) = h.captureMessages(peer);

        await peer.port.send(
          h.localNode,
          h.codec.encode(
            DigestRequest(
              sender: peer.id,
              digests: [
                ChannelDigest(
                  channelId: channelId,
                  streams: [
                    StreamDigest(
                      streamId: streamId,
                      version: VersionVector.empty,
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
        await h.flush();

        expect(messages.whereType<DigestResponse>().length, equals(1));
        expect(
          messages.whereType<DeltaRequest>(),
          isEmpty,
          reason: 'no reciprocation when the peer has nothing we lack',
        );

        await sub.cancel();
        h.engine.stop();
        h.stopListening();
      },
    );

    test(
      'a listen-only (not running) engine serves the digest but does NOT '
      'reciprocate — a paused node must not pull',
      () async {
        final h = GossipEngineTestHarness();
        final peer = h.addPeer('peer1');
        h.createChannel('ch1', streamIds: ['s1']);
        h.startListening(); // listening but NOT started (paused/listen-only)

        final (messages, sub) = h.captureMessages(peer);

        await peer.port.send(
          h.localNode,
          h.codec.encode(
            DigestRequest(
              sender: peer.id,
              digests: [
                ChannelDigest(
                  channelId: channelId,
                  streams: [
                    StreamDigest(
                      streamId: streamId,
                      version: VersionVector({peer.id: 5}),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
        await h.flush();

        expect(
          messages.whereType<DigestResponse>().length,
          equals(1),
          reason: 'still serves its digest while listen-only',
        );
        expect(
          messages.whereType<DeltaRequest>(),
          isEmpty,
          reason: 'must not actively pull while not running (pause semantics)',
        );

        await sub.cancel();
        h.stopListening();
      },
    );
  });
}
