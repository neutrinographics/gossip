import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_ble/gossip_ble.dart';

import 'test_harness.dart';

void main() {
  group('Error Handling Integration Tests', () {
    late BleTestHarness harness;

    setUp(() {
      harness = BleTestHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('send failure emits error event', () async {
      final [alice, bob] = harness.createDevices(['alice', 'bob']);

      await alice.connectTo(bob);

      // Make sends fail
      alice.failAllSends();

      // Attempt to send
      await alice.sendTo(bob, [1, 2, 3]);

      alice.expectError<SendFailedError>();
    });

    test('send to unknown peer emits ConnectionNotFoundError', () async {
      final [alice, unknown] = harness.createDevices(['alice', 'unknown']);
      // Note: alice is NOT connected to unknown

      await alice.sendToNodeId(unknown.nodeId, [1, 2, 3]);

      alice.expectError<ConnectionNotFoundError>();
    });

    test('disconnection mid-handshake records failure in metrics', () async {
      final alice = harness.createDevice('alice');

      // Simulate incoming connection from a device that doesn't exist in FakeBlePort
      // The handshake send will fail because the device isn't actually connected
      alice.simulateIncomingConnection(const DeviceId('device-nonexistent'));

      await harness.advance();

      // Handshake should fail due to send failure (device not connected)
      expect(alice.metrics.totalHandshakesFailed, greaterThanOrEqualTo(1));
      expect(alice.metrics.totalHandshakesCompleted, 0);
    });

    test('invalid handshake data is handled gracefully', () async {
      final alice = harness.createDevice('alice');

      // Simulate incoming connection
      alice.simulateIncomingConnection(const DeviceId('device-b'));
      await harness.advance();

      // Send invalid handshake data
      alice.simulateBytesReceived(
        const DeviceId('device-b'),
        Uint8List.fromList([0xFF, 0xFF, 0xFF]), // Invalid format
      );

      await harness.advance();

      alice.expectError<HandshakeInvalidError>();
      expect(alice.metrics.totalHandshakesFailed, 1);
    });

    test('connection after transport dispose throws', () async {
      final alice = harness.createDevice('alice');

      await alice.dispose();

      expect(
        () => alice.simulateIncomingConnection(const DeviceId('device-x')),
        throwsStateError,
      );
    });

    test('errors include timestamps', () async {
      final [alice, unknown] = harness.createDevices(['alice', 'unknown']);

      final beforeTime = DateTime.now();

      await alice.sendToNodeId(unknown.nodeId, [1]);

      await harness.advance();

      final afterTime = DateTime.now();

      alice.expectErrorCount<ConnectionNotFoundError>(1);
      expect(
        alice.errors.first.occurredAt.isAfter(
          beforeTime.subtract(const Duration(seconds: 1)),
        ),
        isTrue,
      );
      expect(
        alice.errors.first.occurredAt.isBefore(
          afterTime.add(const Duration(seconds: 1)),
        ),
        isTrue,
      );
    });

    test('peer disconnect during message send is handled', () async {
      final [alice, bob] = harness.createDevices(['alice', 'bob']);

      await alice.connectTo(bob);

      // Set up to fail sends to specific device
      alice.failSendsTo(bob);

      // Try to send
      await alice.sendTo(bob, [1, 2, 3]);

      alice.expectError<SendFailedError>();
    });

    group('recovery scenarios', () {
      test('transport recovers from temporary send failures', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);

        // Cause failure
        alice.failAllSends();
        await alice.sendTo(bob, [1]);
        alice.expectError<SendFailedError>();

        // Recover
        alice.succeedAllSends();
        alice.clearErrors();
        bob.clearReceivedMessages();

        await alice.sendTo(bob, [2]);
        alice.expectNoErrors();
        bob.expectReceivedFrom(alice, bytes: [2]);
      });

      test('connection errors dont prevent new connections', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        // Cause error by sending to nonexistent peer
        await alice.sendToNodeId(bob.nodeId, [1]);
        alice.expectError<ConnectionNotFoundError>();

        // Should still be able to connect
        await alice.connectTo(bob);
        alice.expectConnectedTo(bob);
      });

      test('new connection after failed handshake works', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        // First connection - fail by sending invalid data
        alice.simulateIncomingConnection(const DeviceId('device-b'));
        await harness.advance();
        alice.simulateBytesReceived(
          const DeviceId('device-b'),
          Uint8List.fromList([0xFF, 0xFF]),
        );
        await harness.advance();

        alice.expectPeerCount(0);
        expect(alice.metrics.totalHandshakesFailed, 1);

        // Second connection - should work
        await alice.connectTo(bob);

        alice.expectPeerCount(1);
        expect(alice.metrics.totalHandshakesCompleted, 1);
        alice.expectPeerConnectedEvent(bob);
      });
    });
  });
}
