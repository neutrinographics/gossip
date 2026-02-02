import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_ble/src/domain/aggregates/connection_registry.dart';
import 'package:gossip_ble/src/domain/events/connection_event.dart';
import 'package:gossip_ble/src/domain/value_objects/device_id.dart';

void main() {
  group('ConnectionRegistry', () {
    late ConnectionRegistry registry;

    setUp(() {
      registry = ConnectionRegistry();
    });

    group('pending handshakes', () {
      test('registerPendingHandshake adds to pending set', () {
        const deviceId = DeviceId('device-1');

        registry.registerPendingHandshake(deviceId);

        expect(registry.hasPendingHandshake(deviceId), isTrue);
      });

      test('hasPendingHandshake returns false for unknown device', () {
        const deviceId = DeviceId('device-1');

        expect(registry.hasPendingHandshake(deviceId), isFalse);
      });

      test('cancelPendingHandshake removes pending and returns event', () {
        const deviceId = DeviceId('device-1');
        registry.registerPendingHandshake(deviceId);

        final event = registry.cancelPendingHandshake(deviceId, 'timeout');

        expect(event, isA<HandshakeFailed>());
        expect((event as HandshakeFailed).deviceId, deviceId);
        expect(event.reason, 'timeout');
        expect(registry.hasPendingHandshake(deviceId), isFalse);
      });

      test('cancelPendingHandshake returns null if not pending', () {
        const deviceId = DeviceId('device-1');

        final event = registry.cancelPendingHandshake(deviceId, 'timeout');

        expect(event, isNull);
      });
    });

    group('completeHandshake', () {
      test('creates connection and returns HandshakeCompleted', () {
        const deviceId = DeviceId('device-1');
        final nodeId = NodeId('node-abc');
        registry.registerPendingHandshake(deviceId);

        final event = registry.completeHandshake(deviceId, nodeId);

        expect(event, isA<HandshakeCompleted>());
        expect(event.deviceId, deviceId);
        expect(event.nodeId, nodeId);
        expect(registry.hasPendingHandshake(deviceId), isFalse);
        expect(registry.connectionCount, 1);
      });

      test('allows lookup by deviceId after completion', () {
        const deviceId = DeviceId('device-1');
        final nodeId = NodeId('node-abc');
        registry.registerPendingHandshake(deviceId);
        registry.completeHandshake(deviceId, nodeId);

        expect(registry.getNodeIdForDevice(deviceId), nodeId);
      });

      test('allows lookup by nodeId after completion', () {
        const deviceId = DeviceId('device-1');
        final nodeId = NodeId('node-abc');
        registry.registerPendingHandshake(deviceId);
        registry.completeHandshake(deviceId, nodeId);

        expect(registry.getDeviceIdForNode(nodeId), deviceId);
      });

      test('enforces NodeId uniqueness - replaces old connection', () {
        const device1 = DeviceId('device-1');
        const device2 = DeviceId('device-2');
        final nodeId = NodeId('node-abc');

        registry.registerPendingHandshake(device1);
        registry.completeHandshake(device1, nodeId);

        registry.registerPendingHandshake(device2);
        registry.completeHandshake(device2, nodeId);

        // Old connection should be gone
        expect(registry.getNodeIdForDevice(device1), isNull);
        // New connection should exist
        expect(registry.getNodeIdForDevice(device2), nodeId);
        expect(registry.getDeviceIdForNode(nodeId), device2);
        expect(registry.connectionCount, 1);
      });
    });

    group('removeConnection', () {
      test('removes connection and returns ConnectionClosed', () {
        const deviceId = DeviceId('device-1');
        final nodeId = NodeId('node-abc');
        registry.registerPendingHandshake(deviceId);
        registry.completeHandshake(deviceId, nodeId);

        final event = registry.removeConnection(deviceId, 'disconnected');

        expect(event, isA<ConnectionClosed>());
        expect((event as ConnectionClosed).nodeId, nodeId);
        expect(event.reason, 'disconnected');
        expect(registry.connectionCount, 0);
        expect(registry.getNodeIdForDevice(deviceId), isNull);
        expect(registry.getDeviceIdForNode(nodeId), isNull);
      });

      test('returns null if no connection exists', () {
        const deviceId = DeviceId('device-1');

        final event = registry.removeConnection(deviceId, 'disconnected');

        expect(event, isNull);
      });
    });

    group('getConnection', () {
      test('returns connection if exists', () {
        const deviceId = DeviceId('device-1');
        final nodeId = NodeId('node-abc');
        registry.registerPendingHandshake(deviceId);
        registry.completeHandshake(deviceId, nodeId);

        final connection = registry.getConnection(deviceId);

        expect(connection, isNotNull);
        expect(connection!.deviceId, deviceId);
        expect(connection.nodeId, nodeId);
      });

      test('returns null if no connection', () {
        const deviceId = DeviceId('device-1');

        expect(registry.getConnection(deviceId), isNull);
      });
    });

    group('connections iterable', () {
      test('returns all connections', () {
        const device1 = DeviceId('device-1');
        const device2 = DeviceId('device-2');
        final node1 = NodeId('node-1');
        final node2 = NodeId('node-2');

        registry.registerPendingHandshake(device1);
        registry.completeHandshake(device1, node1);
        registry.registerPendingHandshake(device2);
        registry.completeHandshake(device2, node2);

        final connections = registry.connections.toList();
        expect(connections, hasLength(2));
      });
    });
  });
}
