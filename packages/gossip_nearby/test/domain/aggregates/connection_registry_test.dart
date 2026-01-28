import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_nearby/src/domain/aggregates/connection_registry.dart';
import 'package:gossip_nearby/src/domain/entities/connection.dart';
import 'package:gossip_nearby/src/domain/events/connection_event.dart';
import 'package:gossip_nearby/src/domain/value_objects/endpoint.dart';
import 'package:gossip_nearby/src/domain/value_objects/endpoint_id.dart';

void main() {
  group('ConnectionRegistry', () {
    late ConnectionRegistry registry;

    setUp(() {
      registry = ConnectionRegistry();
    });

    group('registerPendingHandshake', () {
      test('tracks endpoint as pending', () {
        final endpointId = EndpointId('abc123');

        registry.registerPendingHandshake(endpointId);

        expect(registry.hasPendingHandshake(endpointId), isTrue);
      });

      test('does not create a connection yet', () {
        final endpointId = EndpointId('abc123');

        registry.registerPendingHandshake(endpointId);

        expect(registry.getConnection(endpointId), isNull);
      });
    });

    group('completeHandshake', () {
      test('creates connection and emits HandshakeCompleted event', () {
        final endpoint = Endpoint(id: EndpointId('abc123'), displayName: 'A');
        final nodeId = NodeId('node-123');
        registry.registerPendingHandshake(endpoint.id);

        final event = registry.completeHandshake(endpoint, nodeId);

        expect(event, isA<HandshakeCompleted>());
        expect((event as HandshakeCompleted).endpoint, equals(endpoint));
        expect(event.nodeId, equals(nodeId));
      });

      test('connection is retrievable after completion', () {
        final endpoint = Endpoint(id: EndpointId('abc123'), displayName: 'A');
        final nodeId = NodeId('node-123');
        registry.registerPendingHandshake(endpoint.id);

        registry.completeHandshake(endpoint, nodeId);

        final connection = registry.getConnection(endpoint.id);
        expect(connection, isNotNull);
        expect(connection!.nodeId, equals(nodeId));
        expect(connection.endpoint, equals(endpoint));
      });

      test('removes pending handshake after completion', () {
        final endpoint = Endpoint(id: EndpointId('abc123'), displayName: 'A');
        final nodeId = NodeId('node-123');
        registry.registerPendingHandshake(endpoint.id);

        registry.completeHandshake(endpoint, nodeId);

        expect(registry.hasPendingHandshake(endpoint.id), isFalse);
      });

      test('can lookup endpointId by nodeId', () {
        final endpoint = Endpoint(id: EndpointId('abc123'), displayName: 'A');
        final nodeId = NodeId('node-123');
        registry.registerPendingHandshake(endpoint.id);
        registry.completeHandshake(endpoint, nodeId);

        expect(registry.getEndpointIdForNodeId(nodeId), equals(endpoint.id));
      });

      test('can lookup nodeId by endpointId', () {
        final endpoint = Endpoint(id: EndpointId('abc123'), displayName: 'A');
        final nodeId = NodeId('node-123');
        registry.registerPendingHandshake(endpoint.id);
        registry.completeHandshake(endpoint, nodeId);

        expect(registry.getNodeIdForEndpoint(endpoint.id), equals(nodeId));
      });
    });

    group('NodeId uniqueness invariant', () {
      test(
        'replaces old connection when same NodeId connects via new endpoint',
        () {
          final endpoint1 = Endpoint(
            id: EndpointId('old-ep'),
            displayName: 'A',
          );
          final endpoint2 = Endpoint(
            id: EndpointId('new-ep'),
            displayName: 'A',
          );
          final nodeId = NodeId('node-123');

          // First connection
          registry.registerPendingHandshake(endpoint1.id);
          registry.completeHandshake(endpoint1, nodeId);

          // Second connection with same NodeId
          registry.registerPendingHandshake(endpoint2.id);
          final event = registry.completeHandshake(endpoint2, nodeId);

          // Old connection should be removed
          expect(registry.getConnection(endpoint1.id), isNull);
          // New connection should exist
          expect(registry.getConnection(endpoint2.id), isNotNull);
          // NodeId should map to new endpoint
          expect(registry.getEndpointIdForNodeId(nodeId), equals(endpoint2.id));
          // Event should indicate successful handshake
          expect(event, isA<HandshakeCompleted>());
        },
      );
    });

    group('removeConnection', () {
      test('removes connection and emits ConnectionClosed event', () {
        final endpoint = Endpoint(id: EndpointId('abc123'), displayName: 'A');
        final nodeId = NodeId('node-123');
        registry.registerPendingHandshake(endpoint.id);
        registry.completeHandshake(endpoint, nodeId);

        final event = registry.removeConnection(endpoint.id, 'Test reason');

        expect(event, isA<ConnectionClosed>());
        expect((event as ConnectionClosed).nodeId, equals(nodeId));
        expect(event.reason, equals('Test reason'));
      });

      test('connection is no longer retrievable after removal', () {
        final endpoint = Endpoint(id: EndpointId('abc123'), displayName: 'A');
        final nodeId = NodeId('node-123');
        registry.registerPendingHandshake(endpoint.id);
        registry.completeHandshake(endpoint, nodeId);

        registry.removeConnection(endpoint.id, 'reason');

        expect(registry.getConnection(endpoint.id), isNull);
        expect(registry.getEndpointIdForNodeId(nodeId), isNull);
        expect(registry.getNodeIdForEndpoint(endpoint.id), isNull);
      });

      test('returns null when removing non-existent connection', () {
        final event = registry.removeConnection(
          EndpointId('unknown'),
          'reason',
        );

        expect(event, isNull);
      });
    });

    group('cancelPendingHandshake', () {
      test('removes pending handshake and emits HandshakeFailed event', () {
        final endpointId = EndpointId('abc123');
        registry.registerPendingHandshake(endpointId);

        final event = registry.cancelPendingHandshake(endpointId, 'Timeout');

        expect(event, isA<HandshakeFailed>());
        expect((event as HandshakeFailed).reason, equals('Timeout'));
        expect(registry.hasPendingHandshake(endpointId), isFalse);
      });

      test('returns null when cancelling non-existent pending handshake', () {
        final event = registry.cancelPendingHandshake(
          EndpointId('unknown'),
          'reason',
        );

        expect(event, isNull);
      });
    });

    group('queries', () {
      test('connections returns all active connections', () {
        final endpoint1 = Endpoint(id: EndpointId('ep1'), displayName: 'A');
        final endpoint2 = Endpoint(id: EndpointId('ep2'), displayName: 'B');
        registry.registerPendingHandshake(endpoint1.id);
        registry.completeHandshake(endpoint1, NodeId('node1'));
        registry.registerPendingHandshake(endpoint2.id);
        registry.completeHandshake(endpoint2, NodeId('node2'));

        expect(registry.connections.length, equals(2));
      });

      test('connectionCount returns number of active connections', () {
        final endpoint = Endpoint(id: EndpointId('ep1'), displayName: 'A');
        registry.registerPendingHandshake(endpoint.id);
        registry.completeHandshake(endpoint, NodeId('node1'));

        expect(registry.connectionCount, equals(1));
      });

      test('pendingHandshakeCount returns number of pending handshakes', () {
        registry.registerPendingHandshake(EndpointId('ep1'));
        registry.registerPendingHandshake(EndpointId('ep2'));

        expect(registry.pendingHandshakeCount, equals(2));
      });
    });
  });
}
