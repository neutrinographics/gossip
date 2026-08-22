/// Owned scan lifecycle. Mirrors bluey's `ScanState` 1:1 so consumers of
/// this package never import `package:bluey` directly.
///
/// Translation from bluey's platform-interface enum happens ONLY at the
/// infrastructure boundary (`BlueyPortImpl.mapScanState`), matching the
/// same ACL pattern used for `BluetoothAdapterState`/`BluetoothState`.
enum ScanState {
  /// No scan activity; the initial state and the state after a clean
  /// `stopScan` completes.
  stopped,

  /// Platform call to begin scanning is in flight.
  starting,

  /// Actively scanning for advertising peers.
  scanning,

  /// Platform call to stop scanning is in flight.
  stopping,

  /// The underlying scanner was invalidated by an adapter cycle (off/on).
  /// Consumer must call `scanForCandidates` again to recover.
  invalidated,
}
