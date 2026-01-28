import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_nearby/src/domain/events/connection_event.dart';
import 'package:gossip_nearby/src/domain/value_objects/endpoint.dart';
import 'package:gossip_nearby/src/domain/value_objects/endpoint_id.dart';

void main() {
  group('ConnectionEvent', () {
    group('HandshakeCompleted', () {
      test('can be created with endpoint and nodeId', () {
        final endpoint = Endpoint(
          id: EndpointId('abc123'),
          displayName: 'Device A',
        );
        final nodeId = NodeId('node-uuid-123');

        final event = HandshakeCompleted(endpoint: endpoint, nodeId: nodeId);

        expect(event.endpoint, equals(endpoint));
        expect(event.nodeId, equals(nodeId));
      });

      test('is a ConnectionEvent', () {
        final event = HandshakeCompleted(
          endpoint: Endpoint(id: EndpointId('abc'), displayName: 'A'),
          nodeId: NodeId('node'),
        );

        expect(event, isA<ConnectionEvent>());
      });
    });

    group('HandshakeFailed', () {
      test('can be created with endpoint and reason', () {
        final endpoint = Endpoint(
          id: EndpointId('abc123'),
          displayName: 'Device A',
        );
        const reason = 'Timeout';

        final event = HandshakeFailed(endpoint: endpoint, reason: reason);

        expect(event.endpoint, equals(endpoint));
        expect(event.reason, equals(reason));
      });

      test('is a ConnectionEvent', () {
        final event = HandshakeFailed(
          endpoint: Endpoint(id: EndpointId('abc'), displayName: 'A'),
          reason: 'Error',
        );

        expect(event, isA<ConnectionEvent>());
      });
    });

    group('ConnectionClosed', () {
      test('can be created with nodeId and reason', () {
        final nodeId = NodeId('node-uuid-123');
        const reason = 'Remote disconnect';

        final event = ConnectionClosed(nodeId: nodeId, reason: reason);

        expect(event.nodeId, equals(nodeId));
        expect(event.reason, equals(reason));
      });

      test('is a ConnectionEvent', () {
        final event = ConnectionClosed(
          nodeId: NodeId('node'),
          reason: 'Disconnect',
        );

        expect(event, isA<ConnectionEvent>());
      });
    });
  });
}
