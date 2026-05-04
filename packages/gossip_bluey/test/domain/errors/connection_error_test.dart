import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/domain/errors/connection_error.dart';

void main() {
  final nodeId = NodeId('11111111-1111-1111-1111-111111111111');

  group('ConnectionError', () {
    test('ConnectionNotFoundError carries nodeId and type', () {
      final err = ConnectionNotFoundError(
        message: 'no connection to peer',
        occurredAt: DateTime(2026, 5, 4),
        nodeId: nodeId,
      );
      expect(err.type, equals(ConnectionErrorType.connectionNotFound));
      expect(err.nodeId, equals(nodeId));
      expect(err.message, contains('no connection'));
    });

    test('SendFailedError preserves the underlying cause', () {
      final cause = StateError('write timeout');
      final err = SendFailedError(
        message: 'send failed',
        occurredAt: DateTime(2026, 5, 4),
        nodeId: nodeId,
        cause: cause,
      );
      expect(err.cause, same(cause));
      expect(err.type, equals(ConnectionErrorType.sendFailed));
    });

    test('ConnectionLostError type', () {
      final err = ConnectionLostError(
        message: 'lost',
        occurredAt: DateTime(2026, 5, 4),
        nodeId: nodeId,
      );
      expect(err.type, equals(ConnectionErrorType.connectionLost));
    });

    test('ConnectionLimitReachedError type', () {
      final err = ConnectionLimitReachedError(
        message: 'at capacity',
        occurredAt: DateTime(2026, 5, 4),
        nodeId: nodeId,
      );
      expect(err.type, equals(ConnectionErrorType.connectionLimitReached));
    });

    test('ConnectFailedError type', () {
      final err = ConnectFailedError(
        message: 'connect failed',
        occurredAt: DateTime(2026, 5, 4),
        nodeId: nodeId,
      );
      expect(err.type, equals(ConnectionErrorType.connectFailed));
    });

    test('FrameDecodeError type', () {
      final err = FrameDecodeError(
        message: 'oversize frame',
        occurredAt: DateTime(2026, 5, 4),
        nodeId: nodeId,
      );
      expect(err.type, equals(ConnectionErrorType.frameDecode));
    });
  });
}
