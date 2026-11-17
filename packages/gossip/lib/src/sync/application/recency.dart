import 'package:meta/meta.dart';
import 'package:gossip/src/sync/application/rotation_key.dart';

/// When each item was last offered to one peer in one list, as a sequence
/// number that only grows. Ordering by it puts every item the peer has not
/// seen for longest first, whatever list the item appears in and however that
/// list has changed since; a position into the list cannot promise that.
///
/// It holds one entry per item the peer has ever been offered, and is cleared
/// with the peer.
@immutable
class Recency {
  final Map<RotationKey, int> lastSent;
  final int next;

  Recency({Map<RotationKey, int> lastSent = const {}, this.next = 0})
    : lastSent = Map.unmodifiable(lastSent);

  const Recency._empty() : lastSent = const {}, next = 0;

  static const Recency initial = Recency._empty();

  /// The sequence of [key]'s last send, or null when it was never sent.
  int? sentAt(RotationKey key) => lastSent[key];

  /// Marks [keys] sent now, in order: each takes the next sequence, so a later
  /// one in the window is newer.
  Recency stamp(Iterable<RotationKey> keys) {
    var sequence = next;
    final stamped = Map<RotationKey, int>.of(lastSent);
    for (final key in keys) {
      stamped[key] = sequence++;
    }
    return Recency(lastSent: stamped, next: sequence);
  }

  @override
  bool operator ==(Object other) =>
      other is Recency &&
      other.next == next &&
      other.lastSent.length == lastSent.length &&
      lastSent.entries.every((e) => other.lastSent[e.key] == e.value);

  @override
  int get hashCode => Object.hash(
    next,
    Object.hashAllUnordered(
      lastSent.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );

  @override
  String toString() => 'Recency(next: $next, ${lastSent.length} items)';
}
