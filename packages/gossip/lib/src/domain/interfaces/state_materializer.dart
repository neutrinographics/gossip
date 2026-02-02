import '../value_objects/log_entry.dart';

/// Materializer folds log entries into derived application state.
///
/// This enables efficient read access without re-processing all entries.
/// The materialized state is rebuilt automatically when entries change.
///
/// ## Contract
/// - `initial()` returns the starting state before any entries
/// - `fold()` must be deterministic: same state + entry → same result
/// - `fold()` should be pure (no side effects)
/// - State type T should be immutable for safety
///
/// ## Example: Counter
/// ```dart
/// class CounterMaterializer implements StateMaterializer<int> {
///   @override
///   int initial() => 0;
///
///   @override
///   int fold(int state, LogEntry entry) {
///     final delta = ByteData.view(entry.payload.buffer).getInt32(0);
///     return state + delta;
///   }
/// }
/// ```
///
/// ## Example: Key-Value Store
/// ```dart
/// class KvMaterializer implements StateMaterializer<Map<String, String>> {
///   @override
///   Map<String, String> initial() => {};
///
///   @override
///   Map<String, String> fold(Map<String, String> state, LogEntry entry) {
///     final op = decodeOperation(entry.payload);
///     return switch (op) {
///       SetOp(key, value) => {...state, key: value},
///       DeleteOp(key) => Map.from(state)..remove(key),
///     };
///   }
/// }
/// ```
abstract interface class StateMaterializer<T> {
  /// Initial state before any entries are applied.
  T initial();

  /// Apply an entry to produce new state.
  /// Entries are applied in timestamp order (with ties broken by author, then sequence).
  T fold(T state, LogEntry entry);
}
