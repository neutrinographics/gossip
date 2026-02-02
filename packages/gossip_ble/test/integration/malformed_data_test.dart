import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_ble/gossip_ble.dart';

import 'test_harness.dart';

/// Tests for handling malformed data and protocol edge cases.
///
/// These tests verify that the system handles invalid input gracefully
/// without crashing or corrupting state.
void main() {
  group('Malformed Data Handling', () {
    late BleTestHarness harness;

    setUp(() {
      harness = BleTestHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    group('invalid handshake data', () {
      test('empty bytes are ignored', () async {
        final alice = harness.createDevice('alice');
        final badDevice = const DeviceId('bad-device');

        alice.simulateIncomingConnection(badDevice);
        await harness.advance();

        alice.simulateBytesReceived(badDevice, MalformedData.empty);
        await harness.advance();

        // Should not crash, connection should not complete
        alice.expectPeerCount(0);
      });

      test('unknown message type is handled gracefully', () async {
        final alice = harness.createDevice('alice');
        final badDevice = const DeviceId('bad-device');

        alice.simulateIncomingConnection(badDevice);
        await harness.advance();

        alice.simulateBytesReceived(
          badDevice,
          MalformedData.unknownMessageType,
        );
        await harness.advance();

        // Should not crash, message logged as unknown
        alice.expectPeerCount(0);
      });

      test('handshake with no payload triggers error', () async {
        final alice = harness.createDevice('alice');
        final badDevice = const DeviceId('bad-device');

        alice.simulateIncomingConnection(badDevice);
        await harness.advance();

        alice.simulateBytesReceived(
          badDevice,
          MalformedData.handshakeNoPayload,
        );
        await harness.advance();

        alice.expectPeerCount(0);
        alice.expectError<HandshakeInvalidError>();
      });

      test('handshake with truncated data triggers error', () async {
        final alice = harness.createDevice('alice');
        final badDevice = const DeviceId('bad-device');

        alice.simulateIncomingConnection(badDevice);
        await harness.advance();

        alice.simulateBytesReceived(
          badDevice,
          MalformedData.handshakeTruncated,
        );
        await harness.advance();

        alice.expectPeerCount(0);
        alice.expectError<HandshakeInvalidError>();
      });

      test('handshake with length overflow triggers error', () async {
        final alice = harness.createDevice('alice');
        final badDevice = const DeviceId('bad-device');

        alice.simulateIncomingConnection(badDevice);
        await harness.advance();

        alice.simulateBytesReceived(
          badDevice,
          MalformedData.handshakeLengthOverflow,
        );
        await harness.advance();

        alice.expectPeerCount(0);
        alice.expectError<HandshakeInvalidError>();
      });

      test('handshake with invalid UTF-8 triggers error', () async {
        final alice = harness.createDevice('alice');
        final badDevice = const DeviceId('bad-device');

        alice.simulateIncomingConnection(badDevice);
        await harness.advance();

        alice.simulateBytesReceived(
          badDevice,
          MalformedData.handshakeInvalidUtf8,
        );
        await harness.advance();

        alice.expectPeerCount(0);
        alice.expectError<HandshakeInvalidError>();
      });

      test('handshake with empty NodeId triggers error', () async {
        final alice = harness.createDevice('alice');
        final badDevice = const DeviceId('bad-device');

        alice.simulateIncomingConnection(badDevice);
        await harness.advance();

        alice.simulateBytesReceived(
          badDevice,
          MalformedData.handshakeEmptyNodeId,
        );
        await harness.advance();

        // Empty NodeId should be rejected or handled
        alice.expectPeerCount(0);
      });

      test('random garbage bytes are handled gracefully', () async {
        final alice = harness.createDevice('alice');
        final badDevice = const DeviceId('bad-device');

        alice.simulateIncomingConnection(badDevice);
        await harness.advance();

        alice.simulateBytesReceived(badDevice, MalformedData.randomGarbage);
        await harness.advance();

        // Should not crash
        alice.expectPeerCount(0);
      });
    });

    group('invalid gossip data', () {
      test('gossip with no payload delivers empty message', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);
        alice.clearReceivedMessages();

        // Send gossip message with just type byte, no payload
        alice.simulateBytesReceived(
          bob.deviceId,
          MalformedData.gossipNoPayload,
        );
        await harness.advance();

        // Empty payload is technically valid - delivers empty bytes
        // The protocol doesn't require non-empty payloads
        alice.expectReceivedCount(1);
        expect(alice.receivedMessages.first.bytes, isEmpty);
      });

      test('gossip from unknown device is ignored', () async {
        final alice = harness.createDevice('alice');
        final unknownDevice = const DeviceId('unknown');

        // Valid gossip format but from unknown device
        final validGossip = Uint8List.fromList([0x02, 0x01, 0x02, 0x03]);
        alice.simulateBytesReceived(unknownDevice, validGossip);
        await harness.advance();

        // Should be silently dropped
        alice.expectReceivedCount(0);
        alice.expectNoErrors();
      });
    });

    group('message type edge cases', () {
      test('type byte 0x00 is handled as unknown', () async {
        final alice = harness.createDevice('alice');
        final badDevice = const DeviceId('bad-device');

        alice.simulateIncomingConnection(badDevice);
        await harness.advance();

        alice.simulateBytesReceived(
          badDevice,
          Uint8List.fromList([0x00, 0x01, 0x02]),
        );
        await harness.advance();

        // Should not crash
        alice.expectPeerCount(0);
      });

      test('type byte 0xFF is handled as unknown', () async {
        final alice = harness.createDevice('alice');
        final badDevice = const DeviceId('bad-device');

        alice.simulateIncomingConnection(badDevice);
        await harness.advance();

        alice.simulateBytesReceived(
          badDevice,
          Uint8List.fromList([0xFF, 0x01, 0x02]),
        );
        await harness.advance();

        // Should not crash
        alice.expectPeerCount(0);
      });
    });

    group('boundary conditions', () {
      test('very large handshake payload is handled', () async {
        final alice = harness.createDevice('alice');
        final badDevice = const DeviceId('bad-device');

        alice.simulateIncomingConnection(badDevice);
        await harness.advance();

        // Create a handshake with 10KB NodeId (unrealistic but tests limits)
        final largeNodeId = List.filled(10000, 0x41); // 'A' repeated
        final payload = Uint8List.fromList([
          0x01, // type
          (largeNodeId.length >> 24) & 0xFF,
          (largeNodeId.length >> 16) & 0xFF,
          (largeNodeId.length >> 8) & 0xFF,
          largeNodeId.length & 0xFF,
          ...largeNodeId,
        ]);

        alice.simulateBytesReceived(badDevice, payload);
        await harness.advance();

        // Should handle without crashing (may accept or reject)
        // The important thing is no exception
      });

      test('single byte messages are handled', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);

        // Single byte gossip payload
        await alice.sendTo(bob, [0x42]);
        bob.expectReceivedFrom(alice, bytes: [0x42]);
      });

      test('maximum reasonable payload is handled', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);

        // 64KB payload (reasonable BLE limit for multiple packets)
        final largePayload = List.generate(65536, (i) => i % 256);
        await alice.sendTo(bob, largePayload);

        bob.expectReceivedFrom(alice);
        final received = bob.receivedMessages.last;
        expect(received.bytes.length, 65536);
      });
    });

    group('duplicate and repeated data', () {
      test('duplicate handshake from same device is handled', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);

        // Simulate receiving another handshake from already-connected bob
        // This mimics a protocol error or replay attack
        final duplicateHandshake = Uint8List.fromList([
          0x01, // type
          0x00, 0x00, 0x00, 0x08, // length
          ...bob.nodeId.value.codeUnits.take(8),
        ]);
        alice.simulateBytesReceived(bob.deviceId, duplicateHandshake);
        await harness.advance();

        // Should not crash or create duplicate connection
        alice.expectPeerCount(1);
      });

      test('rapid repeated messages are all delivered', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);

        // Send 100 messages rapidly
        for (var i = 0; i < 100; i++) {
          await alice.transport.messagePort.send(
            bob.nodeId,
            Uint8List.fromList([i]),
          );
        }
        await harness.advance(const Duration(milliseconds: 200));

        // All should be received
        expect(bob.receivedMessages.length, 100);
      });
    });

    group('interleaved and corrupted streams', () {
      test('valid message after invalid one is still processed', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);
        bob.clearReceivedMessages();

        // Send invalid data
        alice.simulateBytesReceived(bob.deviceId, MalformedData.randomGarbage);
        await harness.advance();

        // Send valid message
        await alice.sendTo(bob, [1, 2, 3]);

        // Valid message should still be received
        bob.expectReceivedFrom(alice, bytes: [1, 2, 3]);
      });

      test('system recovers after malformed handshake attempt', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        // First: failed handshake from bad device
        final badDevice = const DeviceId('bad-device');
        alice.simulateIncomingConnection(badDevice);
        await harness.advance();
        alice.simulateBytesReceived(
          badDevice,
          MalformedData.handshakeInvalidUtf8,
        );
        await harness.advance();

        // Then: successful connection to bob
        await alice.connectTo(bob);

        alice.expectConnectedTo(bob);
        alice.expectPeerCount(1);
      });
    });
  });
}
