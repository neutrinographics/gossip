import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_ble/src/application/services/connection_service.dart';
import 'package:gossip_ble/src/domain/aggregates/connection_registry.dart';
import 'package:gossip_ble/src/domain/events/connection_event.dart';
import 'package:gossip_ble/src/domain/ports/ble_port.dart';
import 'package:gossip_ble/src/domain/value_objects/device_id.dart';
import 'package:gossip_ble/src/infrastructure/codec/handshake_codec.dart';
import 'package:mocktail/mocktail.dart';

class MockTimePort extends Mock implements TimePort {}

class MockBlePort extends Mock implements BlePort {}

void main() {
  setUpAll(() {
    registerFallbackValue(const DeviceId('fallback'));
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(Duration.zero);
  });

  group('ConnectionService', () {
    late MockBlePort mockPort;
    late MockTimePort mockTimePort;
    late ConnectionRegistry registry;
    late ConnectionService service;
    late StreamController<BleEvent> eventController;
    late NodeId localNodeId;

    setUp(() {
      mockPort = MockBlePort();
      mockTimePort = MockTimePort();
      registry = ConnectionRegistry();
      eventController = StreamController<BleEvent>.broadcast();
      localNodeId = NodeId('local-node-123');

      when(() => mockPort.events).thenAnswer((_) => eventController.stream);
      when(() => mockPort.send(any(), any())).thenAnswer((_) async {});
      when(() => mockPort.disconnect(any())).thenAnswer((_) async {});
      // Make delay() never complete so timeout doesn't fire during tests
      when(
        () => mockTimePort.delay(any()),
      ).thenAnswer((_) => Completer<void>().future);

      service = ConnectionService(
        localNodeId: localNodeId,
        blePort: mockPort,
        registry: registry,
        codec: const HandshakeCodec(),
        timePort: mockTimePort,
      );
    });

    tearDown(() async {
      await service.dispose();
      await eventController.close();
    });

    group('connection established', () {
      test('registers pending handshake and sends local NodeId', () async {
        const deviceId = DeviceId('device-1');

        eventController.add(const ConnectionEstablished(id: deviceId));
        await Future<void>.delayed(Duration.zero);

        expect(registry.hasPendingHandshake(deviceId), isTrue);

        final captured =
            verify(() => mockPort.send(deviceId, captureAny())).captured.single
                as Uint8List;

        const codec = HandshakeCodec();
        final decoded = codec.decodeHandshake(captured);
        expect(decoded?.value, 'local-node-123');
      });
    });

    group('handshake received', () {
      test('completes handshake and emits HandshakeCompleted', () async {
        const deviceId = DeviceId('device-1');
        final remoteNodeId = NodeId('remote-node-456');
        const codec = HandshakeCodec();

        // Simulate connection established
        eventController.add(const ConnectionEstablished(id: deviceId));
        await Future<void>.delayed(Duration.zero);

        // Listen for events
        final events = <ConnectionEvent>[];
        service.events.listen(events.add);

        // Simulate receiving handshake
        final handshakeBytes = codec.encodeHandshake(remoteNodeId);
        eventController.add(BytesReceived(id: deviceId, bytes: handshakeBytes));
        await Future<void>.delayed(Duration.zero);

        expect(events, hasLength(1));
        expect(events.first, isA<HandshakeCompleted>());
        final completed = events.first as HandshakeCompleted;
        expect(completed.nodeId, remoteNodeId);
        expect(completed.deviceId, deviceId);

        // Registry should have the connection
        expect(registry.getNodeIdForDevice(deviceId), remoteNodeId);
      });
    });

    group('gossip message received', () {
      test('forwards gossip message with NodeId to callback', () async {
        const deviceId = DeviceId('device-1');
        final remoteNodeId = NodeId('remote-node-456');
        const codec = HandshakeCodec();

        // Set up connection
        eventController.add(const ConnectionEstablished(id: deviceId));
        await Future<void>.delayed(Duration.zero);

        final handshakeBytes = codec.encodeHandshake(remoteNodeId);
        eventController.add(BytesReceived(id: deviceId, bytes: handshakeBytes));
        await Future<void>.delayed(Duration.zero);

        // Listen for gossip messages
        final gossipMessages = <(NodeId, Uint8List)>[];
        service.onGossipMessage = (nodeId, bytes) {
          gossipMessages.add((nodeId, bytes));
        };

        // Send a gossip message
        final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
        final gossipBytes = codec.wrapGossip(payload);
        eventController.add(BytesReceived(id: deviceId, bytes: gossipBytes));
        await Future<void>.delayed(Duration.zero);

        expect(gossipMessages, hasLength(1));
        expect(gossipMessages.first.$1, remoteNodeId);
        expect(gossipMessages.first.$2, payload);
      });

      test('ignores gossip from unknown device', () async {
        const deviceId = DeviceId('unknown-device');
        const codec = HandshakeCodec();

        final gossipMessages = <(NodeId, Uint8List)>[];
        service.onGossipMessage = (nodeId, bytes) {
          gossipMessages.add((nodeId, bytes));
        };

        final payload = Uint8List.fromList([1, 2, 3]);
        final gossipBytes = codec.wrapGossip(payload);
        eventController.add(BytesReceived(id: deviceId, bytes: gossipBytes));
        await Future<void>.delayed(Duration.zero);

        expect(gossipMessages, isEmpty);
      });
    });

    group('sendGossipMessage', () {
      test('wraps and sends gossip message to correct device', () async {
        const deviceId = DeviceId('device-1');
        final remoteNodeId = NodeId('remote-node-456');
        const codec = HandshakeCodec();

        // Set up connection
        eventController.add(const ConnectionEstablished(id: deviceId));
        await Future<void>.delayed(Duration.zero);

        final handshakeBytes = codec.encodeHandshake(remoteNodeId);
        eventController.add(BytesReceived(id: deviceId, bytes: handshakeBytes));
        await Future<void>.delayed(Duration.zero);

        // Clear previous send calls
        clearInteractions(mockPort);
        when(() => mockPort.send(any(), any())).thenAnswer((_) async {});

        // Send gossip
        final payload = Uint8List.fromList([10, 20, 30]);
        await service.sendGossipMessage(remoteNodeId, payload);

        final captured =
            verify(() => mockPort.send(deviceId, captureAny())).captured.single
                as Uint8List;

        final unwrapped = codec.unwrapGossip(captured);
        expect(unwrapped, payload);
      });

      test('does nothing if node is not connected', () async {
        final unknownNodeId = NodeId('unknown-node');
        final payload = Uint8List.fromList([1, 2, 3]);

        await service.sendGossipMessage(unknownNodeId, payload);

        verifyNever(() => mockPort.send(any(), any()));
      });
    });

    group('disconnection', () {
      test('emits ConnectionClosed and cleans up registry', () async {
        const deviceId = DeviceId('device-1');
        final remoteNodeId = NodeId('remote-node-456');
        const codec = HandshakeCodec();

        // Set up connection
        eventController.add(const ConnectionEstablished(id: deviceId));
        await Future<void>.delayed(Duration.zero);

        final handshakeBytes = codec.encodeHandshake(remoteNodeId);
        eventController.add(BytesReceived(id: deviceId, bytes: handshakeBytes));
        await Future<void>.delayed(Duration.zero);

        // Listen for events
        final events = <ConnectionEvent>[];
        service.events.listen(events.add);

        // Disconnect
        eventController.add(const DeviceDisconnected(id: deviceId));
        await Future<void>.delayed(Duration.zero);

        // Should have HandshakeCompleted and ConnectionClosed
        final closedEvents = events.whereType<ConnectionClosed>().toList();
        expect(closedEvents, hasLength(1));
        expect(closedEvents.first.nodeId, remoteNodeId);

        // Registry should be cleaned up
        expect(registry.getNodeIdForDevice(deviceId), isNull);
      });
    });
  });
}
