import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/entities/peer.dart';
import 'package:gossip/src/domain/events/domain_event.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_peer_repository.dart';

void main() {
  group('InMemoryPeerRepository', () {
    test('save and findById stores and retrieves peer', () async {
      final repository = InMemoryPeerRepository();
      final peerId = NodeId('peer-1');
      final peer = Peer(id: peerId, status: PeerStatus.reachable);

      await repository.save(peer);
      final retrieved = await repository.findById(peerId);

      expect(retrieved, isNotNull);
      expect(retrieved!.id, equals(peerId));
      expect(retrieved.status, equals(PeerStatus.reachable));
    });

    test('delete removes peer from repository', () async {
      final repository = InMemoryPeerRepository();
      final peerId = NodeId('peer-1');
      final peer = Peer(id: peerId, status: PeerStatus.reachable);

      await repository.save(peer);
      expect(await repository.exists(peerId), isTrue);

      await repository.delete(peerId);

      expect(await repository.exists(peerId), isFalse);
      expect(await repository.findById(peerId), isNull);
    });

    test('findAll returns all peers', () async {
      final repository = InMemoryPeerRepository();
      final peer1 = Peer(id: NodeId('peer-1'), status: PeerStatus.reachable);
      final peer2 = Peer(id: NodeId('peer-2'), status: PeerStatus.suspected);

      await repository.save(peer1);
      await repository.save(peer2);

      final peers = await repository.findAll();
      expect(peers, hasLength(2));
      expect(peers.map((p) => p.id), contains(peer1.id));
      expect(peers.map((p) => p.id), contains(peer2.id));
    });

    test('findReachable returns only reachable peers', () async {
      final repository = InMemoryPeerRepository();
      final peer1 = Peer(id: NodeId('peer-1'), status: PeerStatus.reachable);
      final peer2 = Peer(id: NodeId('peer-2'), status: PeerStatus.suspected);
      final peer3 = Peer(id: NodeId('peer-3'), status: PeerStatus.reachable);

      await repository.save(peer1);
      await repository.save(peer2);
      await repository.save(peer3);

      final reachable = await repository.findReachable();
      expect(reachable, hasLength(2));
      expect(reachable.map((p) => p.id), contains(peer1.id));
      expect(reachable.map((p) => p.id), contains(peer3.id));
      expect(reachable.map((p) => p.id), isNot(contains(peer2.id)));
    });
  });
}
