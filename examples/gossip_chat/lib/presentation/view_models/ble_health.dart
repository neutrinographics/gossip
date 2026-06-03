/// BLE signal strength bucket derived from RSSI (in dBm).
///
/// Distinct from gossip-protocol health (SWIM probe failures). Both are
/// surfaced as independent indicators on the peers screen.
enum BleHealth {
  excellent, // RSSI >= -60
  good, //      -75 <= RSSI < -60
  fair, //      -85 <= RSSI < -75
  poor, //      RSSI < -85
  unknown; //   No recent RSSI (scanner stopped, never seen)

  /// Bucket RSSI in dBm into a [BleHealth] level. Null RSSI maps to
  /// [BleHealth.unknown].
  static BleHealth fromRssi(int? rssi) {
    if (rssi == null) return BleHealth.unknown;
    if (rssi >= -60) return BleHealth.excellent;
    if (rssi >= -75) return BleHealth.good;
    if (rssi >= -85) return BleHealth.fair;
    return BleHealth.poor;
  }
}
