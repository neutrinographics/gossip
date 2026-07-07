import 'package:gossip/gossip.dart';
import 'package:test/test.dart';

void main() {
  final localNode = NodeId('local');

  group('Coordinator.gossipSyncActivity (G5)', () {
    test('reports quiescent with zero activity for a fresh coordinator',
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
