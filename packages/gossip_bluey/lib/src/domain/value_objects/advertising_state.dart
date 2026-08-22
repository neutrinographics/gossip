/// Owned advertising lifecycle. Mirrors bluey's `AdvertisingState` 1:1 so
/// consumers of this package never import `package:bluey` directly.
///
/// Translation from bluey's platform-interface enum happens ONLY at the
/// infrastructure boundary (`BlueyPortImpl.mapAdvertisingState`), matching
/// the same ACL pattern used for `BluetoothAdapterState`/`BluetoothState`.
enum AdvertisingState {
  /// No advertising activity; the initial state and the state after a
  /// clean `stopAdvertising` completes.
  idle,

  /// Platform call to begin advertising is in flight.
  starting,

  /// Actively advertising and discoverable by peers.
  advertising,

  /// Platform call to stop advertising is in flight.
  stopping,

  /// The underlying server was invalidated by an adapter cycle (off/on).
  /// Consumer must call `startAdvertising` again to recover.
  invalidated,
}
