import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/membership/domain/entities/peer.dart';
import 'package:gossip/src/membership/domain/interfaces/peer_repository.dart';

/// In-memory implementation of [PeerRepository] — the default and
/// recommended repository for most applications.
///
/// Peers are discovered at runtime and re-add themselves on reconnection, so
/// nothing is lost by not persisting them; SWIM-driven status is never
/// persisted by contract regardless of implementation (see
/// [PeerRepository]). A persistent implementation is only useful for
/// app-level features built around peer history (e.g., "recently seen
/// devices").
///
/// All operations complete synchronously but return [Future] to match the
/// repository interface contract.
class InMemoryPeerRepository implements PeerRepository {
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
  Future<void> clearAll() async {
    _peers.clear();
  }
}
