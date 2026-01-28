import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_nearby/src/application/services/connection_service.dart';
import 'package:gossip_nearby/src/domain/aggregates/connection_registry.dart';
import 'package:gossip_nearby/src/domain/events/connection_event.dart';
import 'package:gossip_nearby/src/domain/interfaces/nearby_port.dart';
import 'package:gossip_nearby/src/domain/value_objects/endpoint.dart';
import 'package:gossip_nearby/src/domain/value_objects/endpoint_id.dart';
import 'package:gossip_nearby/src/domain/value_objects/service_id.dart';
import 'package:mocktail/mocktail.dart';

class MockNearbyPort extends Mock implements NearbyPort {}

void main() {
  setUpAll(() {
    registerFallbackValue(EndpointId('fallback'));
    registerFallbackValue(Uint8List(0));
  });

  group('ConnectionService', () {
    late ConnectionService service;
    late MockNearbyPort mockNearbyPort;
    late ConnectionRegistry registry;
    late StreamController<NearbyEvent> nearbyEventController;
    late NodeId localNodeId;

    setUp(() {
      mockNearbyPort = MockNearbyPort();
      registry = ConnectionRegistry();
      nearbyEventController = StreamController<NearbyEvent>.broadcast();
      localNodeId = NodeId('local-node-123');

      when(
        () => mockNearbyPort.events,
      ).thenAnswer((_) => nearbyEventController.stream);
      when(
        () => mockNearbyPort.requestConnection(any()),
      ).thenAnswer((_) async {});
      when(
        () => mockNearbyPort.sendPayload(any(), any()),
      ).thenAnswer((_) async {});
      when(() => mockNearbyPort.disconnect(any())).thenAnswer((_) async {});

      service = ConnectionService(
        localNodeId: localNodeId,
        nearbyPort: mockNearbyPort,
        registry: registry,
      );
    });

    tearDown(() async {
      await nearbyEventController.close();
      await service.dispose();
    });

    group('endpoint discovery', () {
      test('requests connection when endpoint is discovered', () async {
        final endpointId = EndpointId('remote-ep');

        nearbyEventController.add(
          EndpointDiscovered(id: endpointId, displayName: 'Remote Device'),
        );

        await Future.delayed(Duration.zero);

        verify(() => mockNearbyPort.requestConnection(endpointId)).called(1);
      });
    });

    group('handshake flow', () {
      test('sends handshake when connection is established', () async {
        final endpointId = EndpointId('remote-ep');

        nearbyEventController.add(ConnectionEstablished(id: endpointId));

        await Future.delayed(Duration.zero);

        verify(() => mockNearbyPort.sendPayload(endpointId, any())).called(1);
        expect(registry.hasPendingHandshake(endpointId), isTrue);
      });

      test(
        'completes handshake when valid handshake payload received',
        () async {
          final endpointId = EndpointId('remote-ep');
          final remoteNodeId = NodeId('remote-node-456');

          // Simulate connection established
          nearbyEventController.add(ConnectionEstablished(id: endpointId));
          await Future.delayed(Duration.zero);

          // Capture the events emitted
          final events = <ConnectionEvent>[];
          service.events.listen(events.add);

          // Simulate receiving handshake from remote
          final handshakePayload = _encodeHandshake(remoteNodeId);
          nearbyEventController.add(
            PayloadReceived(id: endpointId, bytes: handshakePayload),
          );
          await Future.delayed(Duration.zero);

          expect(events, hasLength(1));
          expect(events.first, isA<HandshakeCompleted>());
          expect(
            (events.first as HandshakeCompleted).nodeId,
            equals(remoteNodeId),
          );
          expect(
            registry.getNodeIdForEndpoint(endpointId),
            equals(remoteNodeId),
          );
        },
      );

      test('emits ConnectionClosed when endpoint disconnects', () async {
        final endpointId = EndpointId('remote-ep');
        final remoteNodeId = NodeId('remote-node-456');

        // Establish connection
        nearbyEventController.add(ConnectionEstablished(id: endpointId));
        await Future.delayed(Duration.zero);

        // Complete handshake
        nearbyEventController.add(
          PayloadReceived(
            id: endpointId,
            bytes: _encodeHandshake(remoteNodeId),
          ),
        );
        await Future.delayed(Duration.zero);

        // Capture events
        final events = <ConnectionEvent>[];
        service.events.listen(events.add);

        // Disconnect
        nearbyEventController.add(Disconnected(id: endpointId));
        await Future.delayed(Duration.zero);

        expect(events.whereType<ConnectionClosed>(), hasLength(1));
      });
    });

    group('message forwarding', () {
      test('forwards gossip messages to onGossipMessage callback', () async {
        final endpointId = EndpointId('remote-ep');
        final remoteNodeId = NodeId('remote-node-456');
        final gossipPayload = Uint8List.fromList([0x02, 1, 2, 3, 4]);

        // Establish and complete handshake
        nearbyEventController.add(ConnectionEstablished(id: endpointId));
        await Future.delayed(Duration.zero);
        nearbyEventController.add(
          PayloadReceived(
            id: endpointId,
            bytes: _encodeHandshake(remoteNodeId),
          ),
        );
        await Future.delayed(Duration.zero);

        // Capture gossip messages
        final messages = <(NodeId, Uint8List)>[];
        service.onGossipMessage = (nodeId, bytes) =>
            messages.add((nodeId, bytes));

        // Send gossip message
        nearbyEventController.add(
          PayloadReceived(id: endpointId, bytes: gossipPayload),
        );
        await Future.delayed(Duration.zero);

        expect(messages, hasLength(1));
        expect(messages.first.$1, equals(remoteNodeId));
        expect(messages.first.$2, equals(Uint8List.fromList([1, 2, 3, 4])));
      });
    });

    group('sending messages', () {
      test('sends wrapped gossip message to connected peer', () async {
        final endpointId = EndpointId('remote-ep');
        final remoteNodeId = NodeId('remote-node-456');
        final payload = Uint8List.fromList([1, 2, 3, 4]);

        // Establish and complete handshake
        nearbyEventController.add(ConnectionEstablished(id: endpointId));
        await Future.delayed(Duration.zero);
        nearbyEventController.add(
          PayloadReceived(
            id: endpointId,
            bytes: _encodeHandshake(remoteNodeId),
          ),
        );
        await Future.delayed(Duration.zero);

        // Clear previous send calls
        clearInteractions(mockNearbyPort);
        when(
          () => mockNearbyPort.sendPayload(any(), any()),
        ).thenAnswer((_) async {});

        // Send message
        await service.sendGossipMessage(remoteNodeId, payload);

        final captured = verify(
          () => mockNearbyPort.sendPayload(endpointId, captureAny()),
        ).captured;

        expect(captured, hasLength(1));
        final sentBytes = captured.first as Uint8List;
        // Should be wrapped with 0x02 prefix
        expect(sentBytes[0], equals(0x02));
        expect(sentBytes.sublist(1), equals(payload));
      });
    });
  });
}

/// Encodes a handshake message with the given NodeId.
/// Format: [0x01][length:4 bytes][nodeId:UTF-8 bytes]
Uint8List _encodeHandshake(NodeId nodeId) {
  final nodeIdBytes = nodeId.value.codeUnits;
  final buffer = ByteData(5 + nodeIdBytes.length);
  buffer.setUint8(0, 0x01);
  buffer.setUint32(1, nodeIdBytes.length, Endian.big);
  final result = buffer.buffer.asUint8List();
  result.setRange(5, 5 + nodeIdBytes.length, nodeIdBytes);
  return result;
}
