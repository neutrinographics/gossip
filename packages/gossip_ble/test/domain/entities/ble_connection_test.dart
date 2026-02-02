import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_ble/src/domain/entities/ble_connection.dart';
import 'package:gossip_ble/src/domain/value_objects/device_id.dart';

void main() {
  group('BleConnection', () {
    const deviceId = DeviceId('device-123');
    final nodeId = NodeId('node-abc');
    final connectedAt = DateTime(2024, 1, 15, 10, 30);

    test('stores all properties', () {
      final connection = BleConnection(
        deviceId: deviceId,
        nodeId: nodeId,
        connectedAt: connectedAt,
      );

      expect(connection.deviceId, deviceId);
      expect(connection.nodeId, nodeId);
      expect(connection.connectedAt, connectedAt);
    });

    test('two connections with same deviceId are equal', () {
      final connection1 = BleConnection(
        deviceId: deviceId,
        nodeId: nodeId,
        connectedAt: connectedAt,
      );
      final connection2 = BleConnection(
        deviceId: deviceId,
        nodeId: NodeId('different-node'),
        connectedAt: DateTime(2024, 2, 1),
      );

      expect(connection1, equals(connection2));
      expect(connection1.hashCode, equals(connection2.hashCode));
    });

    test('two connections with different deviceIds are not equal', () {
      final connection1 = BleConnection(
        deviceId: deviceId,
        nodeId: nodeId,
        connectedAt: connectedAt,
      );
      final connection2 = BleConnection(
        deviceId: const DeviceId('other-device'),
        nodeId: nodeId,
        connectedAt: connectedAt,
      );

      expect(connection1, isNot(equals(connection2)));
    });

    test('toString returns readable format', () {
      final connection = BleConnection(
        deviceId: deviceId,
        nodeId: nodeId,
        connectedAt: connectedAt,
      );

      expect(connection.toString(), contains('BleConnection'));
      expect(connection.toString(), contains('device-123'));
      expect(connection.toString(), contains('node-abc'));
    });
  });
}
