import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_nearby/src/application/services/connection_service.dart';
import 'package:gossip_nearby/src/domain/aggregates/connection_registry.dart';
import 'package:gossip_nearby/src/domain/errors/connection_error.dart';
import 'package:gossip_nearby/src/domain/events/connection_event.dart';
import 'package:gossip_nearby/src/domain/interfaces/nearby_port.dart';
import 'package:gossip_nearby/src/domain/value_objects/endpoint_id.dart';
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

      group('duplicate discovery', () {
        test(
          'does not request connection when peer is already connected',
          () async {
            final ep1 = EndpointId('ep1');
            final ep2 = EndpointId('ep2');
            final remoteNodeId = NodeId('remote-node-456');
            const advertisedName = 'remote-node-456|Remote Device';

            // First discovery → connection → handshake (full lifecycle)
            nearbyEventController.add(
              EndpointDiscovered(id: ep1, displayName: advertisedName),
            );
            await Future.delayed(Duration.zero);

            nearbyEventController.add(ConnectionEstablished(id: ep1));
            await Future.delayed(Duration.zero);

            nearbyEventController.add(
              PayloadReceived(id: ep1, bytes: _encodeHandshake(remoteNodeId)),
            );
            await Future.delayed(Duration.zero);

            // Verify peer is now connected
            expect(registry.getEndpointIdForNodeId(remoteNodeId), equals(ep1));

            clearInteractions(mockNearbyPort);

            // Second discovery with different EndpointId, same NodeId
            nearbyEventController.add(
              EndpointDiscovered(id: ep2, displayName: advertisedName),
            );
            await Future.delayed(Duration.zero);

            verifyNever(() => mockNearbyPort.requestConnection(ep2));
          },
        );

        test('requests connection when peer is not yet connected', () async {
          final endpointId = EndpointId('remote-ep');
          const advertisedName = 'remote-node-456|Remote Device';

          nearbyEventController.add(
            EndpointDiscovered(id: endpointId, displayName: advertisedName),
          );
          await Future.delayed(Duration.zero);

          verify(() => mockNearbyPort.requestConnection(endpointId)).called(1);
        });

        test(
          'requests connection when nodeId cannot be parsed from name',
          () async {
            final endpointId = EndpointId('remote-ep');

            nearbyEventController.add(
              EndpointDiscovered(id: endpointId, displayName: 'Remote Device'),
            );
            await Future.delayed(Duration.zero);

            verify(
              () => mockNearbyPort.requestConnection(endpointId),
            ).called(1);
          },
        );

        test(
          'does not request connection when discovered nodeId is own nodeId',
          () async {
            final endpointId = EndpointId('self-ep');
            // localNodeId is 'local-node-123' from setUp
            const advertisedName = 'local-node-123|My Device';

            nearbyEventController.add(
              EndpointDiscovered(id: endpointId, displayName: advertisedName),
            );
            await Future.delayed(Duration.zero);

            verifyNever(() => mockNearbyPort.requestConnection(endpointId));
          },
        );
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

    group('error stream', () {
      test('exposes errors stream', () {
        expect(service.errors, isA<Stream<ConnectionError>>());
      });

      test(
        'emits ConnectionNotFoundError when sending to unknown peer',
        () async {
          final unknownNodeId = NodeId('unknown-peer');
          final payload = Uint8List.fromList([1, 2, 3]);

          final errors = <ConnectionError>[];
          service.errors.listen(errors.add);

          await service.sendGossipMessage(unknownNodeId, payload);
          await Future.delayed(Duration.zero);

          expect(errors, hasLength(1));
          expect(errors.first, isA<ConnectionNotFoundError>());
          final error = errors.first as ConnectionNotFoundError;
          expect(error.nodeId, equals(unknownNodeId));
          expect(error.type, equals(ConnectionErrorType.connectionNotFound));
          expect(error.occurredAt, isNotNull);
        },
      );

      test('emits SendFailedError when sendPayload throws', () async {
        final endpointId = EndpointId('remote-ep');
        final remoteNodeId = NodeId('remote-node-456');
        final payload = Uint8List.fromList([1, 2, 3]);

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

        // Make sendPayload throw
        when(
          () => mockNearbyPort.sendPayload(any(), any()),
        ).thenThrow(Exception('Network error'));

        final errors = <ConnectionError>[];
        service.errors.listen(errors.add);

        // The error is now propagated to the caller
        await expectLater(
          service.sendGossipMessage(remoteNodeId, payload),
          throwsA(isA<Exception>()),
        );
        await Future.delayed(Duration.zero);

        expect(errors, hasLength(1));
        expect(errors.first, isA<SendFailedError>());
        final error = errors.first as SendFailedError;
        expect(error.nodeId, equals(remoteNodeId));
        expect(error.type, equals(ConnectionErrorType.sendFailed));
        expect(error.cause, isA<Exception>());
      });

      test(
        'emits HandshakeInvalidError when handshake decoding fails',
        () async {
          final endpointId = EndpointId('remote-ep');

          // Establish connection
          nearbyEventController.add(ConnectionEstablished(id: endpointId));
          await Future.delayed(Duration.zero);

          final errors = <ConnectionError>[];
          service.errors.listen(errors.add);

          // Send invalid handshake (wrong format)
          final invalidHandshake = Uint8List.fromList([0x01, 0, 0]);
          nearbyEventController.add(
            PayloadReceived(id: endpointId, bytes: invalidHandshake),
          );
          await Future.delayed(Duration.zero);

          expect(errors, hasLength(1));
          expect(errors.first, isA<HandshakeInvalidError>());
          final error = errors.first as HandshakeInvalidError;
          expect(error.endpointId, equals(endpointId));
          expect(error.type, equals(ConnectionErrorType.handshakeInvalid));
        },
      );
    });

    group('priority queues', () {
      test('processes high-priority messages before normal-priority', () async {
        final endpointId = EndpointId('remote-ep');
        final remoteNodeId = NodeId('remote-node-456');

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

        // Track the order of messages sent
        final sentPayloads = <Uint8List>[];
        var sendCount = 0;
        final firstSendStarted = Completer<void>();
        final releaseFirstSend = Completer<void>();

        when(() => mockNearbyPort.sendPayload(any(), any())).thenAnswer((
          invocation,
        ) async {
          sendCount++;
          final payload = invocation.positionalArguments[1] as Uint8List;
          if (sendCount == 1) {
            // Signal that first send started, then wait
            firstSendStarted.complete();
            await releaseFirstSend.future;
          }
          sentPayloads.add(payload);
        });

        final normalPayload1 = Uint8List.fromList([1, 1, 1]);
        final normalPayload2 = Uint8List.fromList([3, 3, 3]);
        final highPayload = Uint8List.fromList([2, 2, 2]);

        // Queue first normal priority (it will start sending but block)
        final normalFuture1 = service.sendGossipMessage(
          remoteNodeId,
          normalPayload1,
          priority: MessagePriority.normal,
        );

        // Wait for first send to start (blocking in sendPayload)
        await firstSendStarted.future;

        // Now queue more messages while first is blocked
        // High priority should jump ahead of second normal
        final normalFuture2 = service.sendGossipMessage(
          remoteNodeId,
          normalPayload2,
          priority: MessagePriority.normal,
        );
        final highFuture = service.sendGossipMessage(
          remoteNodeId,
          highPayload,
          priority: MessagePriority.high,
        );

        // Release the first send
        releaseFirstSend.complete();

        await Future.wait([normalFuture1, normalFuture2, highFuture]);

        // Order should be: normal1 (already sending), high (jumped queue), normal2
        expect(sentPayloads, hasLength(3));
        expect(sentPayloads[0].sublist(1), equals(normalPayload1));
        expect(sentPayloads[1].sublist(1), equals(highPayload));
        expect(sentPayloads[2].sublist(1), equals(normalPayload2));
      });

      test('totalPendingSendCount returns correct count', () async {
        final endpointId = EndpointId('remote-ep');
        final remoteNodeId = NodeId('remote-node-456');

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

        // Initially no pending messages
        expect(service.totalPendingSendCount, equals(0));

        // Make sendPayload hang to allow queue buildup
        final sendCompleter = Completer<void>();
        when(
          () => mockNearbyPort.sendPayload(any(), any()),
        ).thenAnswer((_) => sendCompleter.future);

        // Queue messages without awaiting
        unawaited(
          service.sendGossipMessage(
            remoteNodeId,
            Uint8List.fromList([1]),
            priority: MessagePriority.high,
          ),
        );
        unawaited(
          service.sendGossipMessage(
            remoteNodeId,
            Uint8List.fromList([2]),
            priority: MessagePriority.normal,
          ),
        );

        // Allow microtasks to run
        await Future.delayed(Duration.zero);

        // One is being processed, one is still in queue
        // (first message is being sent, second is pending)
        expect(service.totalPendingSendCount, equals(1));

        // Complete sending
        sendCompleter.complete();
        await Future.delayed(Duration.zero);

        expect(service.totalPendingSendCount, equals(0));
      });

      test('pendingSendCount returns count for specific peer', () async {
        final endpointId = EndpointId('remote-ep');
        final remoteNodeId = NodeId('remote-node-456');
        final unknownNodeId = NodeId('unknown-node');

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

        // Initially no pending messages
        expect(service.pendingSendCount(remoteNodeId), equals(0));
        expect(service.pendingSendCount(unknownNodeId), equals(0));

        // Make sendPayload hang
        final sendCompleter = Completer<void>();
        when(
          () => mockNearbyPort.sendPayload(any(), any()),
        ).thenAnswer((_) => sendCompleter.future);

        // Queue a message
        unawaited(
          service.sendGossipMessage(remoteNodeId, Uint8List.fromList([1])),
        );
        unawaited(
          service.sendGossipMessage(remoteNodeId, Uint8List.fromList([2])),
        );

        await Future.delayed(Duration.zero);

        // One pending for known peer, zero for unknown
        expect(service.pendingSendCount(remoteNodeId), equals(1));
        expect(service.pendingSendCount(unknownNodeId), equals(0));

        // Complete
        sendCompleter.complete();
        await Future.delayed(Duration.zero);

        expect(service.pendingSendCount(remoteNodeId), equals(0));
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
