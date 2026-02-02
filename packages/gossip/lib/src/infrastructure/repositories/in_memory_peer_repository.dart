import '../../domain/value_objects/node_id.dart';
import '../../domain/entities/peer.dart';
import '../../domain/interfaces/peer_repository.dart';
import '../../domain/events/domain_event.dart';

/// In-memory implementation of [PeerRepository] for testing.
///
/// This implementation stores peers in a simple [Map] with no persistence.
/// All data is lost when the application terminates.
///
/// **Use only for testing and prototyping.**
///
/// For production applications, implement [PeerRepository] with persistent
/// storage:
/// - SQLite for mobile/desktop apps with SQL queries by status
/// - IndexedDB for web apps
/// - Serialize peers to JSON for storage
/// - Consider TTL for unreachable peers to limit storage growth
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
  Future<List<Peer>> findReachable() async =>
      _peers.values.where((p) => p.status == PeerStatus.reachable).toList();

  @override
  Future<bool> exists(NodeId id) async => _peers.containsKey(id);

  @override
  Future<int> get count async => _peers.length;
}
