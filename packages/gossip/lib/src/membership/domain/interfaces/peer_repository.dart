import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/membership/domain/entities/peer.dart';

/// Repository for peer state.
///
/// [PeerRepository] stores the state of known peers, including their
/// reachability status and communication metrics.
///
/// ## Persistence is not required
///
/// Peers are transient — they are discovered at runtime and added/removed
/// as devices connect and disconnect. Persisting peers across app restarts
/// is unnecessary because:
/// - A loaded peer has no meaning if the device isn't present
/// - The failure detector would immediately begin suspecting stale peers
/// - Peers must be re-added when they reconnect anyway
///
/// `Coordinator.create` defaults to `InMemoryPeerRepository` when no
/// repository is provided, which is the recommended choice for most apps.
///
/// A persistent implementation is only useful if your application needs
/// its own features around peer history (e.g., "recently seen devices").
///
/// ## What actually reaches this interface
///
/// Only peer membership (add/remove) is written here. SWIM-driven state —
/// reachability status, contact times, RTT and traffic metrics — lives
/// exclusively in the in-memory `PeerRegistry` and is never persisted, by
/// design: it is ephemeral runtime observation, meaningless across
/// restarts. A persistent implementation therefore sees peers appear and
/// disappear, nothing else.
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

  /// Removes all persisted peers.
  ///
  /// Used when resetting all sync state (e.g., user logout).
  Future<void> clearAll();
}
