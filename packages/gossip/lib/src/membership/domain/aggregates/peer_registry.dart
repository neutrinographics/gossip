import 'dart:math';

import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/membership/domain/entities/peer.dart';
import 'package:gossip/src/membership/domain/entities/peer_metrics.dart';
import 'package:gossip/src/shared/domain/events/domain_event.dart';
import 'package:gossip/src/membership/domain/events/membership_events.dart';
import 'package:gossip/src/membership/domain/value_objects/peer_status.dart';

/// Aggregate root managing peer membership and SWIM failure detection state.
///
/// [PeerRegistry] is the authoritative source for all peer-related state in
/// the gossip system. It enforces invariants, tracks SWIM protocol state
/// transitions, and emits domain events for state changes.
///
/// ## Responsibilities
/// - **Membership management**: Add/remove peers, prevent duplicate entries
/// - **SWIM failure detection**: Track probe failures, status transitions
/// - **Contact tracking**: Record last message and anti-entropy timestamps
/// - **Metrics collection**: Track communication statistics per peer
///
/// ## SWIM State Transitions
/// Peers progress through these states:
/// 1. **reachable** → **suspected**: After probe failures exceed threshold
/// 2. **suspected** → **unreachable**: After indirect probe also fails
/// 3. **suspected** → **reachable**: On successful contact (probe response)
///
/// ## Invariants
/// - Local node cannot be added as a peer
/// - Peer IDs are unique within the registry
/// - Status transitions are managed through updatePeerStatus()
///
/// ## Domain Events
/// Emits events for observability and event sourcing:
/// - [PeerAdded], [PeerRemoved], [PeerStatusChanged]
class PeerRegistry {
  /// The local node ID (this node cannot be added as a peer).
  final NodeId localNode;

  final Map<NodeId, Peer> _peers = {};
  final List<DomainEvent> _uncommittedEvents = [];

  /// Optional sink for domain events.
  ///
  /// When set, events are forwarded here immediately instead of being
  /// buffered in [uncommittedEvents]. A long-lived registry (this is a
  /// singleton, unlike per-operation channel aggregates) MUST have a sink
  /// in production: buffered events with no consumer grow without bound.
  final void Function(DomainEvent)? onEvent;

  /// Creates a [PeerRegistry] for the given local node.
  PeerRegistry({
    required this.localNode,
    this.onEvent,
  });

  /// Private constructor for reconstitute — no events.
  PeerRegistry._reconstitute({
    required this.localNode,
  }) : onEvent = null;

  /// Restores a previously persisted peer registry.
  ///
  /// Unlike the default constructor followed by [addPeer] calls, this does
  /// NOT emit domain events (no [PeerAdded]) since this represents loading
  /// existing state, not creating new state.
  ///
  /// The caller provides the full list of [peers] with all their state
  /// (status, metrics, etc.) as previously persisted.
  factory PeerRegistry.reconstitute({
    required NodeId localNode,
    required List<Peer> peers,
  }) {
    final registry = PeerRegistry._reconstitute(localNode: localNode);
    for (final peer in peers) {
      registry._peers[peer.id] = peer;
    }
    return registry;
  }

  /// Returns true if a peer with the given ID is registered.
  bool isKnown(NodeId id) => _peers.containsKey(id);

  /// Returns true if the peer is registered and has reachable status.
  bool isReachable(NodeId id) => _peers[id]?.status == PeerStatus.reachable;

  /// Returns the total number of registered peers.
  int get peerCount => _peers.length;

  /// Returns the peer entity for the given ID, or null if not found.
  Peer? getPeer(NodeId id) => _peers[id];

  /// Returns the metrics for the given peer, or null if not found.
  PeerMetrics? getMetrics(NodeId id) => _peers[id]?.metrics;

  /// Returns all registered peers.
  List<Peer> get allPeers => _peers.values.toList();

  /// Returns only peers with reachable status.
  ///
  /// Used for selecting peers for gossip rounds and message routing.
  List<Peer> get reachablePeers =>
      _peers.values.where((p) => p.status == PeerStatus.reachable).toList();

