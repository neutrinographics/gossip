import '../../domain/value_objects/node_id.dart';
import '../../domain/value_objects/channel_id.dart';
import '../../domain/entities/peer.dart';

/// Service interface for protocol services to interact with coordinator state.
///
/// [SyncCoordinatorService] provides a clean boundary between protocol
/// implementations (GossipEngine, FailureDetector) and the Coordinator facade.
/// It abstracts coordinator operations that protocols need without exposing
/// the full Coordinator API.
///
/// This follows the Dependency Inversion Principle - protocols depend on this
/// interface, not on the concrete Coordinator implementation.
abstract interface class SyncCoordinatorService {
  /// Returns the local node identifier.
  NodeId get localNode;

  /// Returns the local node's current incarnation number.
  int get localIncarnation;

  /// Returns all reachable peers for gossip/probe selection.
  List<Peer> get reachablePeers;

  /// Returns a specific peer by ID, or null if not found.
  Peer? getPeer(NodeId id);

  /// Returns all channel IDs managed by this coordinator.
  List<ChannelId> get channelIds;
}
