import 'dart:math';

import '../../domain/aggregates/peer_registry.dart';
import '../../domain/entities/peer.dart';
import '../../domain/value_objects/node_id.dart';
import '../domain/interfaces/peer_directory.dart';
import '../domain/value_objects/sync_partner.dart';

/// Anti-corruption layer adapting membership's [PeerRegistry] to sync's
/// [PeerDirectory] port.
///
/// This is the ONLY file in the sync context that imports membership types
/// ([PeerRegistry], [Peer]) — every other sync file (in particular
/// `GossipEngine`) sees peers only through [SyncPartner] and [PeerDirectory].
///
/// Every method is a pure forward/map: no new selection or mutation
/// semantics are introduced here. In particular, [selectRandomPartner]
/// delegates to [PeerRegistry.selectRandomReachablePeer] rather than
/// reimplementing its selection behavior.
class MembershipPeerDirectory implements PeerDirectory {
  MembershipPeerDirectory(this._registry);

  final PeerRegistry _registry;

  @override
  List<SyncPartner> reachablePartners() =>
      _registry.reachablePeers.map(_toPartner).toList();

  @override
  SyncPartner? selectRandomPartner(Random random) {
    final peer = _registry.selectRandomReachablePeer(random);
    return peer == null ? null : _toPartner(peer);
  }

  @override
  void recordContact(NodeId peer, int nowMs) {
    _registry.updatePeerContact(peer, nowMs);
  }

  @override
  void recordMessageReceived(
    NodeId peer,
    int bytes,
    int nowMs,
    int windowMs,
  ) {
    _registry.recordMessageReceived(peer, bytes, nowMs, windowMs);
  }

  @override
  void recordMessageSent(NodeId peer, int bytes) {
    _registry.recordMessageSent(peer, bytes);
  }

  @override
  void recordAntiEntropy(NodeId peer, int nowMs) {
    _registry.updatePeerAntiEntropy(peer, nowMs);
  }

  /// Maps a membership [Peer] to sync's own [SyncPartner] view.
  SyncPartner _toPartner(Peer peer) {
    return SyncPartner(
      nodeId: peer.id,
      smoothedRtt: peer.metrics.rttEstimate?.smoothedRtt,
      lastAntiEntropyMs: peer.lastAntiEntropyMs,
    );
  }
}
