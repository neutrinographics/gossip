import 'package:gossip/gossip.dart' as gossip;

/// UI state for an indirect peer.
///
/// An indirect peer is a node we've learned about through synced data
/// but to which we don't have a direct connection.
class IndirectPeerState {
  final gossip.NodeId id;

  /// Display name derived from the node ID prefix.
  final String displayName;

  const IndirectPeerState({required this.id, required this.displayName});
}
