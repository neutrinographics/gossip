/// Advertising interval/power intensity (honored on Android; iOS manages
/// advertising automatically).
///
/// Owned by this package so consuming apps never import the underlying
/// BLE library to name a radio policy; the adapter translates at the
/// boundary.
enum AdvertiseMode {
  /// ~1000 ms advertising interval — lowest power. Right for a mesh
  /// that is already fully connected.
  lowPower,

  /// ~250 ms advertising interval — balanced.
  balanced,

  /// ~100 ms advertising interval — fastest discovery, highest power.
  /// The historical default.
  lowLatency,
}
