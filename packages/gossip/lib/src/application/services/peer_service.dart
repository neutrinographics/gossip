import '../../domain/errors/sync_error.dart';
import '../../domain/value_objects/node_id.dart';
import '../../domain/aggregates/peer_registry.dart';
import '../../domain/interfaces/local_node_repository.dart';
import '../../domain/interfaces/peer_repository.dart';
import '../../domain/events/domain_event.dart';

/// Application service orchestrating peer lifecycle and state management.
///
/// [PeerService] coordinates between the [PeerRegistry] aggregate and
/// [PeerRepository] persistence layer. It handles:
///
/// - **Peer lifecycle**: Adding and removing peers from registry
/// - **SWIM state updates**: Transitioning peers through reachable/suspected/unreachable
/// - **Contact tracking**: Recording probe responses and anti-entropy exchanges
/// - **Metrics recording**: Tracking message rates for rate limiting
///
/// ## Transaction Boundaries
///
/// Each public method represents a transaction boundary following the pattern:
/// 1. Execute operation on [PeerRegistry] aggregate
/// 2. Extract modified [Peer] entity from registry
/// 3. Persist entity to repository (if repository exists)
///
/// Unlike [ChannelService], this service works with a single [PeerRegistry]
/// aggregate instance that is injected (not loaded per operation). The registry
/// is the source of truth; repository provides persistence only.
///
/// ## Optional Persistence
///
/// [PeerRepository] is optional to support in-memory-only operation for testing.
/// When null, peer state changes are tracked in the registry but not persisted.
///
/// Used by: Protocol services (FailureDetector, GossipEngine) and public facades.
class PeerService {
  /// The peer registry aggregate managing all peer state.
  ///
  /// Injected instance serves as single source of truth for peer state.
  final PeerRegistry registry;

  /// Optional persistence layer for [Peer] entities.
  ///
  /// When null, peers are not persisted (in-memory only).
  final PeerRepository? repository;

  /// Repository for persisting local node state (incarnation).
  final LocalNodeRepository localNodeRepository;

  /// Optional callback for reporting synchronization errors.
  ///
  /// When provided, errors that would otherwise be silent are reported
  /// through this callback for observability.
  final ErrorCallback? onError;

  PeerService({
    required this.registry,
    required this.localNodeRepository,
    this.repository,
    this.onError,
  });

  /// Emits an error through the callback if one is registered.
  void _emitError(SyncError error) {
    onError?.call(error);
  }

  /// Adds a new peer to the registry.
  ///
  /// Creates a new [Peer] entity in [reachable] status with incarnation 0
  /// and persists it. Fires [PeerAdded] domain event.
  ///
  /// If [displayName] is not provided, defaults to a truncated form of the
  /// node ID.
  ///
  /// Used when: Discovering a new peer via application-provided peer list
  /// or gossip membership updates.
  ///
  /// Transaction: Add to registry → retrieve entity → save to repository.
  Future<void> addPeer(NodeId peerId, {String? displayName}) async {
    registry.addPeer(
      peerId,
      displayName: displayName,
      occurredAt: DateTime.now(),
    );
    await _persistPeer(peerId);
  }

  /// Removes a peer from the registry.
  ///
  /// Deletes the [Peer] entity from registry and repository. Fires [PeerRemoved]
  /// domain event.
  ///
  /// Used when: Peer explicitly leaves or is administratively removed.
  ///
  /// Transaction: Remove from registry → delete from repository.
  Future<void> removePeer(NodeId peerId) async {
    registry.removePeer(peerId, occurredAt: DateTime.now());
    await _deletePeer(peerId);
  }

  /// Increments the local incarnation number and persists it.
  ///
  /// Called when this node refutes a false SWIM suspicion. The incremented
  /// incarnation is broadcast to peers to override their suspected state.
  ///
  /// Transaction: Increment in registry → save to LocalNodeRepository.
  ///
  // TODO: Wire this into FailureDetector's SWIM refutation flow. When a
  // Suspicion message about the local node is received, FailureDetector
  // should call this method (via a callback or by accepting PeerService as
  // a dependency instead of PeerRegistry directly) to refute the suspicion
  // and persist the new incarnation number.
  Future<void> incrementLocalIncarnation() async {
    registry.incrementLocalIncarnation();
    await localNodeRepository.saveIncarnation(registry.localIncarnation);
  }

