import 'package:gossip/gossip.dart';

/// Service for tracking indirect peers discovered via version vectors.
///
/// An indirect peer is a node that has authored entries we've synced,
/// but to which we don't have a direct connection. We learned about
/// these peers transitively through gossip with direct peers.
///
/// This service listens to [EntriesMerged] events and extracts author
/// information from version vectors to build a picture of the network.
class IndirectPeerService {
  final NodeId _localNodeId;
  final Set<NodeId> _knownAuthors = {};

  IndirectPeerService({required NodeId localNodeId})
    : _localNodeId = localNodeId;

  /// All remote authors we've seen in version vectors.
  ///
  /// This excludes the local node.
  Set<NodeId> get knownAuthors => Set.unmodifiable(_knownAuthors);

  /// Processes an [EntriesMerged] event to extract author information.
  ///
  /// Call this when receiving [EntriesMerged] domain events from the
  /// coordinator's event stream.
  void onEntriesMerged(VersionVector versionVector) {
    for (final nodeId in versionVector.entries.keys) {
      if (nodeId != _localNodeId) {
        _knownAuthors.add(nodeId);
      }
    }
  }

  /// Returns the set of indirect peers.
  ///
  /// Indirect peers are authors we've seen in version vectors but who
  /// are not in our set of direct peers.
  Set<NodeId> getIndirectPeers({required Set<NodeId> directPeerIds}) {
    return _knownAuthors.difference(directPeerIds);
  }

  /// Clears all tracked authors.
  ///
  /// Use when resetting state, e.g., when leaving all channels.
  void clear() {
    _knownAuthors.clear();
  }
}
