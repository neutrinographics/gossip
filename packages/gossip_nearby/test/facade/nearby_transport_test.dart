import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_nearby/src/application/observability/log_level.dart';
import 'package:gossip_nearby/src/domain/errors/connection_error.dart';
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
        await transport.startAdvertising();
        await transport.stopAdvertising();

        verify(() => mockNearbyPort.stopAdvertising()).called(1);
      });

      test('isAdvertising is false initially', () {
        expect(transport.isAdvertising, isFalse);
      });

      test('isAdvertising is true after startAdvertising', () async {
        await transport.startAdvertising();

        expect(transport.isAdvertising, isTrue);
      });

      test('isAdvertising is false after stopAdvertising', () async {
        await transport.startAdvertising();
        await transport.stopAdvertising();

        expect(transport.isAdvertising, isFalse);
      });

      test('startAdvertising is idempotent', () async {
        await transport.startAdvertising();
        await transport.startAdvertising();

        verify(() => mockNearbyPort.startAdvertising(any(), any())).called(1);
      });

      test('stopAdvertising is idempotent', () async {
        await transport.stopAdvertising();

        verifyNever(() => mockNearbyPort.stopAdvertising());
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
        await transport.startDiscovery();
        await transport.stopDiscovery();

        verify(() => mockNearbyPort.stopDiscovery()).called(1);
      });

      test('isDiscovering is false initially', () {
        expect(transport.isDiscovering, isFalse);
      });

      test('isDiscovering is true after startDiscovery', () async {
        await transport.startDiscovery();

        expect(transport.isDiscovering, isTrue);
      });

      test('isDiscovering is false after stopDiscovery', () async {
        await transport.startDiscovery();
        await transport.stopDiscovery();

        expect(transport.isDiscovering, isFalse);
      });

      test('startDiscovery is idempotent', () async {
        await transport.startDiscovery();
        await transport.startDiscovery();

        verify(() => mockNearbyPort.startDiscovery(any())).called(1);
      });

      test('stopDiscovery is idempotent', () async {
        await transport.stopDiscovery();

        verifyNever(() => mockNearbyPort.stopDiscovery());
      });
    });

    group('metrics', () {
      test('exposes metrics from connection service', () {
        expect(transport.metrics, isNotNull);
        expect(transport.metrics.connectedPeerCount, equals(0));
      });
    });

    group('logging', () {
      test('invokes onLog callback when provided', () async {
        final logs = <(LogLevel, String)>[];

        await transport.dispose();
        await nearbyEventController.close();

        nearbyEventController = StreamController<NearbyEvent>.broadcast();
        when(
          () => mockNearbyPort.events,
        ).thenAnswer((_) => nearbyEventController.stream);

        transport = NearbyTransport.withPort(
          localNodeId: NodeId('local-node'),
          serviceId: ServiceId('com.example.app'),
          displayName: 'Test Device',
          nearbyPort: mockNearbyPort,
          onLog: (level, message, [error, stack]) {
            logs.add((level, message));
          },
        );

        await transport.startAdvertising();

        expect(logs, isNotEmpty);
        expect(logs.any((log) => log.$1 == LogLevel.info), isTrue);
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

    group('errors', () {
      test('exposes errors stream', () {
        expect(transport.errors, isA<Stream<ConnectionError>>());
      });

      test('forwards errors from ConnectionService', () async {
        final errors = <ConnectionError>[];
        transport.errors.listen(errors.add);

        // Try to send to unknown peer via messagePort
        await transport.messagePort.send(
          NodeId('unknown-peer'),
          Uint8List.fromList([1, 2, 3]),
        );
        await Future.delayed(Duration.zero);

        expect(errors, hasLength(1));
        expect(errors.first, isA<ConnectionNotFoundError>());
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
