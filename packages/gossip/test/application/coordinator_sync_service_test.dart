import 'package:gossip/src/application/coordinator_sync_service.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/facade/coordinator.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_channel_repository.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_peer_repository.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:test/test.dart';

void main() {
  group('CoordinatorSyncService', () {
    late Coordinator coordinator;
    late CoordinatorSyncService service;
    late NodeId localNode;

    setUp(() async {
      localNode = NodeId('local');
      coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );
      service = CoordinatorSyncService(coordinator);
    });

    test('localNode returns coordinator local node', () {
      expect(service.localNode, equals(localNode));
    });

    test('localIncarnation returns coordinator incarnation', () {
      expect(service.localIncarnation, equals(0));
    });

    test('reachablePeers returns coordinator reachable peers', () async {
      final peerId = NodeId('peer1');
      await coordinator.addPeer(peerId);

      final peers = service.reachablePeers;
      expect(peers.length, equals(1));
      expect(peers.first.id, equals(peerId));
    });

    test('getPeer returns peer from coordinator', () async {
      final peerId = NodeId('peer1');
      await coordinator.addPeer(peerId);

      final peer = service.getPeer(peerId);
      expect(peer, isNotNull);
      expect(peer!.id, equals(peerId));
    });

    test('getPeer returns null for unknown peer', () {
      final peer = service.getPeer(NodeId('unknown'));
      expect(peer, isNull);
    });

    test('channelIds returns coordinator channel IDs', () async {
      final channelId = ChannelId('channel1');
      await coordinator.createChannel(channelId);

      final ids = service.channelIds;
      expect(ids, contains(channelId));
    });
  });
}