  /// Updates a peer's SWIM status (reachable/suspected/unreachable).
  ///
  /// Transitions peer through SWIM failure detection states and persists
  /// the change. Fires [PeerStatusChanged] domain event.
  ///
  /// Status transitions:
  /// - **reachable → suspected**: Direct probe failed
  /// - **suspected → unreachable**: Indirect probe failed
  /// - **suspected → reachable**: Probe response received
  /// - **unreachable → reachable**: Peer recovered (via refutation)
  ///
  /// Used when: FailureDetector processes probe results.
  ///
  /// Transaction: Update status in registry → retrieve entity → save to repository.
  Future<void> updatePeerStatus(NodeId peerId, PeerStatus newStatus) async {
    registry.updatePeerStatus(peerId, newStatus, occurredAt: DateTime.now());
    await _persistPeer(peerId);
  }

  /// Records successful contact with a peer (probe response).
  ///
  /// Updates the peer's last contact timestamp, used by FailureDetector to
  /// determine when to send next probe.
  ///
  /// Used when: Receiving Ack, PingReq response, or any message from peer.
  ///
  /// Transaction: Update contact time in registry → retrieve entity → save to repository.
  Future<void> recordPeerContact(NodeId peerId, int timestampMs) async {
    registry.updatePeerContact(peerId, timestampMs);
    await _persistPeer(peerId);
  }

  /// Records successful anti-entropy exchange with a peer.
  ///
  /// Updates the peer's last anti-entropy timestamp, used by GossipEngine to
  /// schedule next digest exchange.
  ///
  /// Used when: Completing 4-step digest/delta protocol with peer.
  ///
  /// Transaction: Update anti-entropy time in registry → retrieve entity → save to repository.
  Future<void> recordPeerAntiEntropy(NodeId peerId, int timestampMs) async {
    registry.updatePeerAntiEntropy(peerId, timestampMs);
    await _persistPeer(peerId);
  }

  /// Records a received message for rate limiting metrics.
  ///
  /// Updates the peer's sliding window metrics for incoming message rate.
  /// The library tracks these metrics but does not enforce rate limits;
  /// application can query metrics and take action.
  ///
  /// Used when: Receiving any protocol message from peer.
  ///
  /// Transaction: Record in registry metrics → retrieve entity → save to repository.
  Future<void> recordMessageReceived(
    NodeId peerId,
    int bytes,
    int nowMs,
    int windowDurationMs,
  ) async {
    registry.recordMessageReceived(peerId, bytes, nowMs, windowDurationMs);
    await _persistPeer(peerId);
  }

  /// Records a sent message for rate limiting metrics.
  ///
  /// Updates the peer's outgoing message byte counter. The library tracks
  /// these metrics but does not enforce rate limits; application can query
  /// metrics and take action.
  ///
  /// Used when: Sending any protocol message to peer.
  ///
  /// Transaction: Record in registry metrics → retrieve entity → save to repository.
  Future<void> recordMessageSent(NodeId peerId, int bytes) async {
    registry.recordMessageSent(peerId, bytes);
    await _persistPeer(peerId);
  }

  /// Persists peer to repository if repository exists and peer is found.
  Future<void> _persistPeer(NodeId peerId) async {
    if (repository == null) {
      _emitError(
        StorageSyncError(
          SyncErrorType.storageFailure,
          'Peer persistence skipped: no repository configured for peer $peerId',
          occurredAt: DateTime.now(),
        ),
      );
      return;
    }
    final peer = registry.getPeer(peerId);
    if (peer != null) {
      await repository!.save(peer);
    }
  }

  /// Deletes peer from repository if repository exists.
  Future<void> _deletePeer(NodeId peerId) async {
    if (repository == null) {
      _emitError(
        StorageSyncError(
          SyncErrorType.storageFailure,
          'Peer deletion skipped: no repository configured for peer $peerId',
          occurredAt: DateTime.now(),
        ),
      );
      return;
    }
    await repository!.delete(peerId);
  }
}
