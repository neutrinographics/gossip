import 'dart:async';

import 'package:gossip/src/domain/value_objects/log_entry.dart';

/// Materializer folds log entries into derived application state.
///
/// This enables efficient read access without re-processing all entries.
/// The materialized state is rebuilt automatically when entries change.
///
/// ## Contract
/// - `initial()` returns the starting state and an optional cursor
/// - `fold()` must be deterministic: same state + entry → same result
/// - `fold()` should be pure (no side effects)
/// - State type T should be immutable for safety
/// - `save()` is called after folding a batch (not per entry)
///
/// ## Cursor
/// The cursor is an opaque string representing the last-folded entry position.
/// It must be stored alongside the state and returned from `initial()` on
/// the next startup. The library uses it for incremental folding — only
/// entries after the cursor are folded on startup.
///
/// ## Example: Counter
/// ```dart
/// class CounterMaterializer implements StateMaterializer<int> {
///   @override
///   (int, String?) initial({required bool isReset}) => (0, null);
///
///   @override
///   int fold(int state, LogEntry entry) {
///     final delta = ByteData.view(entry.payload.buffer).getInt32(0);
///     return state + delta;
///   }
/// }
/// ```
///
/// ## Example: Cached Counter
/// ```dart
/// class CachedCounterMaterializer implements StateMaterializer<int> {
///   final MyStore store;
///   CachedCounterMaterializer(this.store);
///
///   @override
///   FutureOr<(int, String?)> initial({required bool isReset}) async {
///     if (isReset) return (0, null);
///     final cached = await store.load();
///     return cached ?? (0, null);
///   }
///
///   @override
///   int fold(int state, LogEntry entry) {
///     final delta = ByteData.view(entry.payload.buffer).getInt32(0);
///     return state + delta;
///   }
///
///   @override
///   FutureOr<void> save(int state, String cursor) async {
///     await store.save(state, cursor);
///   }
/// }
/// ```
abstract class StateMaterializer<T> {
  /// Returns initial state and an optional opaque cursor string.
  ///
  /// When [isReset] is false (startup): load cached state + cursor from
  /// persistence. Return `(cachedState, cursorString)` if available, or
  /// `(emptyState, null)` if no cache exists.
  ///
  /// When [isReset] is true (rebuild): return `(emptyState, null)`, ignoring
  /// any cached state. The library will re-fold all entries from the beginning.
  FutureOr<(T, String?)> initial({required bool isReset});

  /// Apply an entry to produce new state. Must be pure and deterministic.
  /// Entries are applied in timestamp order (with ties broken by author, then sequence).
  T fold(T state, LogEntry entry);

  /// Persist the current state and cursor after folding a batch.
  ///
  /// Called by the library after folding all entries in an append or merge
  /// batch — not after every individual entry. The [cursor] is an opaque
  /// string that must be stored alongside the state and returned from
  /// [initial] on the next startup.
  ///
  /// Default implementation is a no-op. Override to enable caching.
  FutureOr<void> save(T state, String cursor) {}
}
