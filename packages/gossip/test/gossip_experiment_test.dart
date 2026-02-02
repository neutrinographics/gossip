import 'package:gossip/gossip.dart';
import 'package:test/test.dart';

void main() {
  group('Gossip Library', () {
    test('Coordinator can be created', () async {
      final coordinator = await Coordinator.create(
        localNode: NodeId('test'),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      expect(coordinator.localNode, equals(NodeId('test')));
    });

    test('Channel can be created and accessed', () async {
      final coordinator = await Coordinator.create(
        localNode: NodeId('test'),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      final channelFacade = await coordinator.createChannel(
        ChannelId('channel1'),
      );

      expect(channelFacade.id, equals(ChannelId('channel1')));
    });
  });
}
