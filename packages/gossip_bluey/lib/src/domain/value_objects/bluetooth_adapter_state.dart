/// Coarse-grained state of the underlying Bluetooth adapter. Maps from
/// the bluey platform-interface `BluetoothState` so the domain layer
/// doesn't import bluey types directly.
enum BluetoothAdapterState {
  /// Adapter is on and usable. The only state in which transport
  /// operations succeed.
  on,

  /// User or OS turned the adapter off.
  off,

  /// App is not permitted to use Bluetooth (permission denied or
  /// missing usage-description on iOS).
  unauthorized,

  /// Device has no BLE support, or the platform doesn't expose it.
  unsupported,

  /// Mid-transition (turning on, turning off, iOS resetting) or not
  /// yet determined at startup. Treat as "not on" for gating purposes.
  unknown,
}
