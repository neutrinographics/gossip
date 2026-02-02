import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/domain/interfaces/peer_repository.dart';
import 'package:gossip/src/domain/entities/peer.dart';
import 'package:gossip/src/domain/events/domain_event.dart';
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
}

void main() {
  group('PeerService', () {
    test('addPeer adds peer to registry and persists it', () async {
      final localNode = NodeId('local');
      final repository = FakePeerRepository();
      final registry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      final service = PeerService(
        localNode: localNode,
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
          initialIncarnation: 0,
        );
        final service = PeerService(
          localNode: localNode,
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

    test(
      'updatePeerStatus updates status in registry and persists it',
      () async {
        final localNode = NodeId('local');
        final repository = FakePeerRepository();
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        final service = PeerService(
          localNode: localNode,
          registry: registry,
          repository: repository,
        );
        final peerId = NodeId('peer-1');

        // Add peer first
        await service.addPeer(peerId);
        expect(registry.getPeer(peerId)?.status, equals(PeerStatus.reachable));

        // Update status to suspected
        await service.updatePeerStatus(peerId, PeerStatus.suspected);

        expect(registry.getPeer(peerId)?.status, equals(PeerStatus.suspected));
        final persistedPeer = await repository.findById(peerId);
        expect(persistedPeer?.status, equals(PeerStatus.suspected));
      },
    );

    test(
      'recordPeerContact updates contact timestamp in registry and persists it',
      () async {
        final localNode = NodeId('local');
        final repository = FakePeerRepository();
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        final service = PeerService(
          localNode: localNode,
          registry: registry,
          repository: repository,
        );
        final peerId = NodeId('peer-1');

        // Add peer first
        await service.addPeer(peerId);
        expect(registry.getPeer(peerId)?.lastContactMs, equals(0));

        // Record contact
        await service.recordPeerContact(peerId, 1000);

        expect(registry.getPeer(peerId)?.lastContactMs, equals(1000));
        final persistedPeer = await repository.findById(peerId);
        expect(persistedPeer?.lastContactMs, equals(1000));
      },
    );

    test(
      'recordPeerAntiEntropy updates anti-entropy timestamp in registry and persists it',
      () async {
        final localNode = NodeId('local');
        final repository = FakePeerRepository();
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        final service = PeerService(
          localNode: localNode,
          registry: registry,
          repository: repository,
        );
        final peerId = NodeId('peer-1');

        // Add peer first
        await service.addPeer(peerId);
        expect(registry.getPeer(peerId)?.lastAntiEntropyMs, isNull);

        // Record anti-entropy
        await service.recordPeerAntiEntropy(peerId, 2000);

        expect(registry.getPeer(peerId)?.lastAntiEntropyMs, equals(2000));
        final persistedPeer = await repository.findById(peerId);
        expect(persistedPeer?.lastAntiEntropyMs, equals(2000));
      },
    );

    test(
      'recordMessageReceived updates peer metrics in registry and persists it',
      () async {
        final localNode = NodeId('local');
        final repository = FakePeerRepository();
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        final service = PeerService(
          localNode: localNode,
          registry: registry,
          repository: repository,
        );
        final peerId = NodeId('peer-1');

        // Add peer first
        await service.addPeer(peerId);
        expect(registry.getPeer(peerId)?.metrics.bytesReceived, equals(0));

        // Record message received
        await service.recordMessageReceived(peerId, 100, 1000, 60000);

        expect(registry.getPeer(peerId)?.metrics.bytesReceived, equals(100));
        final persistedPeer = await repository.findById(peerId);
        expect(persistedPeer?.metrics.bytesReceived, equals(100));
      },
    );

    test(
      'recordMessageSent updates peer metrics in registry and persists it',
      () async {
        final localNode = NodeId('local');
        final repository = FakePeerRepository();
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        final service = PeerService(
          localNode: localNode,
          registry: registry,
          repository: repository,
        );
        final peerId = NodeId('peer-1');

        // Add peer first
        await service.addPeer(peerId);
        expect(registry.getPeer(peerId)?.metrics.bytesSent, equals(0));

        // Record message sent
        await service.recordMessageSent(peerId, 200);

        expect(registry.getPeer(peerId)?.metrics.bytesSent, equals(200));
        final persistedPeer = await repository.findById(peerId);
        expect(persistedPeer?.metrics.bytesSent, equals(200));
      },
    );
  });
}
