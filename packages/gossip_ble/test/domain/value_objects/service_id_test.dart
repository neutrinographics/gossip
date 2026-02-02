import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_ble/src/domain/value_objects/service_id.dart';

void main() {
  group('ServiceId', () {
    test('stores the value', () {
      const id = ServiceId('com.example.app');
      expect(id.value, 'com.example.app');
    });

    test('two ServiceIds with same value are equal', () {
      const id1 = ServiceId('com.example.app');
      const id2 = ServiceId('com.example.app');
      expect(id1, equals(id2));
      expect(id1.hashCode, equals(id2.hashCode));
    });

    test('two ServiceIds with different values are not equal', () {
      const id1 = ServiceId('com.example.app');
      const id2 = ServiceId('com.other.app');
      expect(id1, isNot(equals(id2)));
    });

    test('toString returns readable format', () {
      const id = ServiceId('com.example.app');
      expect(id.toString(), 'ServiceId(com.example.app)');
    });
  });
}
