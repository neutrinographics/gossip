import 'package:gossip/src/domain/errors/sync_error.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/domain/interfaces/peer_repository.dart';

/// Application service for peer membership: add, remove, query.
///
/// ## Persistence contract (memory-only SWIM state — by design)
///
/// Only membership itself (add/remove) reaches [PeerRepository].
/// SWIM-driven state — reachability status, contact times, RTT and
/// traffic metrics — lives exclusively in the in-memory [PeerRegistry]
/// and is NEVER persisted: it is ephemeral runtime observation that is
/// meaningless across restarts. A persistent [PeerRepository]
/// implementation therefore sees peers appear and disappear, nothing
/// else. (Owner decision, 2026-08-21 — see
/// docs/superpowers/specs/2026-08-21-architecture-honesty-fixes-design.md.)
///
/// Used by: the Coordinator facade (peer add/remove orchestration).
/// The protocol layer deliberately does NOT go through this service.
class PeerService {
  /// The peer registry aggregate managing all peer state.
  ///
  /// Injected instance serves as single source of truth for peer state.
  final PeerRegistry registry;

  /// Optional persistence layer for [Peer] entities.
  ///
  /// When null, peers are not persisted (in-memory only).
  final PeerRepository? repository;

  /// Optional callback for reporting synchronization errors.
  ///
  /// When provided, errors that would otherwise be silent are reported
  /// through this callback for observability.
  final ErrorCallback? onError;

  PeerService({
    required this.registry,
    this.repository,
    this.onError,
  });

  /// Per-peer chain of pending persistence writes.
  ///
  /// Saves for the same peer are serialized, and each save snapshots the
  /// registry state at WRITE time (inside the chain). Without this, two
  /// overlapping mutations each snapshot at call time and race their I/O
  /// — a slow older save landing after a fast newer one persists a stale
  /// snapshot that surfaces on restart.
  final Map<NodeId, Future<void>> _saveQueue = {};

  /// Emits an error through the callback if one is registered.
  void _emitError(SyncError error) {
    onError?.call(error);
  }

  /// Adds a new peer to the registry.
  ///
  /// Creates a new [Peer] entity in [reachable] status and persists it.
  /// Fires [PeerAdded] domain event.
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

  /// Persists peer to repository if repository exists and peer is found.
  ///
  /// Writes for the same peer are chained so they hit storage in order,
  /// each persisting the freshest registry snapshot at write time.
  Future<void> _persistPeer(NodeId peerId) {
    if (repository == null) {
      _emitError(
        StorageSyncError(
          SyncErrorType.storageFailure,
          'Peer persistence skipped: no repository configured for peer $peerId',
          occurredAt: DateTime.now(),
        ),
      );
      return Future.value();
    }

    final previous = _saveQueue[peerId] ?? Future<void>.value();
    final task = previous.catchError((_) {}).then((_) async {
      // Snapshot inside the chain: by the time this runs, the registry
      // holds the newest state, so the last write always wins.
      final peer = registry.getPeer(peerId);
      if (peer != null) {
        await repository!.save(peer);
      }
    });
    _saveQueue[peerId] = task;
    return task.whenComplete(() {
      if (identical(_saveQueue[peerId], task)) {
        _saveQueue.remove(peerId);
      }
    });
  }

  /// Deletes peer from repository if repository exists.
  ///
  /// Chained through the same per-peer queue as saves: a save that already
  /// passed its registry snapshot and is inside the repository write when
  /// the peer is removed would otherwise land after the delete and
  /// resurrect the peer in persistent storage.
  Future<void> _deletePeer(NodeId peerId) {
    if (repository == null) {
      _emitError(
        StorageSyncError(
          SyncErrorType.storageFailure,
          'Peer deletion skipped: no repository configured for peer $peerId',
          occurredAt: DateTime.now(),
        ),
      );
      return Future.value();
    }

    final previous = _saveQueue[peerId] ?? Future<void>.value();
    final task = previous.catchError((_) {}).then((_) {
      return repository!.delete(peerId);
    });
    _saveQueue[peerId] = task;
    return task.whenComplete(() {
      if (identical(_saveQueue[peerId], task)) {
        _saveQueue.remove(peerId);
      }
    });
  }
}