  /// Selects a random reachable peer.
  ///
  /// Uses the provided [random] generator to ensure even distribution of
  /// selections over time. Only considers peers in [PeerStatus.reachable] status.
  ///
  /// Returns null if no reachable peers exist.
  ///
  /// Used by: GossipEngine for peer selection (gossip only with reachable peers).
  Peer? selectRandomReachablePeer(Random random) {
    final reachable = reachablePeers;
    if (reachable.isEmpty) return null;
    return reachable[random.nextInt(reachable.length)];
  }

  /// Returns peers with unreachable status.
  ///
  /// Used by FailureDetector for periodic unreachable peer probing
  /// to break mutual-unreachable deadlocks.
  List<Peer> get unreachablePeers =>
      _peers.values.where((p) => p.status == PeerStatus.unreachable).toList();

  /// Returns peers that can be probed (reachable or suspected).
  ///
  /// Excludes unreachable peers as they have exceeded the suspicion window.
  /// Suspected peers are included to allow them to recover by responding.
  ///
  /// Used by: FailureDetector for probe target selection.
  List<Peer> get probablePeers => _peers.values
      .where(
        (p) =>
            p.status == PeerStatus.reachable ||
            p.status == PeerStatus.suspected,
      )
      .toList();

  /// Returns buffered domain events (only populated when no [onEvent]
  /// sink is set).
  ///
  /// Applications can observe these events for logging, metrics, or
  /// event sourcing. Events accumulate until drained via
  /// [takeUncommittedEvents].
  List<DomainEvent> get uncommittedEvents =>
      List.unmodifiable(_uncommittedEvents);

  /// Drains and returns all buffered events.
  ///
  /// Once taken, events are gone from the registry — this is how a
  /// consumer without an [onEvent] sink prevents unbounded buffering.
  List<DomainEvent> takeUncommittedEvents() {
    final events = List<DomainEvent>.unmodifiable(_uncommittedEvents);
    _uncommittedEvents.clear();
    return events;
  }

  void _addEvent(DomainEvent event) {
    final sink = onEvent;
    if (sink != null) {
      sink(event);
    } else {
      _uncommittedEvents.add(event);
    }
  }

  /// Adds a new peer to the registry with reachable status.
  ///
  /// If the peer already exists and is suspected or unreachable, recovers
  /// it to reachable — this is called on transport reconnection, which is
  /// proof of life. No-op if the peer is already reachable.
  ///
  /// If [displayName] is not provided, defaults to a truncated form of the
  /// node ID.
  ///
  /// Throws if attempting to add the local node as a peer.
  ///
  /// Emits: [PeerAdded] for new peers, [PeerStatusChanged] for recovered peers.
  void addPeer(NodeId id, {String? displayName, required DateTime occurredAt}) {
    if (id == localNode) {
      throw Exception('Cannot add local node as peer');
    }
    final existing = _peers[id];
    if (existing != null) {
      // Peer already exists. If unreachable or suspected, recover it —
      // addPeer is called on transport reconnection, which is proof of life.
      if (existing.status != PeerStatus.reachable) {
        updatePeerStatus(id, PeerStatus.reachable, occurredAt: occurredAt);
        _peers[id] = _peers[id]!.copyWith(failedProbeCount: 0);
      }
      return;
    }
    _peers[id] = Peer(id: id, displayName: displayName);
    _addEvent(PeerAdded(id, occurredAt: occurredAt));
  }

  /// Removes a peer from the registry.
  ///
  /// No-op if the peer doesn't exist.
  ///
  /// Emits: [PeerRemoved] event.
  void removePeer(NodeId id, {required DateTime occurredAt}) {
    if (_peers.remove(id) != null) {
      _addEvent(PeerRemoved(id, occurredAt: occurredAt));
    }
  }

  /// Updates a peer's reachability status.
  ///
  /// Used by SWIM failure detection to transition peers through states:
  /// - reachable → suspected (after probe failures)
  /// - suspected → unreachable (after indirect probe fails)
  /// - suspected → reachable (on successful contact)
  ///
  /// No-op if peer doesn't exist or status is unchanged.
  ///
  /// Emits: [PeerStatusChanged] event.
  void updatePeerStatus(
    NodeId id,
    PeerStatus newStatus, {
    required DateTime occurredAt,
  }) {
    final peer = _peers[id];
    if (peer == null) {
      _addEvent(
        PeerOperationSkipped(id, 'updatePeerStatus', occurredAt: occurredAt),
      );
      return;
    }
    final oldStatus = peer.status;
    if (oldStatus == newStatus) return;
    _peers[id] = peer.copyWith(status: newStatus);
    _addEvent(
      PeerStatusChanged(id, oldStatus, newStatus, occurredAt: occurredAt),
    );
  }

