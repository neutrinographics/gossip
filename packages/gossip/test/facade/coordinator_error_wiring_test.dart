import 'package:gossip/src/shared/domain/errors/sync_error.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/facade/coordinator.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_channel_repository.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:gossip/src/membership/infrastructure/in_memory_peer_repository.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_entry_repository.dart';
import 'package:test/test.dart';

/// Regression tests for audit COR3-3: the Coordinator must wire `onError`
/// into the application services it constructs, so errors they emit reach
/// `coordinator.errors` instead of vanishing (the project's no-silent-errors
/// rule).
void main() {
  group('Coordinator error wiring', () {
    late NodeId localNode;

    setUp(() {
      localNode = NodeId('local');
    });

    Future<Coordinator> createCoordinator() {
      return Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );
    }

    test(
      'ChannelService errors surface on coordinator.errors '
      '(membership op on a removed channel)',
      () async {
        final coordinator = await createCoordinator();
        final channelId = ChannelId('channel1');
        final channel = await coordinator.createChannel(channelId);

        final errors = <SyncError>[];
        final sub = coordinator.errors.listen(errors.add);

        // Remove the channel behind the held facade, then use the stale
        // facade. The service emits a ChannelSyncError; before the fix it
        // went to a null callback and vanished.
        await coordinator.removeChannel(channelId);
        await channel.addMember(NodeId('peer-1'));

        // Let the broadcast stream deliver.
        await Future<void>.delayed(Duration.zero);

        expect(errors, isNotEmpty, reason: 'error should reach the app');
        expect(errors.first, isA<ChannelSyncError>());

        await sub.cancel();
        await coordinator.dispose();
      },
    );
  });
}
