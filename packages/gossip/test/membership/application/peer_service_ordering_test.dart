import 'dart:async';

import 'package:gossip/src/membership/application/peer_service.dart';
import 'package:gossip/src/membership/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/membership/domain/entities/peer.dart';
import 'package:gossip/src/membership/domain/value_objects/peer_status.dart';
import 'package:gossip/src/membership/domain/interfaces/peer_repository.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:test/test.dart';

/// A repository whose save latency is scripted per call, to model a
/// persistent store (SQLite, Hive) with variable I/O timing.
class _ScriptedLatencyRepository implements PeerRepository {
  final Map<NodeId, Peer> stored = {};
  final List<Duration> saveLatencies;
  int _saveCall = 0;

  /// Number of `save()` calls currently between their await and their
  /// write to [stored]. Chained writes never let this exceed 1; a
  /// regression that lets overlapping mutations race their I/O would
  /// push it to 2+.
  int _inFlightSaves = 0;
  int maxConcurrentSaves = 0;

  _ScriptedLatencyRepository(this.saveLatencies);

  @override
  Future<void> save(Peer peer) async {
    final index = _saveCall++;
    final latency = index < saveLatencies.length
        ? saveLatencies[index]
        : Duration.zero;
    _inFlightSaves++;
    if (_inFlightSaves > maxConcurrentSaves) {
      maxConcurrentSaves = _inFlightSaves;
    }
    await Future<void>.delayed(latency);
    stored[peer.id] = peer;
    _inFlightSaves--;
  }

  @override
  Future<Peer?> findById(NodeId id) async => stored[id];

  @override
  Future<void> delete(NodeId id) async => stored.remove(id);

  @override
  Future<List<Peer>> findAll() async => stored.values.toList();

  @override
  Future<List<Peer>> findReachable() async =>
      stored.values.where((p) => p.status == PeerStatus.reachable).toList();

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
      'removePeer cannot be overtaken by an in-flight save (COR3-19)',
      () async {
        final localNode = NodeId('local');
        final peerId = NodeId('peer1');
        final registry = PeerRegistry(localNode: localNode);
        // Call 0 = first addPeer's save (instant); call 1 = second addPeer's
        // save (SLOW — already past its registry snapshot when the peer is
        // removed). The second addPeer is a no-op for the registry (the
        // peer is already reachable) but PeerService still enqueues a
        // persist for it, which is all this race needs.
        final repository = _ScriptedLatencyRepository([
          Duration.zero,
          const Duration(milliseconds: 50),
        ]);
        final service = PeerService(registry: registry, repository: repository);

        await service.addPeer(peerId);
        final slowSave = service.addPeer(peerId);
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

    test('overlapping addPeer calls for the same peer chain their writes '
        '(no interleaved corruption)', () async {
      final localNode = NodeId('local');
      final peerId = NodeId('peer1');
      final registry = PeerRegistry(localNode: localNode);
      // First save is slow, second is fast. If the second call's write
      // were not chained behind the first, it would start (and likely
      // finish) while the first is still in flight.
      final repository = _ScriptedLatencyRepository([
        const Duration(milliseconds: 30),
        const Duration(milliseconds: 5),
      ]);
      final service = PeerService(registry: registry, repository: repository);

      final first = service.addPeer(peerId);
      final second = service.addPeer(peerId);
      await Future.wait([first, second]);

      expect(
        repository.maxConcurrentSaves,
        1,
        reason:
            'overlapping addPeer calls for the same peer must serialize '
            'their persistence writes, never racing two saves at once',
      );
      expect(
        repository.stored,
        hasLength(1),
        reason:
            'the chained writes must leave exactly one final '
            'snapshot for the peer, not a duplicated or corrupted entry',
      );
      expect(repository.stored[peerId], isNotNull);
    });
  });
}