  /// Updates the last contact timestamp for a peer.
  ///
  /// Records successful contact with a peer (received an Ack or Ping).
  /// Resets the failed probe count and recovers the peer to reachable if
  /// suspected or unreachable, emitting a [PeerStatusChanged] event.
  ///
  /// Silently no-ops if the peer doesn't exist — contact recording fires
  /// per message, and a removed peer's transport may still deliver;
  /// emitting an event per message would grow without bound.
  void updatePeerContact(NodeId id, int timestampMs) {
    final peer = _peers[id];
    if (peer == null) {
      return;
    }

    // Recover to reachable if suspected or unreachable.
    // Delegate to updatePeerStatus() so PeerStatusChanged is emitted.
    if (peer.status != PeerStatus.reachable) {
      updatePeerStatus(id, PeerStatus.reachable, occurredAt: DateTime.now());
    }

    // Update contact time and reset failed probe count.
    // Re-read peer since updatePeerStatus may have modified it.
    final current = _peers[id];
    if (current != null) {
      _peers[id] = current.copyWith(
        lastContactMs: timestampMs,
        failedProbeCount: 0,
      );
    }
  }

  /// Updates the last anti-entropy timestamp for a peer.
  ///
  /// Records when we last performed gossip synchronization with this peer.
  /// Used for peer selection (prefer peers we haven't synced with recently).
  ///
  /// Silently no-ops if the peer doesn't exist (telemetry recording for
  /// unknown peers is routine churn, not a domain event).
  void updatePeerAntiEntropy(NodeId id, int timestampMs) {
    final peer = _peers[id];
    if (peer == null) {
      return;
    }
    _peers[id] = peer.copyWith(lastAntiEntropyMs: timestampMs);
  }

  /// Records a received message for metrics tracking.
  ///
  /// Updates the peer's communication metrics including sliding window
  /// for rate limiting. Applications can use metrics to implement
  /// throttling or detect abusive peers.
  ///
  /// Silently no-ops if the peer doesn't exist — this fires for EVERY
  /// incoming message, including from freshly removed peers whose
  /// transport still delivers; one event per message is an unbounded leak.
  void recordMessageReceived(
    NodeId id,
    int bytes,
    int nowMs,
    int windowDurationMs,
  ) {
    final peer = _peers[id];
    if (peer == null) {
      return;
    }
    _peers[id] = peer.copyWith(
      metrics: peer.metrics.recordReceived(bytes, nowMs, windowDurationMs),
    );
  }

  /// Records a sent message for metrics tracking.
  ///
  /// Updates lifetime message and byte counts. Used for monitoring
  /// and debugging communication patterns.
  ///
  /// Silently no-ops if the peer doesn't exist (per-message telemetry;
  /// see [recordMessageReceived]).
  void recordMessageSent(NodeId id, int bytes) {
    final peer = _peers[id];
    if (peer == null) {
      return;
    }
    _peers[id] = peer.copyWith(metrics: peer.metrics.recordSent(bytes));
  }

  /// Records an RTT sample for a peer.
  ///
  /// Updates the peer's per-peer RTT estimate using EWMA smoothing.
  /// Used for per-peer probe timeouts in failure detection.
  ///
  /// Silently no-ops if the peer doesn't exist (per-probe telemetry;
  /// see [recordMessageReceived]).
  void recordPeerRtt(NodeId id, Duration sample) {
    final peer = _peers[id];
    if (peer == null) {
      return;
    }
    _peers[id] = peer.copyWith(metrics: peer.metrics.recordRttSample(sample));
  }


  /// Increments the failed probe count for a peer.
  ///
  /// Called when a direct probe (ping) to this peer fails. The failure
  /// detector uses this count to decide when to suspect a peer.
  ///
  /// Typical threshold: 1-3 failed probes before suspecting.
  ///
  /// Silently no-ops if the peer doesn't exist (per-probe telemetry;
  /// see [recordMessageReceived]).
  void incrementFailedProbeCount(NodeId id) {
    final peer = _peers[id];
    if (peer == null) {
      return;
    }
    _peers[id] = peer.copyWith(failedProbeCount: peer.failedProbeCount + 1);
  }
}
