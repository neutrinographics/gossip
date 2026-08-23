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
  ///
  /// Not called by the library; retained for application-side queries.
  /// Candidate for removal in a future API surface review.
  Future<List<Peer>> findAll();

  /// Returns only reachable peers.
  ///
  /// Filters for peers with status == PeerStatus.reachable. Not called by
  /// the library; retained for application-side queries. Candidate for
  /// removal in a future API surface review. Because status is never
  /// persisted (see the class-level contract above), the filter reflects
  /// only whatever status a [Peer] carried at [save] time, not live SWIM
  /// state — implementations that honor the contract will find it
  /// perpetually empty or stale.
  Future<List<Peer>> findReachable();

  /// Returns true if a peer with the given node ID exists.
  ///
  /// Not called by the library; retained for application-side queries.
  /// Candidate for removal in a future API surface review.
  Future<bool> exists(NodeId id);

  /// Returns the total number of persisted peers.
  ///
  /// Not called by the library; retained for application-side queries.
  /// Candidate for removal in a future API surface review.
  Future<int> get count;

  /// Removes all persisted peers.
  ///
  /// Used when resetting all sync state (e.g., user logout).
  Future<void> clearAll();
}
