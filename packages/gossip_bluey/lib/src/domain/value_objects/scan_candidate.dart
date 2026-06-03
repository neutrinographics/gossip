import 'ble_address.dart';

/// A device surfaced by the BLE scanner — pre-connect, NodeId not yet
/// known. Pure domain: only primitive/domain types. The infrastructure
/// adapter resolves [address] to its internal device handle when
/// connect-and-identify is invoked.
class ScanCandidate {
  final BleAddress address;
  final String? displayName;

  /// Last-known signal strength in dBm. Null when the underlying
  /// scanner did not provide an RSSI value for this emission.
  final int? rssi;

  /// Observation time of the most recent emission for this address.
  /// Consumers use this to decide whether to drop a peer that has
  /// stopped advertising.
  final DateTime lastSeen;

  const ScanCandidate({
    required this.address,
    required this.lastSeen,
    this.displayName,
    this.rssi,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScanCandidate &&
          address == other.address &&
          displayName == other.displayName &&
          rssi == other.rssi &&
          lastSeen == other.lastSeen;

  @override
  int get hashCode => Object.hash(address, displayName, rssi, lastSeen);

  @override
  String toString() =>
      'ScanCandidate(address: $address, displayName: $displayName, '
      'rssi: ${rssi != null ? '$rssi dBm' : 'unknown'}, lastSeen: $lastSeen)';
}
