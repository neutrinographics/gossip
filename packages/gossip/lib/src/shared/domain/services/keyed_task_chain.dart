import 'dart:async';
import 'package:meta/meta.dart';

/// Serializes async work per key: tasks enqueued under the same key run
/// strictly in order; different keys run independently.
///
/// Centralizes the chain idiom previously hand-rolled at five sites, whose
/// subtleties have bitten before (a `whenComplete` returning the map entry
/// self-deadlocks — see the caching-repository regression test):
/// - a failed predecessor never blocks the chain — its error surfaces only
///   to its own awaiter;
/// - the returned future is the caller's typed result, never the map entry;
/// - a drained key's entry is removed, guarded by `identical` so a newer
///   chain for the same key is never evicted.
///
/// Single-isolate (ADR-001): no synchronization needed.
class KeyedTaskChain<K> {
  final Map<K, Future<void>> _chains = {};

  /// Runs [task] after every previously enqueued task for [key] settles.
  Future<T> enqueue<T>(K key, Future<T> Function() task) {
    final previous = _chains[key] ?? Future<void>.value();
    final result = previous.catchError((_) {}).then((_) => task());
    // Detached entry: swallows the error so the internal chain never
    // reports unhandled, and so cleanup cannot await the caller's future.
    final chainEntry = result.then<void>((_) {}, onError: (_) {});
    _chains[key] = chainEntry;
    chainEntry.whenComplete(() {
      if (identical(_chains[key], chainEntry)) {
        _chains.remove(key);
      }
    });
    return result;
  }

  /// Number of keys with a live (undrained) chain.
  @visibleForTesting
  int get pendingKeyCount => _chains.length;
}
