import 'package:gossip/src/sync/application/recency.dart';
import 'package:gossip/src/sync/application/rotation_key.dart';

/// What [DigestWindow.select] chose: [usedBytes] is what the selected items
/// take, separators between them included.
class Window<T> {
  final List<T> selected;
  final List<T> oversized;
  final int usedBytes;

  Window({
    required List<T> selected,
    required List<T> oversized,
    this.usedBytes = 0,
  }) : selected = List.unmodifiable(selected),
       oversized = List.unmodifiable(oversized);
}

/// The budgeter's mechanism, not a domain concept: a window selection over
/// sized items.
///
/// Candidates are ordered by [Recency] ascending — never sent first, then the
/// one sent longest ago — ties by list order, so a peer is offered what it has
/// waited longest for whatever shape the list has now. The window is the
/// longest prefix of that order whose costs fit the budget: it stops at the
/// first item that does not fit the room left. An item alone over the budget
/// can never be sent: it is skipped and reported, and blocks nothing.
///
/// The costs handed in are standalone sizes: what each item would add to a
/// message that carried nothing else. The window owns the separator between
/// the items it selects, charging one for every item that has a predecessor in
/// the window. So an item is oversized by its bare cost (alone it needs no
/// separator, and may fill the budget exactly), while a neighbour is charged
/// its cost plus the separator joining it.
abstract final class DigestWindow {
  /// Sorts before every real sequence.
  static const int _neverSent = -1;

  /// One byte joins each element of the wire array to its predecessor.
  static const int _separatorBytes = 1;

  /// [costs] and [keys] parallel [items]; [budget] is the bytes available to
  /// them; [recency] the peer's record for this list.
  static Window<T> select<T>({
    required List<T> items,
    required List<int> costs,
    required List<RotationKey> keys,
    required Recency recency,
    required int budget,
  }) {
    if (costs.length != items.length || keys.length != items.length) {
      throw ArgumentError(
        'items, costs and keys must be the same length '
        '(${items.length}, ${costs.length}, ${keys.length})',
      );
    }
    final order = List<int>.generate(items.length, (i) => i)
      ..sort((x, y) {
        final byRecency = (recency.sentAt(keys[x]) ?? _neverSent).compareTo(
          recency.sentAt(keys[y]) ?? _neverSent,
        );
        return byRecency != 0 ? byRecency : x.compareTo(y);
      });

    final selected = <T>[];
    final oversized = <T>[];
    var used = 0;

    for (final index in order) {
      final cost = costs[index];

      if (cost > budget) {
        oversized.add(items[index]);
        continue;
      }

      final charged = cost + (selected.isEmpty ? 0 : _separatorBytes);
      if (used + charged > budget) break;

      selected.add(items[index]);
      used += charged;
    }

    return Window(selected: selected, oversized: oversized, usedBytes: used);
  }
}
