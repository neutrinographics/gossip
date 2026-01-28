import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_nearby/src/domain/value_objects/service_id.dart';

void main() {
  group('ServiceId', () {
    test('can be created with a value', () {
      final serviceId = ServiceId('com.example.app');

      expect(serviceId.value, equals('com.example.app'));
    });

    test('two ServiceIds with the same value are equal', () {
      final id1 = ServiceId('com.example.app');
      final id2 = ServiceId('com.example.app');

      expect(id1, equals(id2));
      expect(id1.hashCode, equals(id2.hashCode));
    });

    test('two ServiceIds with different values are not equal', () {
      final id1 = ServiceId('com.example.app1');
      final id2 = ServiceId('com.example.app2');

      expect(id1, isNot(equals(id2)));
    });

    test('toString returns a meaningful representation', () {
      final serviceId = ServiceId('com.example.app');

      expect(serviceId.toString(), contains('com.example.app'));
    });

    test('throws ArgumentError when value is empty', () {
      expect(() => ServiceId(''), throwsArgumentError);
    });
  });
}
