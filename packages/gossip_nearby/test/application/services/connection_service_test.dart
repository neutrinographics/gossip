import 'dart:async';
import 'dart:math' show Random;
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
      test('forwards gossip messages via incomingMessages stream', () async {
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
        final messages = <IncomingMessage>[];
        service.incomingMessages.listen(messages.add);

        // Send gossip message
        nearbyEventController.add(
          PayloadReceived(id: endpointId, bytes: gossipPayload),
        );
        await Future.delayed(Duration.zero);

        expect(messages, hasLength(1));
        expect(messages.first.sender, equals(remoteNodeId));
        expect(messages.first.bytes, equals(Uint8List.fromList([1, 2, 3, 4])));
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

      test('emits SendFailedError when a payload transfer to a connected peer '
          'fails', () async {
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

        final errors = <ConnectionError>[];
        service.errors.listen(errors.add);

        nearbyEventController.add(
          PayloadTransferFailed(id: endpointId, payloadId: 7),
        );
        await Future.delayed(Duration.zero);

        expect(errors, hasLength(1));
        final error = errors.first as SendFailedError;
        expect(error.nodeId, equals(remoteNodeId));
        expect(error.type, equals(ConnectionErrorType.sendFailed));
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

    group('connection retry', () {
      late MockNearbyPort retryMockPort;
      late ConnectionRegistry retryRegistry;
      late StreamController<NearbyEvent> retryController;
      late InMemoryTimePort timePort;

      setUp(() {
        retryMockPort = MockNearbyPort();
        retryRegistry = ConnectionRegistry();
        retryController = StreamController<NearbyEvent>.broadcast();
        timePort = InMemoryTimePort();

        when(
          () => retryMockPort.events,
        ).thenAnswer((_) => retryController.stream);
        when(
          () => retryMockPort.requestConnection(any()),
        ).thenAnswer((_) async {});
        when(
          () => retryMockPort.sendPayload(any(), any()),
        ).thenAnswer((_) async {});
        when(() => retryMockPort.disconnect(any())).thenAnswer((_) async {});
      });

      tearDown(() async {
        await retryController.close();
      });

      ConnectionService createRetryService({required NodeId localNodeId}) {
        return ConnectionService(
          localNodeId: localNodeId,
          nearbyPort: retryMockPort,
          registry: retryRegistry,
          timePort: timePort,
          connectionTimeout: const Duration(seconds: 5),
          random: Random(42),
        );
      }

      test('passive side retries after connectionTimeout', () async {
        // Local has larger nodeId → passive side
        final svc = createRetryService(localNodeId: NodeId('zzz'));

        retryController.add(
          EndpointDiscovered(id: EndpointId('ep1'), displayName: 'aaa|Device'),
        );
        await Future.delayed(Duration.zero);

        // Passive side should NOT initiate immediately
        verifyNever(() => retryMockPort.requestConnection(EndpointId('ep1')));

        // Advance past max jittered timeout (6.5s) → retry should fire
        await timePort.advance(const Duration(seconds: 7));

        verify(
          () => retryMockPort.requestConnection(EndpointId('ep1')),
        ).called(1);

        await svc.dispose();
      });

      test('active side retries after connectionTimeout', () async {
        // Local has smaller nodeId → active side
        final svc = createRetryService(localNodeId: NodeId('aaa'));

        retryController.add(
          EndpointDiscovered(id: EndpointId('ep1'), displayName: 'zzz|Device'),
        );
        await Future.delayed(Duration.zero);

        // Active side initiates immediately
        verify(
          () => retryMockPort.requestConnection(EndpointId('ep1')),
        ).called(1);

        // Advance past max jittered timeout (6.5s) → retry fires again
        await timePort.advance(const Duration(seconds: 7));

        verify(
          () => retryMockPort.requestConnection(EndpointId('ep1')),
        ).called(1);

        await svc.dispose();
      });

      test('successful connection stops retry', () async {
        final svc = createRetryService(localNodeId: NodeId('zzz'));

        retryController.add(
          EndpointDiscovered(id: EndpointId('ep1'), displayName: 'aaa|Device'),
        );
        await Future.delayed(Duration.zero);

        // Connection established → removes from pending
        retryController.add(ConnectionEstablished(id: EndpointId('ep1')));
        await Future.delayed(Duration.zero);

        // Advance well past timeout
        await timePort.advance(const Duration(seconds: 10));

        // Should never have called requestConnection (passive + connected)
        verifyNever(() => retryMockPort.requestConnection(EndpointId('ep1')));

        await svc.dispose();
      });

      test('EndpointLost stops retry', () async {
        final svc = createRetryService(localNodeId: NodeId('zzz'));

        retryController.add(
          EndpointDiscovered(id: EndpointId('ep1'), displayName: 'aaa|Device'),
        );
        await Future.delayed(Duration.zero);

        // Endpoint lost → removes from pending
        retryController.add(EndpointLost(id: EndpointId('ep1')));
        await Future.delayed(Duration.zero);

        // Advance well past timeout
        await timePort.advance(const Duration(seconds: 10));

        verifyNever(() => retryMockPort.requestConnection(EndpointId('ep1')));

        await svc.dispose();
      });

      test('ConnectionFailed keeps endpoint pending for retry', () async {
        // Active side so we get an immediate attempt
        final svc = createRetryService(localNodeId: NodeId('aaa'));

        retryController.add(
          EndpointDiscovered(id: EndpointId('ep1'), displayName: 'zzz|Device'),
        );
        await Future.delayed(Duration.zero);

        // Immediate attempt
        verify(
          () => retryMockPort.requestConnection(EndpointId('ep1')),
        ).called(1);

        // Connection failed — endpoint stays in pending
        retryController.add(ConnectionFailed(id: EndpointId('ep1')));
        await Future.delayed(Duration.zero);

        // Advance past max jittered timeout → retry fires
        await timePort.advance(const Duration(seconds: 7));

        verify(
          () => retryMockPort.requestConnection(EndpointId('ep1')),
        ).called(1);

        await svc.dispose();
      });

      test('requestConnection exception does not crash', () async {
        when(
          () => retryMockPort.requestConnection(any()),
        ).thenAnswer((_) => Future.error(Exception('platform error')));

        // Active side triggers immediate attempt which throws
        final svc = createRetryService(localNodeId: NodeId('aaa'));

        retryController.add(
          EndpointDiscovered(id: EndpointId('ep1'), displayName: 'zzz|Device'),
        );
        await Future.delayed(Duration.zero);

        // Should not crash — error is caught
        verify(
          () => retryMockPort.requestConnection(EndpointId('ep1')),
        ).called(1);

        // Retry after jittered timeout also throws — still no crash
        await timePort.advance(const Duration(seconds: 7));

        verify(
          () => retryMockPort.requestConnection(EndpointId('ep1')),
        ).called(1);

        await svc.dispose();
      });

      test('duplicate NodeId disconnects old endpoint', () async {
        final svc = createRetryService(localNodeId: NodeId('aaa'));

        // First connection via ep1
        retryController.add(ConnectionEstablished(id: EndpointId('ep1')));
        await Future.delayed(Duration.zero);
        retryController.add(
          PayloadReceived(
            id: EndpointId('ep1'),
            bytes: _encodeHandshake(NodeId('remote')),
          ),
        );
        await Future.delayed(Duration.zero);

        // Second connection via ep2 with same NodeId
        retryController.add(ConnectionEstablished(id: EndpointId('ep2')));
        await Future.delayed(Duration.zero);
        retryController.add(
          PayloadReceived(
            id: EndpointId('ep2'),
            bytes: _encodeHandshake(NodeId('remote')),
          ),
        );
        await Future.delayed(Duration.zero);

        // Old endpoint should be disconnected
        verify(() => retryMockPort.disconnect(EndpointId('ep1'))).called(1);

        await svc.dispose();
      });

      test('does not retry for own advertisement', () async {
        final svc = createRetryService(localNodeId: NodeId('local-node'));

        // Discover own nodeId
        retryController.add(
          EndpointDiscovered(
            id: EndpointId('ep1'),
            displayName: 'local-node|My Device',
          ),
        );
        await Future.delayed(Duration.zero);

        // Advance well past timeout
        await timePort.advance(const Duration(seconds: 10));

        verifyNever(() => retryMockPort.requestConnection(any()));

        await svc.dispose();
      });

      test('retry intervals are jittered (not fixed)', () async {
        final svc = createRetryService(localNodeId: NodeId('zzz'));

        retryController.add(
          EndpointDiscovered(id: EndpointId('ep1'), displayName: 'aaa|Device'),
        );
        await Future.delayed(Duration.zero);

        // Advance to just before minimum jitter (3.5s) — no retry yet
        await timePort.advance(const Duration(milliseconds: 3400));
        verifyNever(() => retryMockPort.requestConnection(EndpointId('ep1')));

        // Advance past maximum jitter (6.5s total) — retry must have fired
        await timePort.advance(const Duration(milliseconds: 3200));
        verify(
          () => retryMockPort.requestConnection(EndpointId('ep1')),
        ).called(1);

        await svc.dispose();
      });

      test('does not retry when already connected to NodeId', () async {
        final svc = createRetryService(localNodeId: NodeId('aaa'));

        // Complete handshake with remote
        retryController.add(ConnectionEstablished(id: EndpointId('ep1')));
        await Future.delayed(Duration.zero);
        retryController.add(
          PayloadReceived(
            id: EndpointId('ep1'),
            bytes: _encodeHandshake(NodeId('remote')),
          ),
        );
        await Future.delayed(Duration.zero);

        clearInteractions(retryMockPort);

        // Discover same NodeId via new endpoint
        retryController.add(
          EndpointDiscovered(
            id: EndpointId('ep2'),
            displayName: 'remote|Device',
          ),
        );
        await Future.delayed(Duration.zero);

        // Advance well past timeout
        await timePort.advance(const Duration(seconds: 10));

        // Should never request connection for ep2
        verifyNever(() => retryMockPort.requestConnection(EndpointId('ep2')));

        await svc.dispose();
      });
    });

    group('dispose', () {
      final endpointId = EndpointId('remote-ep');
      final remoteNodeId = NodeId('remote-node-456');

      /// Establishes a connection and completes the handshake so sends
      /// can be routed to [remoteNodeId].
      Future<void> completeHandshake() async {
        nearbyEventController.add(ConnectionEstablished(id: endpointId));
        await Future.delayed(Duration.zero);
        nearbyEventController.add(
          PayloadReceived(
            id: endpointId,
            bytes: _encodeHandshake(remoteNodeId),
          ),
        );
        await Future.delayed(Duration.zero);
      }

      test('completes queued sends with an error instead of hanging', () async {
        await completeHandshake();

        // Gate the port so the first send stays in flight and the second
        // stays queued.
        final sendGate = Completer<void>();
        when(
          () => mockNearbyPort.sendPayload(any(), any()),
        ).thenAnswer((_) => sendGate.future);

        final inFlight = service.sendGossipMessage(
          remoteNodeId,
          Uint8List.fromList([1]),
        );
        final queued = service.sendGossipMessage(
          remoteNodeId,
          Uint8List.fromList([2]),
        );
        await Future.delayed(Duration.zero);

        final inFlightExpectation = expectLater(
          inFlight,
          throwsA(isA<Exception>()),
        );
        final queuedExpectation = expectLater(
          queued,
          throwsA(isA<StateError>()),
        );

        await service.dispose();

        // The in-flight send fails after dispose; its awaiter must still
        // be completed instead of the error being thrown into a closed
        // controller.
        sendGate.completeError(Exception('link died'));

        await inFlightExpectation;
        await queuedExpectation;
      });

      test(
        'send after dispose completes with an error without touching the port',
        () async {
          await completeHandshake();
          clearInteractions(mockNearbyPort);

          await service.dispose();

          await expectLater(
            service.sendGossipMessage(remoteNodeId, Uint8List.fromList([1])),
            throwsA(isA<StateError>()),
          );
          verifyNever(() => mockNearbyPort.sendPayload(any(), any()));
        },
      );
    });

    group('handshake timeout', () {
      late MockNearbyPort timeoutMockPort;
      late ConnectionRegistry timeoutRegistry;
      late StreamController<NearbyEvent> timeoutController;
      late InMemoryTimePort timePort;

      setUp(() {
        timeoutMockPort = MockNearbyPort();
        timeoutRegistry = ConnectionRegistry();
        timeoutController = StreamController<NearbyEvent>.broadcast();
        timePort = InMemoryTimePort();

        when(
          () => timeoutMockPort.events,
        ).thenAnswer((_) => timeoutController.stream);
        when(
          () => timeoutMockPort.requestConnection(any()),
        ).thenAnswer((_) async {});
        when(
          () => timeoutMockPort.sendPayload(any(), any()),
        ).thenAnswer((_) async {});
        when(() => timeoutMockPort.disconnect(any())).thenAnswer((_) async {});
      });

      tearDown(() async {
        await timeoutController.close();
      });

      ConnectionService createTimeoutService({int? maxConnections}) {
        return ConnectionService(
          localNodeId: NodeId('aaa'),
          nearbyPort: timeoutMockPort,
          registry: timeoutRegistry,
          timePort: timePort,
          connectionTimeout: const Duration(seconds: 5),
          random: Random(42),
          maxConnections: maxConnections,
        );
      }

      test(
        'cancels pending handshake when endpoint disconnects mid-handshake',
        () async {
          final svc = createTimeoutService();

          timeoutController.add(ConnectionEstablished(id: EndpointId('ep1')));
          await Future.delayed(Duration.zero);
          expect(timeoutRegistry.pendingHandshakeCount, equals(1));

          timeoutController.add(Disconnected(id: EndpointId('ep1')));
          await Future.delayed(Duration.zero);

          expect(timeoutRegistry.pendingHandshakeCount, equals(0));

          await svc.dispose();
        },
      );

      test('cancels pending handshake when handshake decode fails', () async {
        final svc = createTimeoutService();

        timeoutController.add(ConnectionEstablished(id: EndpointId('ep1')));
        await Future.delayed(Duration.zero);
        expect(timeoutRegistry.pendingHandshakeCount, equals(1));

        // Malformed handshake payload (declared length exceeds bytes)
        timeoutController.add(
          PayloadReceived(
            id: EndpointId('ep1'),
            bytes: Uint8List.fromList([0x01, 0, 0]),
          ),
        );
        await Future.delayed(Duration.zero);

        expect(timeoutRegistry.pendingHandshakeCount, equals(0));

        await svc.dispose();
      });

      test('sweeps handshake pending longer than timeout and emits '
          'HandshakeFailed', () async {
        final svc = createTimeoutService();
        final events = <ConnectionEvent>[];
        svc.events.listen(events.add);

        timeoutController.add(ConnectionEstablished(id: EndpointId('ep1')));
        await Future.delayed(Duration.zero);
        expect(timeoutRegistry.pendingHandshakeCount, equals(1));

        // First retry tick at ~7s: handshake age below the 10s timeout,
        // must not be swept yet.
        await timePort.advance(const Duration(seconds: 7));
        expect(timeoutRegistry.pendingHandshakeCount, equals(1));

        // Second tick at ~14s: age exceeds the timeout — swept.
        await timePort.advance(const Duration(seconds: 7));

        expect(timeoutRegistry.pendingHandshakeCount, equals(0));
        expect(events.whereType<HandshakeFailed>(), hasLength(1));
        expect(svc.metrics.pendingHandshakeCount, equals(0));
        verify(() => timeoutMockPort.disconnect(EndpointId('ep1'))).called(1);

        await svc.dispose();
      });

      test(
        'swept handshake frees a connection-limit slot for the next peer',
        () async {
          final svc = createTimeoutService(maxConnections: 1);

          // Handshake starts but the peer never responds — slot consumed.
          timeoutController.add(ConnectionEstablished(id: EndpointId('ep1')));
          await Future.delayed(Duration.zero);
          expect(timeoutRegistry.pendingHandshakeCount, equals(1));

          // Sweep the stale handshake.
          await timePort.advance(const Duration(seconds: 7));
          await timePort.advance(const Duration(seconds: 7));
          expect(timeoutRegistry.pendingHandshakeCount, equals(0));

          clearInteractions(timeoutMockPort);

          // A new inbound connection must proceed to handshake instead of
          // being rejected against the leaked slot.
          timeoutController.add(ConnectionEstablished(id: EndpointId('ep2')));
          await Future.delayed(Duration.zero);

          verify(
            () => timeoutMockPort.sendPayload(EndpointId('ep2'), any()),
          ).called(1);
          verifyNever(() => timeoutMockPort.disconnect(EndpointId('ep2')));

          await svc.dispose();
        },
      );
    });

    group('connection limit', () {
      late MockNearbyPort limitMockPort;
      late ConnectionRegistry limitRegistry;
      late StreamController<NearbyEvent> limitController;
      late InMemoryTimePort timePort;

      setUp(() {
        limitMockPort = MockNearbyPort();
        limitRegistry = ConnectionRegistry();
        limitController = StreamController<NearbyEvent>.broadcast();
        timePort = InMemoryTimePort();

        when(
          () => limitMockPort.events,
        ).thenAnswer((_) => limitController.stream);
        when(
          () => limitMockPort.requestConnection(any()),
        ).thenAnswer((_) async {});
        when(
          () => limitMockPort.sendPayload(any(), any()),
        ).thenAnswer((_) async {});
        when(() => limitMockPort.disconnect(any())).thenAnswer((_) async {});
      });

      tearDown(() async {
        await limitController.close();
      });

      ConnectionService createLimitedService({
        required NodeId localNodeId,
        int? maxConnections,
      }) {
        return ConnectionService(
          localNodeId: localNodeId,
          nearbyPort: limitMockPort,
          registry: limitRegistry,
          timePort: timePort,
          maxConnections: maxConnections,
          random: Random(42),
        );
      }

      /// Completes a full connection lifecycle for a peer.
      Future<void> connectPeer(
        StreamController<NearbyEvent> controller,
        EndpointId endpointId,
        NodeId remoteNodeId,
      ) async {
        controller.add(ConnectionEstablished(id: endpointId));
        await Future.delayed(Duration.zero);
        controller.add(
          PayloadReceived(
            id: endpointId,
            bytes: _encodeHandshake(remoteNodeId),
          ),
        );
        await Future.delayed(Duration.zero);
      }

      test(
        'does not initiate outbound connection when at connection limit',
        () async {
          // Active side (smaller nodeId initiates)
          final svc = createLimitedService(
            localNodeId: NodeId('aaa'),
            maxConnections: 1,
          );

          // Fill up the connection limit
          await connectPeer(
            limitController,
            EndpointId('ep1'),
            NodeId('peer-1'),
          );
          expect(limitRegistry.connectionCount, equals(1));

          clearInteractions(limitMockPort);

          // Discover another peer — should NOT initiate connection
          limitController.add(
            EndpointDiscovered(
              id: EndpointId('ep2'),
              displayName: 'zzz|Device',
            ),
          );
          await Future.delayed(Duration.zero);

          verifyNever(() => limitMockPort.requestConnection(EndpointId('ep2')));

          await svc.dispose();
        },
      );

      test(
        'immediately disconnects inbound connection when at limit',
        () async {
          final svc = createLimitedService(
            localNodeId: NodeId('aaa'),
            maxConnections: 1,
          );

          // Fill up the connection limit
          await connectPeer(
            limitController,
            EndpointId('ep1'),
            NodeId('peer-1'),
          );

          clearInteractions(limitMockPort);

          // Inbound connection established (platform auto-accepted)
          limitController.add(ConnectionEstablished(id: EndpointId('ep2')));
          await Future.delayed(Duration.zero);

          // Should disconnect immediately without sending handshake
          verify(() => limitMockPort.disconnect(EndpointId('ep2'))).called(1);
          verifyNever(
            () => limitMockPort.sendPayload(EndpointId('ep2'), any()),
          );
          expect(limitRegistry.hasPendingHandshake(EndpointId('ep2')), isFalse);

          await svc.dispose();
        },
      );

      test(
        'emits ConnectionLimitReachedError when rejecting inbound connection',
        () async {
          final svc = createLimitedService(
            localNodeId: NodeId('aaa'),
            maxConnections: 1,
          );

          await connectPeer(
            limitController,
            EndpointId('ep1'),
            NodeId('peer-1'),
          );

          final errors = <ConnectionError>[];
          svc.errors.listen(errors.add);

          limitController.add(ConnectionEstablished(id: EndpointId('ep2')));
          await Future.delayed(Duration.zero);

          expect(errors, hasLength(1));
          expect(errors.first, isA<ConnectionLimitReachedError>());
          final error = errors.first as ConnectionLimitReachedError;
          expect(error.endpointId, equals(EndpointId('ep2')));
          expect(
            error.type,
            equals(ConnectionErrorType.connectionLimitReached),
          );

          await svc.dispose();
        },
      );

      test(
        'resumes initiating connections after dropping below limit',
        () async {
          final svc = createLimitedService(
            localNodeId: NodeId('aaa'),
            maxConnections: 1,
          );

          // Fill up the connection limit
          await connectPeer(
            limitController,
            EndpointId('ep1'),
            NodeId('peer-1'),
          );

          // Discover another peer while at limit — tracked but not initiated
          limitController.add(
            EndpointDiscovered(
              id: EndpointId('ep2'),
              displayName: 'zzz|Device',
            ),
          );
          await Future.delayed(Duration.zero);

          clearInteractions(limitMockPort);

          // Disconnect the existing peer — now below limit
          limitController.add(Disconnected(id: EndpointId('ep1')));
          await Future.delayed(Duration.zero);

          // Advance past retry timeout — should now initiate connection
          await timePort.advance(const Duration(seconds: 7));

          verify(
            () => limitMockPort.requestConnection(EndpointId('ep2')),
          ).called(1);

          await svc.dispose();
        },
      );

      test('pending handshakes count toward connection limit', () async {
        final svc = createLimitedService(
          localNodeId: NodeId('aaa'),
          maxConnections: 1,
        );

        // Connection established but handshake not yet completed
        limitController.add(ConnectionEstablished(id: EndpointId('ep1')));
        await Future.delayed(Duration.zero);
        expect(limitRegistry.pendingHandshakeCount, equals(1));

        clearInteractions(limitMockPort);

        // Another inbound connection — should be rejected
        limitController.add(ConnectionEstablished(id: EndpointId('ep2')));
        await Future.delayed(Duration.zero);

        verify(() => limitMockPort.disconnect(EndpointId('ep2'))).called(1);

        await svc.dispose();
      });

      test('no limit when maxConnections is null', () async {
        final svc = createLimitedService(
          localNodeId: NodeId('aaa'),
          maxConnections: null,
        );

        // Connect several peers
        await connectPeer(limitController, EndpointId('ep1'), NodeId('peer-1'));
        await connectPeer(limitController, EndpointId('ep2'), NodeId('peer-2'));
        await connectPeer(limitController, EndpointId('ep3'), NodeId('peer-3'));

        expect(limitRegistry.connectionCount, equals(3));

        // Another inbound connection — should be accepted (handshake sent)
        limitController.add(ConnectionEstablished(id: EndpointId('ep4')));
        await Future.delayed(Duration.zero);

        verify(
          () => limitMockPort.sendPayload(EndpointId('ep4'), any()),
        ).called(1);
        verifyNever(() => limitMockPort.disconnect(EndpointId('ep4')));

        await svc.dispose();
      });

      test('does not skip retries when below limit', () async {
        final svc = createLimitedService(
          localNodeId: NodeId('zzz'),
          maxConnections: 2,
        );

        // One connection active, limit is 2
        await connectPeer(limitController, EndpointId('ep1'), NodeId('peer-1'));

        // Discover another peer (passive side)
        limitController.add(
          EndpointDiscovered(id: EndpointId('ep2'), displayName: 'aaa|Device'),
        );
        await Future.delayed(Duration.zero);

        // Advance past retry timeout — should retry since below limit
        await timePort.advance(const Duration(seconds: 7));

        verify(
          () => limitMockPort.requestConnection(EndpointId('ep2')),
        ).called(1);

        await svc.dispose();
      });

      test('skips retries when at connection limit', () async {
        final svc = createLimitedService(
          localNodeId: NodeId('zzz'),
          maxConnections: 1,
        );

        // Fill up the connection limit
        await connectPeer(limitController, EndpointId('ep1'), NodeId('peer-1'));

        // Discover another peer (passive side)
        limitController.add(
          EndpointDiscovered(id: EndpointId('ep2'), displayName: 'aaa|Device'),
        );
        await Future.delayed(Duration.zero);

        clearInteractions(limitMockPort);

        // Advance past retry timeout — should NOT retry
        await timePort.advance(const Duration(seconds: 7));

        verifyNever(() => limitMockPort.requestConnection(EndpointId('ep2')));

        await svc.dispose();
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
