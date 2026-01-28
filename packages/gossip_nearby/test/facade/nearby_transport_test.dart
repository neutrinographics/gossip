import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_nearby/src/domain/interfaces/nearby_port.dart';
import 'package:gossip_nearby/src/domain/value_objects/endpoint_id.dart';
import 'package:gossip_nearby/src/domain/value_objects/service_id.dart';
import 'package:gossip_nearby/src/facade/nearby_transport.dart';
import 'package:mocktail/mocktail.dart';

class MockNearbyPort extends Mock implements NearbyPort {}

void main() {
  setUpAll(() {
    registerFallbackValue(EndpointId('fallback'));
    registerFallbackValue(ServiceId('fallback'));
    registerFallbackValue(Uint8List(0));
  });

  group('NearbyTransport', () {
    late NearbyTransport transport;
    late MockNearbyPort mockNearbyPort;
    late StreamController<NearbyEvent> nearbyEventController;

    setUp(() {
      mockNearbyPort = MockNearbyPort();
      nearbyEventController = StreamController<NearbyEvent>.broadcast();

      when(
        () => mockNearbyPort.events,
      ).thenAnswer((_) => nearbyEventController.stream);
      when(
        () => mockNearbyPort.startAdvertising(any(), any()),
      ).thenAnswer((_) async {});
      when(() => mockNearbyPort.stopAdvertising()).thenAnswer((_) async {});
      when(() => mockNearbyPort.startDiscovery(any())).thenAnswer((_) async {});
      when(() => mockNearbyPort.stopDiscovery()).thenAnswer((_) async {});
      when(
        () => mockNearbyPort.requestConnection(any()),
      ).thenAnswer((_) async {});
      when(
        () => mockNearbyPort.sendPayload(any(), any()),
      ).thenAnswer((_) async {});
      when(() => mockNearbyPort.disconnect(any())).thenAnswer((_) async {});

      transport = NearbyTransport.withPort(
        localNodeId: NodeId('local-node'),
        serviceId: ServiceId('com.example.app'),
        displayName: 'Test Device',
        nearbyPort: mockNearbyPort,
      );
    });

    tearDown(() async {
      await nearbyEventController.close();
      await transport.dispose();
    });

    group('advertising', () {
      test('startAdvertising delegates to NearbyPort', () async {
        await transport.startAdvertising();

        verify(
          () => mockNearbyPort.startAdvertising(
            ServiceId('com.example.app'),
            'Test Device',
          ),
        ).called(1);
      });

      test('stopAdvertising delegates to NearbyPort', () async {
        await transport.stopAdvertising();

        verify(() => mockNearbyPort.stopAdvertising()).called(1);
      });
    });

    group('discovery', () {
      test('startDiscovery delegates to NearbyPort', () async {
        await transport.startDiscovery();

        verify(
          () => mockNearbyPort.startDiscovery(ServiceId('com.example.app')),
        ).called(1);
      });

      test('stopDiscovery delegates to NearbyPort', () async {
        await transport.stopDiscovery();

        verify(() => mockNearbyPort.stopDiscovery()).called(1);
      });
    });

    group('peer events', () {
      test('emits PeerConnected when handshake completes', () async {
        final endpointId = EndpointId('remote-ep');
        final remoteNodeId = NodeId('remote-node');

        final peerEvents = <PeerEvent>[];
        transport.peerEvents.listen(peerEvents.add);

        // Simulate connection and handshake
        nearbyEventController.add(ConnectionEstablished(id: endpointId));
        await Future.delayed(Duration.zero);

        nearbyEventController.add(
          PayloadReceived(
            id: endpointId,
            bytes: _encodeHandshake(remoteNodeId),
          ),
        );
        await Future.delayed(Duration.zero);

        expect(peerEvents, hasLength(1));
        expect(peerEvents.first, isA<PeerConnected>());
        expect(
          (peerEvents.first as PeerConnected).nodeId,
          equals(remoteNodeId),
        );
      });

      test('emits PeerDisconnected when connection closes', () async {
        final endpointId = EndpointId('remote-ep');
        final remoteNodeId = NodeId('remote-node');

        // Establish connection first
        nearbyEventController.add(ConnectionEstablished(id: endpointId));
        await Future.delayed(Duration.zero);
        nearbyEventController.add(
          PayloadReceived(
            id: endpointId,
            bytes: _encodeHandshake(remoteNodeId),
          ),
        );
        await Future.delayed(Duration.zero);

        final peerEvents = <PeerEvent>[];
        transport.peerEvents.listen(peerEvents.add);

        // Disconnect
        nearbyEventController.add(Disconnected(id: endpointId));
        await Future.delayed(Duration.zero);

        expect(peerEvents.whereType<PeerDisconnected>(), hasLength(1));
      });
    });

    group('messagePort', () {
      test('returns a valid MessagePort', () {
        expect(transport.messagePort, isNotNull);
        expect(transport.messagePort, isA<MessagePort>());
      });
    });

    group('connectedPeers', () {
      test('returns connected peer NodeIds', () async {
        final endpointId = EndpointId('remote-ep');
        final remoteNodeId = NodeId('remote-node');

        // Establish connection
        nearbyEventController.add(ConnectionEstablished(id: endpointId));
        await Future.delayed(Duration.zero);
        nearbyEventController.add(
          PayloadReceived(
            id: endpointId,
            bytes: _encodeHandshake(remoteNodeId),
          ),
        );
        await Future.delayed(Duration.zero);

        expect(transport.connectedPeers, contains(remoteNodeId));
        expect(transport.connectedPeerCount, equals(1));
      });
    });
  });
}

/// Encodes a handshake message.
Uint8List _encodeHandshake(NodeId nodeId) {
  final nodeIdBytes = nodeId.value.codeUnits;
  final buffer = ByteData(5 + nodeIdBytes.length);
  buffer.setUint8(0, 0x01);
  buffer.setUint32(1, nodeIdBytes.length, Endian.big);
  final result = buffer.buffer.asUint8List();
  result.setRange(5, 5 + nodeIdBytes.length, nodeIdBytes);
  return result;
}
