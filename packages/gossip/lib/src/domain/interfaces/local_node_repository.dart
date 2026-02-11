import '../value_objects/hlc.dart';

/// Repository for persisting local node state across application restarts.
///
/// [LocalNodeRepository] stores state that belongs to the local node and
/// must survive restarts to maintain protocol correctness:
///
/// - **HLC clock state**: The hybrid logical clock's last known timestamp.
///   Restoring this on startup preserves timestamp monotonicity even if the
///   system clock regresses between restarts.
///
/// - **Incarnation number**: The SWIM protocol incarnation counter. Restoring
///   this prevents peers from treating the restarted node as stale when it
///   had previously incremented its incarnation to refute false suspicions.
///
/// ## Default Values
/// When no state has been persisted, implementations should return:
/// - [Hlc.zero] for clock state
/// - `0` for incarnation
///
/// ## Implementation Guidance
/// - Use key-value storage (SharedPreferences, localStorage) for simple cases
/// - Use a single-row table in SQLite for relational storage
/// - Both values are small and change infrequently — no special
///   performance considerations needed
///
/// See also:
/// - [InMemoryLocalNodeRepository] for the reference implementation
/// - [ChannelRepository] for channel metadata storage
/// - [EntryRepository] for log entry storage
/// - [PeerRepository] for peer state storage
abstract interface class LocalNodeRepository {
  /// Returns the persisted HLC clock state, or [Hlc.zero] if none exists.
  Future<Hlc> getClockState();

  /// Persists the current HLC clock state.
  Future<void> saveClockState(Hlc state);

  /// Returns the persisted incarnation number, or 0 if none exists.
  Future<int> getIncarnation();

  /// Persists the current incarnation number.
  Future<void> saveIncarnation(int incarnation);
}
