import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/sync/application/digest_window.dart';
import 'package:gossip/src/sync/application/recency.dart';
import 'package:gossip/src/sync/application/rotation_key.dart';
import 'package:test/test.dart';

/// Translates gossip-kt `DigestWindowTest.kt` (the window cases of
/// `digest_budgeter_test.dart`, on the pure selection with sizes handed in);
/// order is by recency, not by a cursor.
void main() {
  List<RotationKey> keys(List<String> items) => [
    for (final i in items) RotationKey(ChannelId(i), StreamId('s')),
  ];

  Window<String> select(
    List<String> items,
    List<int> costs, {
    required int budget,
    Recency recency = Recency.initial,
  }) => DigestWindow.select(
    items: items,
    costs: costs,
    keys: keys(items),
    recency: recency,
    budget: budget,
  );

  Recency sent(List<String> names) => Recency.initial.stamp(keys(names));

  test('everything fits: all selected, never-sent ones in list order', () {
    final w = select(['a', 'b', 'c'], [10, 10, 10], budget: 32);
    expect(w.selected, ['a', 'b', 'c']);
    expect(w.oversized, isEmpty);
  });

  test('a previously sent item goes after the never-sent ones', () {
    final w = select(
      ['a', 'b', 'c'],
      [10, 10, 10],
      budget: 32,
      recency: sent(['a']),
    );
    expect(w.selected, ['b', 'c', 'a']);
  });

  test('among sent items the one sent longest ago goes first', () {
    final w = select(
      ['a', 'b', 'c'],
      [10, 10, 10],
      budget: 32,
      recency: sent(['c', 'a', 'b']),
    );
    expect(w.selected, ['c', 'a', 'b']);
  });

  test(
    'a window that does not fit stops at the first item over the room left',
    () {
      final w = select(['a', 'b', 'c', 'd'], [10, 10, 10, 10], budget: 25);
      expect(w.selected, ['a', 'b']);
    },
  );

  test(
    'stopping at the first non-fit does not look past it for a smaller item',
    () {
      final w = select(['a', 'big', 'c'], [10, 25, 5], budget: 30);
      expect(w.selected, ['a']);
    },
  );

  test('successive windows stamped by their selection cover every item', () {
    final items = ['a', 'b', 'c'];
    final costs = [10, 10, 10];
    final first = select(items, costs, budget: 21);
    final second = select(
      items,
      costs,
      budget: 21,
      recency: Recency.initial.stamp(keys(first.selected)),
    );
    expect(first.selected, ['a', 'b']);
    expect(second.selected, ['c', 'a']);
  });

  test(
    'an item alone over the budget is skipped and reported, not selected',
    () {
      final w = select(['a', 'big', 'c'], [10, 100, 10], budget: 30);
      expect(w.selected, ['a', 'c']);
      expect(w.oversized, ['big']);
    },
  );

  test('no items: nothing selected', () {
    final w = select([], [], budget: 10);
    expect(w.selected, isEmpty);
    expect(w.oversized, isEmpty);
  });

  test('a zero budget selects nothing and reports every item as oversized', () {
    final w = select(['a'], [1], budget: 0);
    expect(w.selected, isEmpty);
    expect(w.oversized, ['a']);
  });

  test(
    'an item whose cost equals the budget is selected alone, not oversized',
    () {
      final w = select(['a'], [10], budget: 10);
      expect(w.selected, ['a']);
      expect(w.oversized, isEmpty);
      expect(w.usedBytes, 10);
    },
  );

  test('two items that each fill the budget select one and stop', () {
    final w = select(['a', 'b'], [10, 10], budget: 10);
    expect(w.selected, ['a']);
    expect(w.oversized, isEmpty);
  });

  test('the window charges one separator between the items it selects', () {
    final items = ['a', 'b', 'c'];
    final costs = [10, 10, 10];
    final all = select(items, costs, budget: 32);
    final two = select(items, costs, budget: 31);
    expect(all.selected, items);
    expect(all.usedBytes, 32);
    expect(two.selected, ['a', 'b']);
    expect(two.usedBytes, 21);
  });

  test('lists of different lengths are an ArgumentError', () {
    expect(
      () => DigestWindow.select(
        items: ['a'],
        costs: [1, 2],
        keys: keys(['a']),
        recency: Recency.initial,
        budget: 10,
      ),
      throwsArgumentError,
    );
  });
}
