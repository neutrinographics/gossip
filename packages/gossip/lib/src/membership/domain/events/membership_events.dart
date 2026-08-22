import 'package:gossip/src/shared/domain/events/domain_event.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/membership/domain/value_objects/peer_status.dart';

/// Sealed family root for domain events emitted by the membership context
/// (peer registry, SWIM failure detection).
///
/// Every membership-context event extends [MembershipEvent], which itself
/// extends the shared [DomainEvent] base. Consumers of the public
/// `Stream<DomainEvent>` are unaffected by this split — they still see every
/// event, regardless of which context family it belongs to.
sealed class MembershipEvent extends DomainEvent {
  const MembershipEvent({required super.occurredAt});
}

// ─────────────────────────────────────────────────────────────
// Peer Events
// ─────────────────────────────────────────────────────────────

/// Emitted when a new peer is added to the peer registry.
///
/// Fired when: [PeerRegistry.addPeer] successfully adds a new peer.
final class PeerAdded extends MembershipEvent {
  final NodeId peerId;

  const PeerAdded(this.peerId, {required super.occurredAt});
}

/// Emitted when a peer is removed from the peer registry.
///
/// Fired when: [PeerRegistry.removePeer] removes an existing peer.
final class PeerRemoved extends MembershipEvent {
  final NodeId peerId;

  const PeerRemoved(this.peerId, {required super.occurredAt});
}

/// Emitted when a peer's reachability status changes.
///
/// Fired when: [PeerRegistry.updatePeerStatus] changes a peer's status.
/// Common transitions:
/// - reachable → suspected (probe failure)
/// - suspected → unreachable (indirect probe also failed)
/// - suspected → reachable (peer recovered or refuted suspicion)
final class PeerStatusChanged extends MembershipEvent {
  final NodeId peerId;
  final PeerStatus oldStatus;
  final PeerStatus newStatus;

  const PeerStatusChanged(
    this.peerId,
    this.oldStatus,
    this.newStatus, {
    required super.occurredAt,
  });
}

/// Emitted when an operation on a peer is skipped because the peer is not found.
///
/// Fired when: Operations like [updatePeerStatus], [updatePeerContact], etc.
/// are called for a peer that doesn't exist in the registry. This is for
/// observability only - not an error, just a trace event.
final class PeerOperationSkipped extends MembershipEvent {
  final NodeId peerId;
  final String operation;

  const PeerOperationSkipped(
    this.peerId,
    this.operation, {
    required super.occurredAt,
  });
}
