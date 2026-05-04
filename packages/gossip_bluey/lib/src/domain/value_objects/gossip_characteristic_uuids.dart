import 'service_uuid.dart';

/// Bundle of BLE characteristic UUIDs used by `gossip_bluey`.
///
/// Currently only the data characteristic. Derived deterministically from
/// the user's service UUID so the application doesn't have to pick two.
class GossipCharacteristicUuids {
  final String dataCharacteristic;

  const GossipCharacteristicUuids._({required this.dataCharacteristic});

  factory GossipCharacteristicUuids.derive(ServiceUuid serviceUuid) {
    final hex = serviceUuid.value.replaceAll('-', '');
    final lastByte = int.parse(hex.substring(30), radix: 16);
    final xored = (lastByte ^ 0x01).toRadixString(16).padLeft(2, '0');
    final mutatedHex = hex.substring(0, 30) + xored;
    final formatted =
        '${mutatedHex.substring(0, 8)}-${mutatedHex.substring(8, 12)}-'
        '${mutatedHex.substring(12, 16)}-${mutatedHex.substring(16, 20)}-'
        '${mutatedHex.substring(20, 32)}';
    return GossipCharacteristicUuids._(dataCharacteristic: formatted);
  }
}
