import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_nearby/src/domain/value_objects/endpoint.dart';
import 'package:gossip_nearby/src/domain/value_objects/endpoint_id.dart';

void main() {
  group('Endpoint', () {
    test('can be created with id and displayName', () {
      final endpoint = Endpoint(
        id: EndpointId('abc123'),
        displayName: 'Device A',
      );

      expect(endpoint.id, equals(EndpointId('abc123')));
      expect(endpoint.displayName, equals('Device A'));
    });

    test('two Endpoints with the same id are equal', () {
      final endpoint1 = Endpoint(
        id: EndpointId('abc123'),
        displayName: 'Device A',
      );
      final endpoint2 = Endpoint(
        id: EndpointId('abc123'),
        displayName: 'Device B', // Different displayName, same id
      );

      expect(endpoint1, equals(endpoint2));
      expect(endpoint1.hashCode, equals(endpoint2.hashCode));
    });

    test('two Endpoints with different ids are not equal', () {
      final endpoint1 = Endpoint(
        id: EndpointId('abc123'),
        displayName: 'Device A',
      );
      final endpoint2 = Endpoint(
        id: EndpointId('xyz789'),
        displayName: 'Device A', // Same displayName, different id
      );

      expect(endpoint1, isNot(equals(endpoint2)));
    });

    test('toString returns a meaningful representation', () {
      final endpoint = Endpoint(
        id: EndpointId('abc123'),
        displayName: 'Device A',
      );

      expect(endpoint.toString(), contains('abc123'));
      expect(endpoint.toString(), contains('Device A'));
    });
  });
}
