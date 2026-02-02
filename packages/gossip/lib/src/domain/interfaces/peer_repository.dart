import '../value_objects/node_id.dart';
import '../entities/peer.dart';

/// Repository for persisting peer state and metrics.
///
/// [PeerRepository] stores the state of known peers, including their
/// reachability status, incarnation numbers, and communication metrics.
/// The [PeerRegistry] aggregate uses this repository to persist peer
/// state across application restarts.
///
/// ## Persistence Scope
/// Each [Peer] entity includes:
/// - Node ID (identity)
/// - Reachability status (reachable/suspected/unreachable)
/// - Incarnation number (for refuting suspicions)
/// - Last contact timestamps
/// - Failed probe count
/// - Communication metrics
///
/// ## Implementation Guidance
/// - Use key-value storage for simple cases
/// - Use relational storage (SQLite) if querying by status is frequent
/// - Serialize peers to JSON for persistence
/// - Consider time-to-live for unreachable peers to limit storage growth
abstract interface class PeerRepository {
  /// Retrieves a peer by node ID, or null if not found.
  Future<Peer?> findById(NodeId id);

  /// Persists a peer, creating or updating it.
  ///
  /// Overwrites any existing peer with the same node ID.
  Future<void> save(Peer peer);

  /// Deletes a peer by node ID.
  ///
  /// No-op if the peer doesn't exist.
  Future<void> delete(NodeId id);

  /// Returns all persisted peers.
  Future<List<Peer>> findAll();

  /// Returns only reachable peers.
  ///
  /// Filters for peers with status == PeerStatus.reachable.
  /// Used when selecting peers for gossip rounds.
  Future<List<Peer>> findReachable();

  /// Returns true if a peer with the given node ID exists.
  Future<bool> exists(NodeId id);

  /// Returns the total number of persisted peers.
  Future<int> get count;
}
