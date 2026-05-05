import 'ble_address.dart';

/// A device surfaced by the BLE scanner — pre-connect, NodeId not yet
/// known. Pure domain: only primitive/domain types. The infrastructure
/// adapter resolves [address] to its internal device handle when
/// connect-and-identify is invoked.
class ScanCandidate {
  final BleAddress address;
  final String? displayName;
  const ScanCandidate({required this.address, this.displayName});
}
