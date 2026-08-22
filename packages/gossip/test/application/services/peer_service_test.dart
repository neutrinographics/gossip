import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/domain/interfaces/peer_repository.dart';
import 'package:gossip/src/domain/entities/peer.dart';
import 'package:gossip/src/membership/domain/events/membership_events.dart';
import 'package:gossip/src/application/services/peer_service.dart';

class FakePeerRepository implements PeerRepository {
  final Map<NodeId, Peer> _peers = {};

  @override
  Future<Peer?> findById(NodeId id) async => _peers[id];

  @override
  Future<void> save(Peer peer) async {
    _peers[peer.id] = peer;
  }

  @override
  Future<void> delete(NodeId id) async {
    _peers.remove(id);
  }

  @override
  Future<List<Peer>> findAll() async => _peers.values.toList();

  @override
  Future<List<Peer>> findReachable() async =>
      _peers.values.where((p) => p.status == PeerStatus.reachable).toList();

  @override
  Future<bool> exists(NodeId id) async => _peers.containsKey(id);

  @override
  Future<int> get count async => _peers.length;

  @override
  Future<void> clearAll() async {
    _peers.clear();
  }
}

void main() {
  group('PeerService', () {
    test('addPeer adds peer to registry and persists it', () async {
      final localNode = NodeId('local');
      final repository = FakePeerRepository();
      final registry = PeerRegistry(
        localNode: localNode,
      );
      final service = PeerService(
        registry: registry,
        repository: repository,
      );
      final peerId = NodeId('peer-1');

      await service.addPeer(peerId);

      expect(registry.isKnown(peerId), isTrue);
      final persistedPeer = await repository.findById(peerId);
      expect(persistedPeer, isNotNull);
      expect(persistedPeer!.id, equals(peerId));
      expect(persistedPeer.status, equals(PeerStatus.reachable));
    });

    test(
      'removePeer removes peer from registry and deletes it from repository',
      () async {
        final localNode = NodeId('local');
        final repository = FakePeerRepository();
        final registry = PeerRegistry(
          localNode: localNode,
        );
        final service = PeerService(
          registry: registry,
          repository: repository,
        );
        final peerId = NodeId('peer-1');

        // Add peer first
        await service.addPeer(peerId);
        expect(registry.isKnown(peerId), isTrue);
        expect(await repository.exists(peerId), isTrue);

        // Now remove it
        await service.removePeer(peerId);

        expect(registry.isKnown(peerId), isFalse);
        expect(await repository.exists(peerId), isFalse);
      },
    );
  });
}
