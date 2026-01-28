import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_nearby/src/application/services/connection_service.dart';
import 'package:gossip_nearby/src/domain/events/connection_event.dart';
import 'package:gossip_nearby/src/infrastructure/ports/nearby_message_port.dart';
import 'package:mocktail/mocktail.dart';

class MockConnectionService extends Mock implements ConnectionService {}

void main() {
  setUpAll(() {
    registerFallbackValue(NodeId('fallback'));
    registerFallbackValue(Uint8List(0));
  });

  group('NearbyMessagePort', () {
    late NearbyMessagePort messagePort;
    late MockConnectionService mockConnectionService;
    late StreamController<ConnectionEvent> eventController;

    setUp(() {
      mockConnectionService = MockConnectionService();
      eventController = StreamController<ConnectionEvent>.broadcast();

      when(
        () => mockConnectionService.events,
      ).thenAnswer((_) => eventController.stream);
      when(
        () => mockConnectionService.sendGossipMessage(any(), any()),
      ).thenAnswer((_) async {});

      messagePort = NearbyMessagePort(mockConnectionService);
    });

    tearDown(() async {
      await eventController.close();
      await messagePort.close();
    });

    group('send', () {
      test('delegates to ConnectionService.sendGossipMessage', () async {
        final destination = NodeId('dest-node');
        final bytes = Uint8List.fromList([1, 2, 3, 4]);

        await messagePort.send(destination, bytes);

        verify(
          () => mockConnectionService.sendGossipMessage(destination, bytes),
        ).called(1);
      });
    });

    group('incoming', () {
      test('emits IncomingMessage when gossip message received', () async {
        final sender = NodeId('sender-node');
        final bytes = Uint8List.fromList([1, 2, 3, 4]);

        // Set up callback capture
        GossipMessageCallback? capturedCallback;
        when(() => mockConnectionService.onGossipMessage = any()).thenAnswer((
          invocation,
        ) {
          capturedCallback =
              invocation.positionalArguments[0] as GossipMessageCallback?;
          return null;
        });

        // Re-create to capture callback
        messagePort = NearbyMessagePort(mockConnectionService);

        final messages = <IncomingMessage>[];
        messagePort.incoming.listen(messages.add);

        // Simulate receiving a message
        capturedCallback?.call(sender, bytes);

        await Future.delayed(Duration.zero);

        expect(messages, hasLength(1));
        expect(messages.first.sender, equals(sender));
        expect(messages.first.bytes, equals(bytes));
      });
    });

    group('close', () {
      test('can be called multiple times without error', () async {
        await messagePort.close();
        await messagePort.close();
        // No exception = pass
      });
    });
  });
}
