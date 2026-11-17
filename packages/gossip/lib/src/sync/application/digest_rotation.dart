import 'package:meta/meta.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/sync/application/peer_rotation.dart';

/// The budgeter's rotation state, not a domain concept: which items each peer
/// has been offered, and when, so that what does not fit one message goes in a
/// later one.
///
/// It remembers items, not positions. A position into a list that changes
/// shape skips or starves: the request list changes with the sender's
/// holdings, the response list with each request, the announcement list as
/// the peer shows what it holds, so a cursor that was right for one call
/// points at the wrong item on the next, and alternating shapes can leave
/// whole windows never advertised. A last-sent sequence per item is
/// independent of list shape: whatever the peer has gone longest without goes
/// first, in whichever list it appears.
///
/// It is per peer because every list is built for one peer, and one peer's
/// exchanges must not use up windows another peer never saw. It is bounded by
/// the items a peer has ever been offered, and cleared with the peer. A peer
/// absent from the map has been offered nothing.
///
/// The memory must not be pruned to the current list: the stamps of items
/// absent from this call's list are exactly what carries fairness across
/// alternating list shapes, and dropping them hands the same half of a list
/// out again — the starvation this value exists to end.
@immutable
class DigestRotation {
  final Map<NodeId, PeerRotation> byPeer;

  DigestRotation({Map<NodeId, PeerRotation> byPeer = const {}})
    : byPeer = Map.unmodifiable(byPeer);

  const DigestRotation._empty() : byPeer = const {};

  static const DigestRotation initial = DigestRotation._empty();

  PeerRotation of(NodeId peer) => byPeer[peer] ?? const PeerRotation();

  DigestRotation withPeer(NodeId peer, PeerRotation rotation) =>
      DigestRotation(byPeer: {...byPeer, peer: rotation});

  /// Forgets [peer], so a re-added peer is offered every item again from the
  /// start.
  DigestRotation forget(NodeId peer) =>
      DigestRotation(byPeer: {...byPeer}..remove(peer));

  @override
  bool operator ==(Object other) =>
      other is DigestRotation &&
      other.byPeer.length == byPeer.length &&
      byPeer.entries.every((e) => other.byPeer[e.key] == e.value);

  @override
  int get hashCode => Object.hashAllUnordered(
    byPeer.entries.map((e) => Object.hash(e.key, e.value)),
  );

  @override
  String toString() => 'DigestRotation(${byPeer.length} peers)';
}
