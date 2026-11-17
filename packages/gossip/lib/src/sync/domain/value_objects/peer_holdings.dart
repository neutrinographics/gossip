import 'package:meta/meta.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';

/// What each peer has shown it holds: the channels it has named in its
/// digests, requests and responses alike.
///
/// Only a name is evidence. A dominance-filtered response may omit a channel,
/// so an omission teaches nothing, which is why holdings only grow. They are
/// cleared with the peer and never persisted: our own restart forgets them
/// and the peer's next digest teaches them again. They are sync's, not
/// membership's, because what a peer holds is a different fact from whether
/// it is alive.
@immutable
class PeerHoldings {
  /// The channels each peer has shown it holds. The map and every set in it
  /// are unmodifiable.
  final Map<NodeId, Set<ChannelId>> byPeer;

  const PeerHoldings._(this.byPeer);

  /// No peer has shown anything yet.
  static const PeerHoldings initial = PeerHoldings._({});

  /// The channels [peer] has shown it holds; empty for a peer that has shown
  /// nothing.
  Set<ChannelId> of(NodeId peer) => byPeer[peer] ?? const {};

  /// [peer] named [named]: those channels join its holdings. An empty [named]
  /// changes nothing.
  PeerHoldings learn(NodeId peer, Iterable<ChannelId> named) {
    if (named.isEmpty) return this;
    return PeerHoldings._(
      Map.unmodifiable({
        ...byPeer,
        peer: Set<ChannelId>.unmodifiable({...of(peer), ...named}),
      }),
    );
  }

  /// [peer] is gone and its holdings with it; an unknown peer answers the
  /// same value.
  PeerHoldings forget(NodeId peer) {
    if (!byPeer.containsKey(peer)) return this;
    return PeerHoldings._(Map.unmodifiable({...byPeer}..remove(peer)));
  }

  @override
  bool operator ==(Object other) {
    if (other is! PeerHoldings) return false;
    if (other.byPeer.length != byPeer.length) return false;
    for (final entry in byPeer.entries) {
      final theirs = other.byPeer[entry.key];
      if (theirs == null ||
          theirs.length != entry.value.length ||
          !theirs.containsAll(entry.value)) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode {
    var hash = 0;
    for (final entry in byPeer.entries) {
      var inner = 0;
      for (final c in entry.value) {
        inner ^= c.hashCode;
      }
      hash ^= Object.hash(entry.key, inner);
    }
    return hash;
  }

  @override
  String toString() => 'PeerHoldings(${byPeer.length} peers)';
}
