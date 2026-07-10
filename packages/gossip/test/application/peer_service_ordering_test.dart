import 'dart:async';

import 'package:gossip/src/application/services/peer_service.dart';
import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/domain/entities/peer.dart';
import 'package:gossip/src/domain/events/domain_event.dart' show PeerStatus;
import 'package:gossip/src/domain/interfaces/peer_repository.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:test/test.dart';

/// A repository whose save latency is scripted per call, to model a
/// persistent store (SQLite, Hive) with variable I/O timing.
class _ScriptedLatencyRepository implements PeerRepository {
  final Map<NodeId, Peer> stored = {};
  final List<Duration> saveLatencies;
  int _saveCall = 0;

  _ScriptedLatencyRepository(this.saveLatencies);

  @override
  Future<void> save(Peer peer) async {
    final index = _saveCall++;
    final latency = index < saveLatencies.length
        ? saveLatencies[index]
        : Duration.zero;
    await Future<void>.delayed(latency);
    stored[peer.id] = peer;
  }

  @override
  Future<Peer?> findById(NodeId id) async => stored[id];

  @override
  Future<void> delete(NodeId id) async => stored.remove(id);

  @override
  Future<List<Peer>> findAll() async => stored.values.toList();

  @override
  Future<List<Peer>> findReachable() async => stored.values
      .where((p) => p.status == PeerStatus.reachable)
      .toList();

  @override
  Future<bool> exists(NodeId id) async => stored.containsKey(id);

  @override
  Future<int> get count async => stored.length;

  @override
  Future<void> clearAll() async => stored.clear();
}

void main() {
  group('PeerService persistence ordering', () {
    test(
      'overlapping mutations persist the newest snapshot last',
      () async {
        final localNode = NodeId('local');
        final peerId = NodeId('peer1');
        final registry = PeerRegistry(
          localNode: localNode,
        );
        // Call 0 = addPeer's save (instant). Call 1 (status change) is
        // SLOW; call 2 (contact) is instant — so without ordering, the
        // stale suspected snapshot lands after the fresh reachable one.
        final repository = _ScriptedLatencyRepository([
          Duration.zero,
          const Duration(milliseconds: 50),
          Duration.zero,
        ]);
        final service = PeerService(
          registry: registry,
          repository: repository,
        );

        await service.addPeer(peerId);

        // Two overlapping operations: suspect, then contact (recovers to
        // reachable). Logical order says the peer ends reachable.
        final statusUpdate = service.updatePeerStatus(
          peerId,
          PeerStatus.suspected,
        );
        final contact = service.recordPeerContact(peerId, 1000);
        await Future.wait([statusUpdate, contact]);

        expect(
          registry.getPeer(peerId)!.status,
          equals(PeerStatus.reachable),
          reason: 'sanity: the registry itself is last-write-wins in order',
        );
        expect(
          repository.stored[peerId]!.status,
          equals(PeerStatus.reachable),
          reason:
              'storage must not end up with an older snapshot than the '
              'registry because a slow save landed last',
        );
      },
    );

    test(
      'removePeer cannot be overtaken by an in-flight save (COR3-19)',
      () async {
        final localNode = NodeId('local');
        final peerId = NodeId('peer1');
        final registry = PeerRegistry(localNode: localNode);
        // Call 0 = addPeer save (instant); call 1 = status change (SLOW —
        // already past its registry snapshot when the peer is removed).
        final repository = _ScriptedLatencyRepository([
          Duration.zero,
          const Duration(milliseconds: 50),
        ]);
        final service = PeerService(
          registry: registry,
          repository: repository,
        );

        await service.addPeer(peerId);
        final slowSave = service.updatePeerStatus(
          peerId,
          PeerStatus.suspected,
        );
        // Let the save chain pass its registry snapshot and enter the
        // repository write before the peer is removed.
        await Future<void>.delayed(Duration.zero);
        await service.removePeer(peerId);
        await slowSave;

        expect(
          repository.stored,
          isEmpty,
          reason:
              'a save in flight at removal time must not resurrect the '
              'peer in persistent storage',
        );
      },
    );
  });
}
