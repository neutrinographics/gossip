import 'package:meta/meta.dart';

import '../value_objects/node_id.dart';
import '../events/domain_event.dart';
import 'peer_metrics.dart';

/// Represents a peer in the gossip network with its state and metrics.
///
/// A [Peer] entity tracks all state for a remote node participating in
/// gossip, including:
/// - **Identity**: Unique node identifier
/// - **Reachability**: Current status from SWIM failure detection
/// - **Incarnation**: Version number for refuting false failure suspicions
/// - **Contact tracking**: Last communication and anti-entropy timestamps
/// - **Failure detection**: Consecutive probe failure count
/// - **Metrics**: Communication statistics for rate limiting
///
/// Peers are managed by the [PeerRegistry] aggregate, which enforces
/// invariants and emits domain events for state changes.
///
/// Entities are compared by identity (NodeId) and state equality.
@immutable
class Peer {
  /// Unique identifier for this peer.
  final NodeId id;

  /// Human-readable display name for this peer.
  ///
  /// Provided during peer discovery/handshake. If not provided, defaults
  /// to a truncated form of the node ID.
  final String displayName;

  /// Current reachability status from SWIM failure detection.
  ///
  /// Lifecycle: reachable → suspected → unreachable
  final PeerStatus status;

  /// Incarnation number for refuting false failure suspicions.
  ///
  /// When a peer suspects itself as failed, it increments its incarnation
  /// number and broadcasts it to refute the suspicion. Null until first
  /// incarnation message is received.
  final int? incarnation;

  /// Last time we received any message from this peer (milliseconds since epoch).
  final int lastContactMs;

  /// Last time we performed anti-entropy (gossip) with this peer (milliseconds since epoch).
  ///
  /// Null if we've never gossiped with this peer. Used to prioritize peers
  /// that haven't synced recently.
  final int? lastAntiEntropyMs;

  /// Consecutive probe failures in SWIM failure detection.
  ///
  /// Incremented on each failed probe, reset on successful contact.
  /// When this exceeds a threshold, the peer transitions to suspected.
  final int failedProbeCount;

  /// Communication metrics for this peer.
  final PeerMetrics metrics;

  /// Prefix length for default display name derived from node ID.
  static const int _defaultDisplayNameLength = 8;

  /// Creates a [Peer] with the given state.
  ///
  /// If [displayName] is not provided, defaults to the first 8 characters
  /// of the node ID.
  Peer({
    required this.id,
    String? displayName,
    this.status = PeerStatus.reachable,
    this.incarnation,
    this.lastContactMs = 0,
    this.lastAntiEntropyMs,
    this.failedProbeCount = 0,
    this.metrics = const PeerMetrics(),
  }) : displayName = displayName ?? _truncateId(id.value);

  /// Truncates an ID to the default display name length.
  static String _truncateId(String id) {
    return id.length > _defaultDisplayNameLength
        ? id.substring(0, _defaultDisplayNameLength)
        : id;
  }

  /// Creates a copy of this Peer with specified fields replaced.
  Peer copyWith({
    NodeId? id,
    String? displayName,
    PeerStatus? status,
    int? incarnation,
    int? lastContactMs,
    int? lastAntiEntropyMs,
    int? failedProbeCount,
    PeerMetrics? metrics,
  }) {
    return Peer(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      status: status ?? this.status,
      incarnation: incarnation ?? this.incarnation,
      lastContactMs: lastContactMs ?? this.lastContactMs,
      lastAntiEntropyMs: lastAntiEntropyMs ?? this.lastAntiEntropyMs,
      failedProbeCount: failedProbeCount ?? this.failedProbeCount,
      metrics: metrics ?? this.metrics,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Peer &&
        other.id == id &&
        other.displayName == displayName &&
        other.status == status &&
        other.incarnation == incarnation &&
        other.lastContactMs == lastContactMs &&
        other.lastAntiEntropyMs == lastAntiEntropyMs &&
        other.failedProbeCount == failedProbeCount &&
        other.metrics == metrics;
  }

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    status,
    incarnation,
    lastContactMs,
    lastAntiEntropyMs,
    failedProbeCount,
    metrics,
  );

  @override
  String toString() =>
      'Peer($id, displayName: $displayName, status: $status, '
      'incarnation: $incarnation, failedProbes: $failedProbeCount)';
}
