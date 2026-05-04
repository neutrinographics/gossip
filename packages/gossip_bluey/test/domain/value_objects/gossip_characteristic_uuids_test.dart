import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/src/domain/value_objects/gossip_characteristic_uuids.dart';
import 'package:gossip_bluey/src/domain/value_objects/service_uuid.dart';

void main() {
  group('GossipCharacteristicUuids', () {
    test('derives the data characteristic UUID by XORing the last byte with 0x01', () {
      final service = ServiceUuid('f0000000-0000-0000-0000-000000000000');
      final uuids = GossipCharacteristicUuids.derive(service);
      expect(uuids.dataCharacteristic, equals('f0000000-0000-0000-0000-000000000001'));
    });

    test('handles a non-zero last byte cleanly', () {
      final service = ServiceUuid('f0000000-0000-0000-0000-0000000000ab');
      final uuids = GossipCharacteristicUuids.derive(service);
      expect(uuids.dataCharacteristic, equals('f0000000-0000-0000-0000-0000000000aa'));
    });

    test('is stable across calls', () {
      final service = ServiceUuid('f0000000-0000-0000-0000-000000000000');
      final a = GossipCharacteristicUuids.derive(service);
      final b = GossipCharacteristicUuids.derive(service);
      expect(a.dataCharacteristic, equals(b.dataCharacteristic));
    });
  });
}
