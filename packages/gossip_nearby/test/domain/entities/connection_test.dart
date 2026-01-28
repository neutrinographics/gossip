import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_nearby/src/domain/entities/connection.dart';
import 'package:gossip_nearby/src/domain/value_objects/endpoint.dart';
import 'package:gossip_nearby/src/domain/value_objects/endpoint_id.dart';

void main() {
  group('Connection', () {
    late Endpoint endpoint;
    late NodeId nodeId;
    late DateTime connectedAt;

    setUp(() {
      endpoint = Endpoint(id: EndpointId('abc123'), displayName: 'Device A');
      nodeId = NodeId('node-uuid-123');
      connectedAt = DateTime(2024, 1, 15, 10, 30);
    });

    test('can be created with endpoint, nodeId, and connectedAt', () {
      final connection = Connection(
        endpoint: endpoint,
        nodeId: nodeId,
        connectedAt: connectedAt,
      );

      expect(connection.endpoint, equals(endpoint));
      expect(connection.nodeId, equals(nodeId));
      expect(connection.connectedAt, equals(connectedAt));
    });

    test('exposes endpointId for convenience', () {
      final connection = Connection(
        endpoint: endpoint,
        nodeId: nodeId,
        connectedAt: connectedAt,
      );

      expect(connection.endpointId, equals(EndpointId('abc123')));
    });

    test('two Connections with the same endpointId are equal', () {
      final connection1 = Connection(
        endpoint: endpoint,
        nodeId: nodeId,
        connectedAt: connectedAt,
      );
      final connection2 = Connection(
        endpoint: Endpoint(id: EndpointId('abc123'), displayName: 'Different'),
        nodeId: NodeId('different-node'),
        connectedAt: DateTime(2025, 1, 1),
      );

      expect(connection1, equals(connection2));
      expect(connection1.hashCode, equals(connection2.hashCode));
    });

    test('two Connections with different endpointIds are not equal', () {
      final connection1 = Connection(
        endpoint: endpoint,
        nodeId: nodeId,
        connectedAt: connectedAt,
      );
      final connection2 = Connection(
        endpoint: Endpoint(id: EndpointId('xyz789'), displayName: 'Device A'),
        nodeId: nodeId,
        connectedAt: connectedAt,
      );

      expect(connection1, isNot(equals(connection2)));
    });

    test('toString returns a meaningful representation', () {
      final connection = Connection(
        endpoint: endpoint,
        nodeId: nodeId,
        connectedAt: connectedAt,
      );

      expect(connection.toString(), contains('abc123'));
      expect(connection.toString(), contains('node-uuid-123'));
    });
  });
}
