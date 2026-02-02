import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_ble/gossip_ble.dart';
import 'package:gossip_ble/src/domain/ports/ble_port.dart';
import 'package:gossip_ble/src/infrastructure/codec/handshake_codec.dart';
import 'package:mocktail/mocktail.dart';

class MockBlePort extends Mock implements BlePort {}

void main() {
  setUpAll(() {
    registerFallbackValue(const DeviceId('fallback'));
    registerFallbackValue(const ServiceId('fallback'));
    registerFallbackValue(Uint8List(0));
  });

  group('BleTransport', () {
    late MockBlePort mockPort;
    late StreamController<BleEvent> eventController;
    late BleTransport transport;
    late NodeId localNodeId;

    setUp(() {
      mockPort = MockBlePort();
      eventController = StreamController<BleEvent>.broadcast();
      localNodeId = NodeId('local-node-123');

      when(() => mockPort.events).thenAnswer((_) => eventController.stream);
      when(
        () => mockPort.startAdvertising(any(), any()),
      ).thenAnswer((_) async {});
      when(() => mockPort.stopAdvertising()).thenAnswer((_) async {});
      when(() => mockPort.startDiscovery(any())).thenAnswer((_) async {});
      when(() => mockPort.stopDiscovery()).thenAnswer((_) async {});
      when(() => mockPort.requestConnection(any())).thenAnswer((_) async {});
      when(() => mockPort.send(any(), any())).thenAnswer((_) async {});
      when(() => mockPort.dispose()).thenAnswer((_) async {});

      transport = BleTransport.withPort(
        localNodeId: localNodeId,
        serviceId: const ServiceId('com.test.app'),
        displayName: 'Test Device',
        blePort: mockPort,
      );
    });

    tearDown(() async {
      await transport.dispose();
      await eventController.close();
    });

    test('provides MessagePort for gossip integration', () {
      expect(transport.messagePort, isNotNull);
    });

    test('starts and stops advertising', () async {
      expect(transport.isAdvertising, isFalse);

      await transport.startAdvertising();
      expect(transport.isAdvertising, isTrue);

      await transport.stopAdvertising();
      expect(transport.isAdvertising, isFalse);

      verify(() => mockPort.startAdvertising(any(), 'Test Device')).called(1);
      verify(() => mockPort.stopAdvertising()).called(1);
    });

    test('starts and stops discovery', () async {
      expect(transport.isDiscovering, isFalse);

      await transport.startDiscovery();
      expect(transport.isDiscovering, isTrue);

      await transport.stopDiscovery();
      expect(transport.isDiscovering, isFalse);

      verify(() => mockPort.startDiscovery(any())).called(1);
      verify(() => mockPort.stopDiscovery()).called(1);
    });

    test('emits PeerConnected after handshake completes', () async {
      const deviceId = DeviceId('device-1');
      final remoteNodeId = NodeId('remote-node-456');
      const codec = HandshakeCodec();

      final peerEvents = <PeerEvent>[];
      transport.peerEvents.listen(peerEvents.add);

      // Simulate connection and handshake
      eventController.add(const ConnectionEstablished(id: deviceId));
      await Future<void>.delayed(Duration.zero);

      final handshakeBytes = codec.encodeHandshake(remoteNodeId);
      eventController.add(BytesReceived(id: deviceId, bytes: handshakeBytes));
      await Future<void>.delayed(Duration.zero);

      expect(peerEvents, hasLength(1));
      expect(peerEvents.first, isA<PeerConnected>());
      expect((peerEvents.first as PeerConnected).nodeId, remoteNodeId);

      expect(transport.connectedPeers, contains(remoteNodeId));
      expect(transport.connectedPeerCount, 1);
    });

    test('emits PeerDisconnected when device disconnects', () async {
      const deviceId = DeviceId('device-1');
      final remoteNodeId = NodeId('remote-node-456');
      const codec = HandshakeCodec();

      final peerEvents = <PeerEvent>[];
      transport.peerEvents.listen(peerEvents.add);

      // Set up connection
      eventController.add(const ConnectionEstablished(id: deviceId));
      await Future<void>.delayed(Duration.zero);

      final handshakeBytes = codec.encodeHandshake(remoteNodeId);
      eventController.add(BytesReceived(id: deviceId, bytes: handshakeBytes));
      await Future<void>.delayed(Duration.zero);

      // Disconnect
      eventController.add(const DeviceDisconnected(id: deviceId));
      await Future<void>.delayed(Duration.zero);

      expect(peerEvents, hasLength(2));
      expect(peerEvents[1], isA<PeerDisconnected>());
      expect((peerEvents[1] as PeerDisconnected).nodeId, remoteNodeId);

      expect(transport.connectedPeers, isEmpty);
      expect(transport.connectedPeerCount, 0);
    });

    test('messagePort sends gossip messages', () async {
      const deviceId = DeviceId('device-1');
      final remoteNodeId = NodeId('remote-node-456');
      const codec = HandshakeCodec();

      // Set up connection
      eventController.add(const ConnectionEstablished(id: deviceId));
      await Future<void>.delayed(Duration.zero);

      final handshakeBytes = codec.encodeHandshake(remoteNodeId);
      eventController.add(BytesReceived(id: deviceId, bytes: handshakeBytes));
      await Future<void>.delayed(Duration.zero);

      // Clear previous interactions
      clearInteractions(mockPort);
      when(() => mockPort.send(any(), any())).thenAnswer((_) async {});

      // Send via messagePort
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      await transport.messagePort.send(remoteNodeId, payload);

      verify(() => mockPort.send(deviceId, any())).called(1);
    });

    test('messagePort receives gossip messages', () async {
      const deviceId = DeviceId('device-1');
      final remoteNodeId = NodeId('remote-node-456');
      const codec = HandshakeCodec();

      // Set up connection
      eventController.add(const ConnectionEstablished(id: deviceId));
      await Future<void>.delayed(Duration.zero);

      final handshakeBytes = codec.encodeHandshake(remoteNodeId);
      eventController.add(BytesReceived(id: deviceId, bytes: handshakeBytes));
      await Future<void>.delayed(Duration.zero);

      // Listen for incoming messages
      final incoming = <IncomingMessage>[];
      transport.messagePort.incoming.listen(incoming.add);

      // Send a gossip message
      final payload = Uint8List.fromList([10, 20, 30]);
      final gossipBytes = codec.wrapGossip(payload);
      eventController.add(BytesReceived(id: deviceId, bytes: gossipBytes));
      await Future<void>.delayed(Duration.zero);

      expect(incoming, hasLength(1));
      expect(incoming.first.sender, remoteNodeId);
      expect(incoming.first.bytes, payload);
    });

    test('auto-connects when device is discovered', () async {
      const deviceId = DeviceId('discovered-device-1');

      // Simulate device discovery
      eventController.add(
        const DeviceDiscovered(id: deviceId, displayName: 'Peer Device'),
      );
      await Future<void>.delayed(Duration.zero);

      // Should have requested connection to the discovered device
      verify(() => mockPort.requestConnection(deviceId)).called(1);
    });

    test('auto-connects to multiple discovered devices', () async {
      const deviceId1 = DeviceId('discovered-device-1');
      const deviceId2 = DeviceId('discovered-device-2');

      // Simulate multiple device discoveries
      eventController.add(
        const DeviceDiscovered(id: deviceId1, displayName: 'Peer 1'),
      );
      eventController.add(
        const DeviceDiscovered(id: deviceId2, displayName: 'Peer 2'),
      );
      await Future<void>.delayed(Duration.zero);

      // Should have requested connections to both devices
      verify(() => mockPort.requestConnection(deviceId1)).called(1);
      verify(() => mockPort.requestConnection(deviceId2)).called(1);
    });
  });
}
