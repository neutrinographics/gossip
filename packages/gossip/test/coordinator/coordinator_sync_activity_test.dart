import 'package:gossip/gossip.dart';
import 'package:gossip/src/sync/domain/messages/digest_response.dart';
import 'package:gossip/src/sync/infrastructure/sync_message_codec.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';
import 'package:gossip/src/sync/domain/value_objects/stream_digest.dart';
import 'package:test/test.dart';

void main() {
  final localNode = NodeId('local');

  group('Coordinator.gossipSyncActivity (G5)', () {
    test(
      'reports quiescent with zero activity for a fresh coordinator',
      () async {
        final coordinator = await Coordinator.create(
          localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
          channelRepository: InMemoryChannelRepository(),
          peerRepository: InMemoryPeerRepository(),
          entryRepository: InMemoryEntryRepository(),
          messagePort: InMemoryMessagePort(localNode, InMemoryMessageBus()),
        );
        await coordinator.start();

        final activity = coordinator.gossipSyncActivity;
        expect(activity.outstandingPulls, equals(0));
        expect(activity.mergedBatches, equals(0));
        expect(activity.isQuiescent, isTrue);

        await coordinator.dispose();
      },
    );

    test('removePeer clears its outstanding pulls so isQuiescent recovers '
        '(COR3-12)', () async {
      final bus = InMemoryMessageBus();
      final localPort = InMemoryMessagePort(localNode, bus);
      final peerId = NodeId('peer-1');
      final peerPort = InMemoryMessagePort(peerId, bus);
      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
        messagePort: localPort,
        timerPort: InMemoryTimePort(),
      );
      final channel = await coordinator.createChannel(ChannelId('ch1'));
      await channel.getOrCreateStream(StreamId('s1'));
      await coordinator.start();
      await coordinator.addPeer(peerId);

      // The peer advertises entries we lack → the engine arms a pending
      // pull and sends it a DeltaRequest (which the peer never answers).
      await peerPort.send(
        localNode,
        SyncMessageCodec().encode(
          DigestResponse(
            sender: peerId,
            digests: [
              ChannelDigest(
                channelId: ChannelId('ch1'),
                streams: [
                  StreamDigest(
                    streamId: StreamId('s1'),
                    version: VersionVector({peerId: 5}),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(coordinator.gossipSyncActivity.outstandingPulls, equals(1));

      // The peer disconnects before answering: its pull can never
      // complete and must not wedge the "syncing…" signal forever.
      await coordinator.removePeer(peerId);
      expect(coordinator.gossipSyncActivity.outstandingPulls, equals(0));
      expect(coordinator.gossipSyncActivity.isQuiescent, isTrue);

      await coordinator.dispose();
      await peerPort.close();
    });

    test('reports quiescent in local-only mode (no gossip engine)', () async {
      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      final activity = coordinator.gossipSyncActivity;
      expect(activity.isQuiescent, isTrue);
      expect(activity.outstandingPulls, equals(0));

      await coordinator.dispose();
    });
  });
}
