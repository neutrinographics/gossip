/// Scan duty-cycle intensity (honored on Android; iOS manages scan duty
/// automatically).
///
/// Owned by this package so consuming apps never import the underlying
/// BLE library to name a radio policy; the adapter translates at the
/// boundary.
enum ScanMode {
  /// Sparse duty cycle — the radio mostly rests. Right once every
  /// expected peer is connected and scanning is only a safety net.
  lowPower,

  /// Balanced duty cycle. Good default for opportunistic discovery.
  balanced,

  /// Continuous scanning — fastest discovery, highest battery cost
  /// (commonly ~10-15% per hour on phones). The historical default.
  lowLatency,
}
