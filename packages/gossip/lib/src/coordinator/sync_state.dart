/// Represents the current state of the sync coordinator.
enum SyncState {
  /// Initial state before start() is called.
  stopped,

  /// Coordinator is running and actively syncing.
  running,

  /// Coordinator is paused (no active sync but can be resumed).
  paused,

  /// Coordinator has been disposed and cannot be reused.
  disposed,
}
