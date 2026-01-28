import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_nearby/src/domain/errors/connection_error.dart';
import 'package:gossip_nearby/src/domain/value_objects/endpoint_id.dart';

void main() {
  group('ConnectionError', () {
    group('ConnectionNotFound', () {
      test('can be created with nodeId', () {
        final nodeId = NodeId('node-123');
        final error = ConnectionNotFound(nodeId);

        expect(error.nodeId, equals(nodeId));
      });

      test('is a ConnectionError', () {
        final error = ConnectionNotFound(NodeId('node'));
        expect(error, isA<ConnectionError>());
      });

      test('toString includes nodeId', () {
        final error = ConnectionNotFound(NodeId('node-123'));
        expect(error.toString(), contains('node-123'));
      });
    });

    group('HandshakeTimeout', () {
      test('can be created with endpointId', () {
        final endpointId = EndpointId('endpoint-123');
        final error = HandshakeTimeout(endpointId);

        expect(error.endpointId, equals(endpointId));
      });

      test('is a ConnectionError', () {
        final error = HandshakeTimeout(EndpointId('endpoint'));
        expect(error, isA<ConnectionError>());
      });

      test('toString includes endpointId', () {
        final error = HandshakeTimeout(EndpointId('endpoint-123'));
        expect(error.toString(), contains('endpoint-123'));
      });
    });

    group('HandshakeInvalid', () {
      test('can be created with endpointId and reason', () {
        final endpointId = EndpointId('endpoint-123');
        const reason = 'Malformed data';
        final error = HandshakeInvalid(endpointId, reason);

        expect(error.endpointId, equals(endpointId));
        expect(error.reason, equals(reason));
      });

      test('is a ConnectionError', () {
        final error = HandshakeInvalid(EndpointId('endpoint'), 'reason');
        expect(error, isA<ConnectionError>());
      });

      test('toString includes endpointId and reason', () {
        final error = HandshakeInvalid(EndpointId('endpoint-123'), 'Bad data');
        expect(error.toString(), contains('endpoint-123'));
        expect(error.toString(), contains('Bad data'));
      });
    });

    group('SendFailed', () {
      test('can be created with nodeId and reason', () {
        final nodeId = NodeId('node-123');
        const reason = 'Network error';
        final error = SendFailed(nodeId, reason);

        expect(error.nodeId, equals(nodeId));
        expect(error.reason, equals(reason));
      });

      test('is a ConnectionError', () {
        final error = SendFailed(NodeId('node'), 'reason');
        expect(error, isA<ConnectionError>());
      });

      test('toString includes nodeId and reason', () {
        final error = SendFailed(NodeId('node-123'), 'Network error');
        expect(error.toString(), contains('node-123'));
        expect(error.toString(), contains('Network error'));
      });
    });
  });
}
