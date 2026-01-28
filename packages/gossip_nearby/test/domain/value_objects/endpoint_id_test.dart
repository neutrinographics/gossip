import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_nearby/src/domain/value_objects/endpoint_id.dart';

void main() {
  group('EndpointId', () {
    test('can be created with a value', () {
      final endpointId = EndpointId('abc123');

      expect(endpointId.value, equals('abc123'));
    });

    test('two EndpointIds with the same value are equal', () {
      final id1 = EndpointId('abc123');
      final id2 = EndpointId('abc123');

      expect(id1, equals(id2));
      expect(id1.hashCode, equals(id2.hashCode));
    });

    test('two EndpointIds with different values are not equal', () {
      final id1 = EndpointId('abc123');
      final id2 = EndpointId('xyz789');

      expect(id1, isNot(equals(id2)));
    });

    test('toString returns a meaningful representation', () {
      final endpointId = EndpointId('abc123');

      expect(endpointId.toString(), contains('abc123'));
    });

    test('throws ArgumentError when value is empty', () {
      expect(() => EndpointId(''), throwsArgumentError);
    });
  });
}
