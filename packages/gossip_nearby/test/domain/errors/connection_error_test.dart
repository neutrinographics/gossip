import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_nearby/src/domain/errors/connection_error.dart';
import 'package:gossip_nearby/src/domain/value_objects/endpoint_id.dart';

void main() {
  group('ConnectionErrorType', () {
    test('has connectionNotFound type', () {
      expect(ConnectionErrorType.connectionNotFound, isNotNull);
    });

    test('has connectionLost type', () {
      expect(ConnectionErrorType.connectionLost, isNotNull);
    });

    test('has handshakeTimeout type', () {
      expect(ConnectionErrorType.handshakeTimeout, isNotNull);
    });

    test('has handshakeInvalid type', () {
      expect(ConnectionErrorType.handshakeInvalid, isNotNull);
    });

    test('has sendFailed type', () {
      expect(ConnectionErrorType.sendFailed, isNotNull);
    });
  });

  group('ConnectionError base class', () {
    test('has message property', () {
      final error = ConnectionNotFoundError(
        NodeId('node'),
        'Test message',
        occurredAt: DateTime.now(),
      );
      expect(error.message, equals('Test message'));
    });

    test('has occurredAt property', () {
      final now = DateTime.now();
      final error = ConnectionNotFoundError(
        NodeId('node'),
        'Test message',
        occurredAt: now,
      );
      expect(error.occurredAt, equals(now));
    });

    test('has type property', () {
      final error = ConnectionNotFoundError(
        NodeId('node'),
        'Test message',
        occurredAt: DateTime.now(),
      );
      expect(error.type, equals(ConnectionErrorType.connectionNotFound));
    });

    test('has optional cause property', () {
      final cause = Exception('Original error');
      final error = ConnectionNotFoundError(
        NodeId('node'),
        'Test message',
        occurredAt: DateTime.now(),
        cause: cause,
      );
      expect(error.cause, equals(cause));
    });

    test('cause defaults to null', () {
      final error = ConnectionNotFoundError(
        NodeId('node'),
        'Test message',
        occurredAt: DateTime.now(),
      );
      expect(error.cause, isNull);
    });
  });

  group('ConnectionNotFoundError', () {
    test('can be created with nodeId, message, and occurredAt', () {
      final nodeId = NodeId('node-123');
      final now = DateTime.now();
      final error = ConnectionNotFoundError(
        nodeId,
        'No connection found',
        occurredAt: now,
      );

      expect(error.nodeId, equals(nodeId));
      expect(error.message, equals('No connection found'));
      expect(error.occurredAt, equals(now));
      expect(error.type, equals(ConnectionErrorType.connectionNotFound));
    });

    test('is a ConnectionError', () {
      final error = ConnectionNotFoundError(
        NodeId('node'),
        'message',
        occurredAt: DateTime.now(),
      );
      expect(error, isA<ConnectionError>());
    });

    test('toString includes nodeId and message', () {
      final error = ConnectionNotFoundError(
        NodeId('node-123'),
        'No connection',
        occurredAt: DateTime.now(),
      );
      expect(error.toString(), contains('node-123'));
      expect(error.toString(), contains('No connection'));
    });
  });

  group('HandshakeTimeoutError', () {
    test('can be created with endpointId, message, and occurredAt', () {
      final endpointId = EndpointId('endpoint-123');
      final now = DateTime.now();
      final error = HandshakeTimeoutError(
        endpointId,
        'Handshake timed out',
        occurredAt: now,
      );

      expect(error.endpointId, equals(endpointId));
      expect(error.message, equals('Handshake timed out'));
      expect(error.occurredAt, equals(now));
      expect(error.type, equals(ConnectionErrorType.handshakeTimeout));
    });

    test('is a ConnectionError', () {
      final error = HandshakeTimeoutError(
        EndpointId('endpoint'),
        'message',
        occurredAt: DateTime.now(),
      );
      expect(error, isA<ConnectionError>());
    });

    test('toString includes endpointId and message', () {
      final error = HandshakeTimeoutError(
        EndpointId('endpoint-123'),
        'Timed out',
        occurredAt: DateTime.now(),
      );
      expect(error.toString(), contains('endpoint-123'));
      expect(error.toString(), contains('Timed out'));
    });
  });

  group('HandshakeInvalidError', () {
    test('can be created with endpointId, message, and occurredAt', () {
      final endpointId = EndpointId('endpoint-123');
      final now = DateTime.now();
      final error = HandshakeInvalidError(
        endpointId,
        'Malformed handshake data',
        occurredAt: now,
      );

      expect(error.endpointId, equals(endpointId));
      expect(error.message, equals('Malformed handshake data'));
      expect(error.occurredAt, equals(now));
      expect(error.type, equals(ConnectionErrorType.handshakeInvalid));
    });

    test('is a ConnectionError', () {
      final error = HandshakeInvalidError(
        EndpointId('endpoint'),
        'message',
        occurredAt: DateTime.now(),
      );
      expect(error, isA<ConnectionError>());
    });

    test('toString includes endpointId and message', () {
      final error = HandshakeInvalidError(
        EndpointId('endpoint-123'),
        'Bad data',
        occurredAt: DateTime.now(),
      );
      expect(error.toString(), contains('endpoint-123'));
      expect(error.toString(), contains('Bad data'));
    });
  });

  group('SendFailedError', () {
    test('can be created with nodeId, message, and occurredAt', () {
      final nodeId = NodeId('node-123');
      final now = DateTime.now();
      final error = SendFailedError(nodeId, 'Failed to send', occurredAt: now);

      expect(error.nodeId, equals(nodeId));
      expect(error.message, equals('Failed to send'));
      expect(error.occurredAt, equals(now));
      expect(error.type, equals(ConnectionErrorType.sendFailed));
    });

    test('can include cause', () {
      final cause = Exception('Network error');
      final error = SendFailedError(
        NodeId('node'),
        'Failed to send',
        occurredAt: DateTime.now(),
        cause: cause,
      );
      expect(error.cause, equals(cause));
    });

    test('is a ConnectionError', () {
      final error = SendFailedError(
        NodeId('node'),
        'message',
        occurredAt: DateTime.now(),
      );
      expect(error, isA<ConnectionError>());
    });

    test('toString includes nodeId and message', () {
      final error = SendFailedError(
        NodeId('node-123'),
        'Network error',
        occurredAt: DateTime.now(),
      );
      expect(error.toString(), contains('node-123'));
      expect(error.toString(), contains('Network error'));
    });
  });

  group('ConnectionLostError', () {
    test('can be created with nodeId, message, and occurredAt', () {
      final nodeId = NodeId('node-123');
      final now = DateTime.now();
      final error = ConnectionLostError(
        nodeId,
        'Connection lost unexpectedly',
        occurredAt: now,
      );

      expect(error.nodeId, equals(nodeId));
      expect(error.message, equals('Connection lost unexpectedly'));
      expect(error.occurredAt, equals(now));
      expect(error.type, equals(ConnectionErrorType.connectionLost));
    });

    test('is a ConnectionError', () {
      final error = ConnectionLostError(
        NodeId('node'),
        'message',
        occurredAt: DateTime.now(),
      );
      expect(error, isA<ConnectionError>());
    });

    test('toString includes nodeId and message', () {
      final error = ConnectionLostError(
        NodeId('node-123'),
        'Lost connection',
        occurredAt: DateTime.now(),
      );
      expect(error.toString(), contains('node-123'));
      expect(error.toString(), contains('Lost connection'));
    });
  });

  group('ConnectionErrorCallback', () {
    test('can be used as a function type', () {
      ConnectionError? receivedError;
      void callback(ConnectionError error) {
        receivedError = error;
      }

      final error = ConnectionNotFoundError(
        NodeId('node'),
        'test',
        occurredAt: DateTime.now(),
      );
      callback(error);

      expect(receivedError, equals(error));
    });
  });
}
