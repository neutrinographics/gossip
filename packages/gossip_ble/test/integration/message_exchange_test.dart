import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'test_harness.dart';

void main() {
  group('Message Exchange Integration Tests', () {
    late BleTestHarness harness;

    setUp(() {
      harness = BleTestHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('message sent via messagePort is received by peer', () async {
      final [alice, bob] = harness.createDevices(['alice', 'bob']);

      await alice.connectTo(bob);

      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      await alice.sendTo(bob, payload);

      bob.expectReceivedMessage(from: alice, bytes: payload);
    });

    test('bidirectional message exchange works', () async {
      final [alice, bob] = harness.createDevices(['alice', 'bob']);

      await alice.connectTo(bob);

      final payloadAliceToBob = Uint8List.fromList([1, 2, 3]);
      final payloadBobToAlice = Uint8List.fromList([4, 5, 6]);

      await alice.sendTo(bob, payloadAliceToBob);
      await bob.sendTo(alice, payloadBobToAlice);

      alice.expectReceivedMessage(from: bob, bytes: payloadBobToAlice);
      bob.expectReceivedMessage(from: alice, bytes: payloadAliceToBob);
    });

    test('multiple messages maintain order', () async {
      final [alice, bob] = harness.createDevices(['alice', 'bob']);

      await alice.connectTo(bob);

      // Send multiple messages
      for (var i = 0; i < 10; i++) {
        await alice.sendTo(bob, Uint8List.fromList([i]));
      }

      await harness.advance();

      expect(bob.receivedMessages, hasLength(10));
      for (var i = 0; i < 10; i++) {
        expect(bob.receivedMessages[i].bytes, Uint8List.fromList([i]));
      }
    });

    test('large messages are transmitted correctly', () async {
      final [alice, bob] = harness.createDevices(['alice', 'bob']);

      await alice.connectTo(bob);

      // Create a large payload (simulating a gossip sync)
      final largePayload = Uint8List.fromList(
        List.generate(10000, (i) => i % 256),
      );

      await alice.sendTo(bob, largePayload);

      bob.expectReceivedMessage(from: alice, bytes: largePayload);
    });

    test('messages to unknown peer are silently dropped', () async {
      final [alice, bob, unknown] = harness.createDevices([
        'alice',
        'bob',
        'unknown',
      ]);

      await alice.connectTo(bob);
      // Note: alice is NOT connected to unknown

      // Should not throw
      await alice.sendTo(unknown, Uint8List.fromList([1, 2, 3]));

      // Verify no side effects
      alice.expectPeerCount(1);
    });

    test('metrics track bytes sent and received', () async {
      final [alice, bob] = harness.createDevices(['alice', 'bob']);

      await alice.connectTo(bob);

      // Record baseline after handshake
      final baselineSentA = alice.transport.metrics.totalMessagesSent;
      final baselineReceivedA = alice.transport.metrics.totalMessagesReceived;
      final baselineSentB = bob.transport.metrics.totalMessagesSent;
      final baselineReceivedB = bob.transport.metrics.totalMessagesReceived;

      final payload1 = Uint8List.fromList([1, 2, 3, 4, 5]); // 5 bytes
      final payload2 = Uint8List.fromList([10, 20, 30]); // 3 bytes

      await alice.sendTo(bob, payload1);
      await bob.sendTo(alice, payload2);

      await harness.advance();

      // Alice sent payload1, received payload2
      // Note: bytes include protocol wrapper, so they'll be slightly larger
      expect(alice.transport.metrics.totalMessagesSent - baselineSentA, 1);
      expect(
        alice.transport.metrics.totalMessagesReceived - baselineReceivedA,
        1,
      );
      expect(alice.transport.metrics.totalBytesSent, greaterThan(5));
      expect(alice.transport.metrics.totalBytesReceived, greaterThan(3));

      // Bob sent payload2, received payload1
      expect(bob.transport.metrics.totalMessagesSent - baselineSentB, 1);
      expect(
        bob.transport.metrics.totalMessagesReceived - baselineReceivedB,
        1,
      );
    });

    test('rapid message exchange works correctly', () async {
      final [alice, bob] = harness.createDevices(['alice', 'bob']);

      await alice.connectTo(bob);

      // Send multiple messages rapidly
      await alice.sendTo(bob, [1, 2, 3]);
      await alice.sendTo(bob, [4, 5, 6]);
      await alice.sendTo(bob, [7, 8, 9]);

      expect(bob.receivedMessages, hasLength(3));
    });

    group('multi-peer message routing', () {
      test('messages are routed to correct peer', () async {
        final [alice, bob, charlie] = harness.createDevices([
          'alice',
          'bob',
          'charlie',
        ]);

        // Alice connects to both Bob and Charlie
        await alice.connectToAll([bob, charlie]);

        // Send different messages to each peer
        await alice.sendTo(bob, Uint8List.fromList([1, 1, 1]));
        await alice.sendTo(charlie, Uint8List.fromList([2, 2, 2]));

        bob.expectReceivedMessage(
          from: alice,
          bytes: Uint8List.fromList([1, 1, 1]),
        );
        charlie.expectReceivedMessage(
          from: alice,
          bytes: Uint8List.fromList([2, 2, 2]),
        );
      });

      test('broadcast to all peers', () async {
        final [alice, bob, charlie] = harness.createDevices([
          'alice',
          'bob',
          'charlie',
        ]);

        await alice.connectToAll([bob, charlie]);

        final payload = Uint8List.fromList([42, 42, 42]);

        // Send to all connected peers
        for (final peer in alice.transport.connectedPeers) {
          await alice.transport.messagePort.send(peer, payload);
        }

        await harness.advance();

        bob.expectReceivedMessage(from: alice, bytes: payload);
        charlie.expectReceivedMessage(from: alice, bytes: payload);
      });
    });
  });
}
