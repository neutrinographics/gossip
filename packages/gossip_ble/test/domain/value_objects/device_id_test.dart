import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_ble/src/domain/value_objects/device_id.dart';

void main() {
  group('DeviceId', () {
    test('stores the value', () {
      const id = DeviceId('abc-123');
      expect(id.value, 'abc-123');
    });

    test('two DeviceIds with same value are equal', () {
      const id1 = DeviceId('abc-123');
      const id2 = DeviceId('abc-123');
      expect(id1, equals(id2));
      expect(id1.hashCode, equals(id2.hashCode));
    });

    test('two DeviceIds with different values are not equal', () {
      const id1 = DeviceId('abc-123');
      const id2 = DeviceId('xyz-789');
      expect(id1, isNot(equals(id2)));
    });

    test('toString returns readable format', () {
      const id = DeviceId('abc-123');
      expect(id.toString(), 'DeviceId(abc-123)');
    });
  });
}
