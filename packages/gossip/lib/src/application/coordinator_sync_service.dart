import '../domain/value_objects/node_id.dart';
import '../domain/value_objects/channel_id.dart';
import '../domain/entities/peer.dart';
import '../facade/coordinator.dart';
import 'interfaces/sync_coordinator_service.dart';

/// Implementation of [SyncCoordinatorService] that delegates to [Coordinator].
///
/// [CoordinatorSyncService] acts as an adapter, allowing protocol services
/// to interact with coordinator state through a clean interface without
/// depending directly on the Coordinator facade.
///
/// This service can be injected into protocol implementations (GossipEngine,
/// FailureDetector) to give them access to peer and channel information.
class CoordinatorSyncService implements SyncCoordinatorService {
  final Coordinator _coordinator;

  CoordinatorSyncService(this._coordinator);

  @override
  NodeId get localNode => _coordinator.localNode;

  @override
  int get localIncarnation => _coordinator.localIncarnation;

  @override
  List<Peer> get reachablePeers => _coordinator.reachablePeers;

  @override
  Peer? getPeer(NodeId id) {
    return _coordinator.peers.where((p) => p.id == id).firstOrNull;
  }

  @override
  List<ChannelId> get channelIds => _coordinator.channelIds;
}
