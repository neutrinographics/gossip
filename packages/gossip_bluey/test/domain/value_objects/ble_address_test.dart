import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/src/domain/value_objects/ble_address.dart';

void main() {
  group('BleAddress', () {
    test('equality is value-based', () {
      expect(const BleAddress('AA:BB:CC:DD:EE:FF'),
          equals(const BleAddress('AA:BB:CC:DD:EE:FF')));
      expect(const BleAddress('AA:BB:CC:DD:EE:FF'),
          isNot(equals(const BleAddress('11:22:33:44:55:66'))));
    });

    test('hashCode matches equality', () {
      expect(const BleAddress('AA:BB:CC:DD:EE:FF').hashCode,
          equals(const BleAddress('AA:BB:CC:DD:EE:FF').hashCode));
    });

    test('toString includes value', () {
      expect(const BleAddress('AA:BB:CC:DD:EE:FF').toString(),
          contains('AA:BB:CC:DD:EE:FF'));
    });
  });
}
