import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/domain/errors/bluetooth_unavailable_exception.dart';

void main() {
  group('BluetoothUnavailableException', () {
    test('default construction has null cause and null nodeId', () {
      const exception = BluetoothUnavailableException();
      expect(exception.cause, isNull);
      expect(exception.nodeId, isNull);
    });

    test('toString omits null fields', () {
      expect(
        const BluetoothUnavailableException().toString(),
        equals('BluetoothUnavailableException()'),
      );
    });

    test('carries underlying cause when provided', () {
      final underlying = StateError('synthetic');
      final exception = BluetoothUnavailableException(cause: underlying);
      expect(exception.cause, same(underlying));
      expect(exception.toString(), contains('synthetic'));
    });

    test('carries nodeId when provided', () {
      final nodeId = NodeId('11111111-1111-1111-1111-111111111111');
      final exception = BluetoothUnavailableException(nodeId: nodeId);
      expect(exception.nodeId, equals(nodeId));
      expect(exception.toString(), contains(nodeId.value));
    });

    test('carries both cause and nodeId when both provided', () {
      final nodeId = NodeId('22222222-2222-2222-2222-222222222222');
      final underlying = Exception('boom');
      final exception = BluetoothUnavailableException(
        cause: underlying,
        nodeId: nodeId,
      );
      expect(exception.cause, same(underlying));
      expect(exception.nodeId, equals(nodeId));
    });
  });
}
