import 'dart:math';

import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/sync/domain/value_objects/sync_partner.dart';

/// Sync's port onto peer state: THE sync↔membership contract.
///
/// `GossipEngine` (the sync context's protocol service) depends on this
/// interface rather than membership's `PeerRegistry`/`Peer` types directly —
/// the one boundary-rule concession that keeps the sync context from naming
/// any membership type. Implemented by `MembershipPeerDirectory`, an ACL in
/// `sync/infrastructure/` that wraps a real `PeerRegistry`.
///
/// Each method mirrors the exact parameter list of the `PeerRegistry` method
/// the engine calls today, so the ACL can be a pure pass-through/mapping —
/// no new semantics are introduced at this seam.
///
/// Designed to be extended with piggybacked liveness data; keep the
/// pass-through purity when extending.
abstract interface class PeerDirectory {
  /// All partners currently reachable for gossip (mirrors
  /// `PeerRegistry.reachablePeers`).
  List<SyncPartner> reachablePartners();

  /// Selects a random reachable partner using [random], or null if none are
  /// reachable. Delegates to `PeerRegistry.selectRandomReachablePeer` —
  /// implementations must preserve that method's selection semantics
  /// exactly rather than reimplementing them.
  SyncPartner? selectRandomPartner(Random random);

  /// Records successful contact with [peer] at [nowMs] (mirrors
  /// `PeerRegistry.updatePeerContact`) — proof of life for SWIM liveness.
  void recordContact(NodeId peer, int nowMs);

  /// Records a received message from [peer] for metrics/rate-limiting
  /// (mirrors `PeerRegistry.recordMessageReceived`).
  void recordMessageReceived(NodeId peer, int bytes, int nowMs, int windowMs);

  /// Records a sent message to [peer] for metrics (mirrors
  /// `PeerRegistry.recordMessageSent`).
  void recordMessageSent(NodeId peer, int bytes);

  /// Records that anti-entropy was just performed with [peer] at [nowMs]
  /// (mirrors `PeerRegistry.updatePeerAntiEntropy`) — used to bound gossip
  /// coverage and drive recency suppression.
  void recordAntiEntropy(NodeId peer, int nowMs);
}
