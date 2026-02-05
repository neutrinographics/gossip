import 'package:gossip/gossip.dart' as gossip;

import '../../application/services/indirect_peer_service.dart';

/// UI state for an indirect peer.
///
/// An indirect peer is a node we've learned about through synced data
/// but to which we don't have a direct connection.
class IndirectPeerState {
  final gossip.NodeId id;

  /// Display name derived from the node ID prefix.
  final String displayName;

  /// When we last received an entry from this peer.
  final DateTime? lastSeenAt;

  /// Activity status based on entry recency.
  final IndirectPeerActivityStatus activityStatus;

  const IndirectPeerState({
    required this.id,
    required this.displayName,
    this.lastSeenAt,
    this.activityStatus = IndirectPeerActivityStatus.unknown,
  });
}
