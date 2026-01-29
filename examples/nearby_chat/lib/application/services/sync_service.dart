import 'dart:async';

import 'package:gossip/gossip.dart';

/// Service that exposes synchronization state and events to the presentation layer.
///
/// This abstracts the Coordinator from the UI, providing only the observability
/// and state access needed by the presentation layer.
class SyncService {
  final Coordinator _coordinator;

  SyncService({required Coordinator coordinator}) : _coordinator = coordinator;

  // ─────────────────────────────────────────────────────────────
  // Event Streams
  // ─────────────────────────────────────────────────────────────

  /// Stream of domain events for UI updates.
  Stream<DomainEvent> get events => _coordinator.events;

  /// Stream of sync errors for observability.
  Stream<SyncError> get errors => _coordinator.errors;

  // ─────────────────────────────────────────────────────────────
  // Peer State
  // ─────────────────────────────────────────────────────────────

  /// Gets all registered peers.
  List<Peer> get peers => _coordinator.peers;

  /// Gets only reachable peers.
  List<Peer> get reachablePeers => _coordinator.reachablePeers;

  /// Gets metrics for a specific peer.
  PeerMetrics? getPeerMetrics(NodeId id) => _coordinator.getPeerMetrics(id);

  // ─────────────────────────────────────────────────────────────
  // Sync State
  // ─────────────────────────────────────────────────────────────

  /// Current sync state.
  SyncState get state => _coordinator.state;

  /// Local node incarnation number.
  int get localIncarnation => _coordinator.localIncarnation;

  // ─────────────────────────────────────────────────────────────
  // Health & Metrics
  // ─────────────────────────────────────────────────────────────

  /// Gets comprehensive health status.
  Future<HealthStatus> getHealth() => _coordinator.getHealth();

  /// Gets resource usage statistics.
  Future<ResourceUsage> getResourceUsage() => _coordinator.getResourceUsage();
}
