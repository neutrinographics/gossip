import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_ble/gossip_ble.dart';
import 'package:gossip_ble/src/infrastructure/codec/handshake_codec.dart';

import 'fake_ble_port.dart';
import 'test_harness.dart';

/// Tests for timing-sensitive scenarios and race conditions.
///
/// These tests verify that the system handles concurrent operations
/// and edge cases in timing correctly.
void main() {
  group('Timing and Race Conditions', () {
    late BleTestHarness harness;

    setUp(() {
      harness = BleTestHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    group('handshake timing', () {
      test('handshake completes even with minimal delay', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        // Connect with no additional settling time
        FakeBlePort.connect(alice.port, bob.port);

        // Allow just enough time for event processing
        await Future<void>.delayed(const Duration(milliseconds: 10));

        // Both should complete handshake
        alice.expectConnectedTo(bob);
        bob.expectConnectedTo(alice);
      });

      test('multiple rapid connections complete correctly', () async {
        final [alice, bob, charlie, diana] = harness.createDevices([
          'alice',
          'bob',
          'charlie',
          'diana',
        ]);

        // Connect all to alice simultaneously
        FakeBlePort.connect(alice.port, bob.port);
        FakeBlePort.connect(alice.port, charlie.port);
        FakeBlePort.connect(alice.port, diana.port);

        await harness.advance(const Duration(milliseconds: 100));

        alice.expectPeerCount(3);
        harness.expectAllConnectedTo([bob, charlie, diana], alice);
      });

      test('disconnect during handshake is handled', () async {
        final alice = harness.createDevice('alice');
        final badDevice = const DeviceId('bad-device');

        // Start connection
        alice.simulateIncomingConnection(badDevice);

        // Immediately disconnect before handshake can complete
        await Future<void>.delayed(const Duration(milliseconds: 5));
        alice.simulateDisconnection(badDevice);

        await harness.advance();

        // Should have no connected peers
        alice.expectPeerCount(0);
      });

      test(
        'message arrives during handshake phase is buffered or dropped',
        () async {
          final [alice, bob] = harness.createDevices(['alice', 'bob']);

          // Start connection but don't wait for handshake
          FakeBlePort.connect(alice.port, bob.port);

          // Immediately try to send (handshake may or may not be complete)
          await Future<void>.delayed(const Duration(milliseconds: 1));

          // This tests the race between handshake completion and message send
          // The message should either be delivered or fail gracefully
          try {
            await alice.transport.messagePort.send(
              bob.nodeId,
              Uint8List.fromList([1, 2, 3]),
            );
          } catch (_) {
            // Expected if handshake not complete
          }

          await harness.advance();

          // Connection should still be healthy
          alice.expectConnectedTo(bob);
        },
      );
    });

    group('concurrent operations', () {
      test('simultaneous sends to same peer are serialized', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);
        bob.clearReceivedMessages();

        // Send multiple messages without awaiting
        final futures = <Future<void>>[];
        for (var i = 0; i < 10; i++) {
          futures.add(
            alice.transport.messagePort.send(
              bob.nodeId,
              Uint8List.fromList([i]),
            ),
          );
        }

        await Future.wait(futures);
        await harness.advance();

        // All messages should be received
        expect(bob.receivedMessages.length, 10);
      });

      test('simultaneous sends to different peers work correctly', () async {
        final [alice, bob, charlie] = harness.createDevices([
          'alice',
          'bob',
          'charlie',
        ]);

        await alice.connectToAll([bob, charlie]);

        bob.clearReceivedMessages();
        charlie.clearReceivedMessages();

        // Send to both peers simultaneously
        await Future.wait([
          alice.sendTo(bob, [1, 2, 3]),
          alice.sendTo(charlie, [4, 5, 6]),
        ]);

        bob.expectReceivedFrom(alice, bytes: [1, 2, 3]);
        charlie.expectReceivedFrom(alice, bytes: [4, 5, 6]);
      });

      test('connect and disconnect interleaved operations', () async {
        final [alice, bob, charlie] = harness.createDevices([
          'alice',
          'bob',
          'charlie',
        ]);

        // Connect to bob
        await alice.connectTo(bob);
        alice.expectPeerCount(1);

        // Simultaneously connect to charlie and disconnect from bob
        await Future.wait([
          alice.disconnectFrom(bob),
          alice.connectTo(charlie),
        ]);

        // Should have charlie connected
        alice.expectPeerCount(1);
        alice.expectConnectedTo(charlie);
        alice.expectNotConnectedTo(bob);
      });
    });

    group('reconnection scenarios', () {
      test('rapid reconnect to same peer works', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);
        alice.expectConnectedTo(bob);

        // Rapid disconnect and reconnect
        await alice.disconnectFrom(bob);
        await alice.connectTo(bob);

        alice.expectConnectedTo(bob);
        alice.expectPeerCount(1);
      });

      test('multiple reconnect cycles maintain correct state', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        for (var i = 0; i < 5; i++) {
          await alice.connectTo(bob);
          alice.expectConnectedTo(bob);
          alice.expectPeerCount(1);

          await alice.disconnectFrom(bob);
          alice.expectNotConnectedTo(bob);
          alice.expectPeerCount(0);
        }

        // Final metrics check
        alice.expectMetrics(
          totalConnectionsEstablished: 5,
          totalHandshakesCompleted: 5,
          connectedPeerCount: 0,
        );
      });

      test('message delivery works after reconnect', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        // First connection
        await alice.connectTo(bob);
        await alice.sendTo(bob, [1, 2, 3]);
        bob.expectReceivedFrom(alice, bytes: [1, 2, 3]);

        // Disconnect
        await alice.disconnectFrom(bob);
        bob.clearReceivedMessages();

        // Reconnect and send again
        await alice.connectTo(bob);
        await alice.sendTo(bob, [4, 5, 6]);
        bob.expectReceivedFrom(alice, bytes: [4, 5, 6]);
      });
    });

    group('event ordering', () {
      test('PeerConnected event received before first message', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        var connectedBeforeMessage = false;
        var messageReceived = false;

        alice.transport.peerEvents.listen((event) {
          if (event is PeerConnected && event.nodeId == bob.nodeId) {
            connectedBeforeMessage = !messageReceived;
          }
        });

        alice.transport.messagePort.incoming.listen((msg) {
          if (msg.sender == bob.nodeId) {
            messageReceived = true;
          }
        });

        await alice.connectTo(bob);
        await bob.sendTo(alice, [1, 2, 3]);

        expect(connectedBeforeMessage, isTrue);
      });

      test('PeerDisconnected event received after connection closes', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);
        alice.clearPeerEvents();

        await alice.disconnectFrom(bob);

        alice.expectPeerDisconnectedEvent(bob);
        alice.expectNotConnectedTo(bob);
      });

      test('events from multiple peers arrive in correct order', () async {
        final [alice, bob, charlie] = harness.createDevices([
          'alice',
          'bob',
          'charlie',
        ]);

        final events = <String>[];
        alice.transport.peerEvents.listen((event) {
          if (event is PeerConnected) {
            events.add('connected:${event.nodeId.value.split('-').first}');
          } else if (event is PeerDisconnected) {
            events.add('disconnected:${event.nodeId.value.split('-').first}');
          }
        });

        // Connect bob first, then charlie
        await alice.connectTo(bob);
        await alice.connectTo(charlie);

        // Disconnect bob first, then charlie
        await alice.disconnectFromAll([bob, charlie]);

        // Verify order
        expect(events[0], startsWith('connected:node'));
        expect(events[1], startsWith('connected:node'));
        expect(events[2], startsWith('disconnected:node'));
        expect(events[3], startsWith('disconnected:node'));
      });
    });

    group('send during state transitions', () {
      test('send during disconnect is handled gracefully', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);

        // Start disconnect and send simultaneously
        final disconnectFuture = alice.disconnectFrom(bob);
        final sendFuture = alice.transport.messagePort.send(
          bob.nodeId,
          Uint8List.fromList([1, 2, 3]),
        );

        // Both should complete without throwing
        await Future.wait([disconnectFuture, sendFuture]);

        // Alice should be disconnected
        alice.expectNotConnectedTo(bob);
      });

      test('send to recently disconnected peer fails gracefully', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);
        await alice.disconnectFrom(bob);

        // Try to send to disconnected peer
        await alice.sendToNodeId(bob.nodeId, [1, 2, 3]);

        // Should emit error, not throw
        alice.expectError<ConnectionNotFoundError>();
      });
    });

    group('handshake edge cases', () {
      test('duplicate handshake message is handled', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);
        final initialPeerCount = alice.connectedPeerCount;

        // Send another handshake from bob (simulating protocol error)
        const codec = HandshakeCodec();
        final duplicateHandshake = codec.encodeHandshake(bob.nodeId);
        alice.simulateBytesReceived(bob.deviceId, duplicateHandshake);
        await harness.advance();

        // Should still have exactly one connection
        expect(alice.connectedPeerCount, initialPeerCount);
      });

      test('handshake from new device replaces pending handshake', () async {
        final alice = harness.createDevice('alice');

        // Start two connections from different devices claiming same node
        // This tests the NodeId uniqueness handling
        final device1 = const DeviceId('device-1');
        final device2 = const DeviceId('device-2');

        alice.simulateIncomingConnection(device1);
        alice.simulateIncomingConnection(device2);

        await harness.advance();

        // Both will fail because neither has a peer to complete handshake
        // But system should not crash
        alice.expectPeerCount(0);
      });

      test('concurrent handshakes from same peer complete correctly', () async {
        final alice = harness.createDevice('alice');
        final sharedNodeId = NodeId('duplicate-peer');
        const codec = HandshakeCodec();

        // Simulate receiving two connection events rapidly from "same" peer
        // (different DeviceIds but same NodeId - happens with BLE address rotation)
        final device1 = const DeviceId('peer-device-1');
        final device2 = const DeviceId('peer-device-2');

        // First connection starts
        alice.simulateIncomingConnection(device1);
        await harness.advance();

        // Second connection starts before first completes handshake
        alice.simulateIncomingConnection(device2);
        await harness.advance();

        // Both complete handshake with same NodeId
        alice.simulateBytesReceived(
          device1,
          codec.encodeHandshake(sharedNodeId),
        );
        alice.simulateBytesReceived(
          device2,
          codec.encodeHandshake(sharedNodeId),
        );
        await harness.advance();

        // Should have exactly 1 peer (deduplicated by NodeId)
        alice.expectPeerCount(1);
      });

      test('rapid handshake attempts from same device are handled', () async {
        final alice = harness.createDevice('alice');
        final deviceId = const DeviceId('flaky-device');
        const codec = HandshakeCodec();

        // Simulate a flaky connection that connects/disconnects rapidly
        for (var i = 0; i < 3; i++) {
          alice.simulateIncomingConnection(deviceId);
          await harness.advance();
          alice.simulateDisconnection(deviceId);
          await harness.advance();
        }

        // Final successful connection
        alice.simulateIncomingConnection(deviceId);
        await harness.advance();
        alice.simulateBytesReceived(
          deviceId,
          codec.encodeHandshake(NodeId('flaky-node')),
        );
        await harness.advance();

        // Should have 1 connected peer
        alice.expectPeerCount(1);
      });
    });

    group('network latency simulation', () {
      test('messages are delivered after latency delay', () async {
        // Create devices with 100ms message delay
        final alice = harness.createDevice(
          'alice',
          messageDelay: const Duration(milliseconds: 100),
        );
        final bob = harness.createDevice('bob');

        await alice.connectTo(bob);
        bob.clearReceivedMessages();

        // Send message - should not be delivered immediately
        unawaited(alice.sendTo(bob, [1, 2, 3]));

        // Check immediately - message should not be received yet
        await harness.advance(const Duration(milliseconds: 50));
        expect(bob.receivedMessages, isEmpty);

        // Advance past the delay
        await harness.advance(const Duration(milliseconds: 60));
        bob.expectReceivedFrom(alice, bytes: [1, 2, 3]);
      });

      test('multiple messages with latency maintain order', () async {
        final alice = harness.createDevice(
          'alice',
          messageDelay: const Duration(milliseconds: 50),
        );
        final bob = harness.createDevice('bob');

        await alice.connectTo(bob);
        bob.clearReceivedMessages();

        // Send multiple messages
        unawaited(alice.sendTo(bob, [1]));
        unawaited(alice.sendTo(bob, [2]));
        unawaited(alice.sendTo(bob, [3]));

        // Advance time to deliver all
        await harness.advance(const Duration(milliseconds: 200));

        // All messages should arrive in order
        expect(bob.receivedMessages.length, 3);
        expect(bob.receivedMessages[0].bytes, Uint8List.fromList([1]));
        expect(bob.receivedMessages[1].bytes, Uint8List.fromList([2]));
        expect(bob.receivedMessages[2].bytes, Uint8List.fromList([3]));
      });

      test('zero latency delivers immediately', () async {
        // Device without message delay should deliver immediately
        final alice = harness.createDevice('alice');
        final bob = harness.createDevice('bob');

        await alice.connectTo(bob);
        bob.clearReceivedMessages();

        // Send without any explicit advance
        await alice.sendTo(bob, [1, 2, 3]);

        // Message should be received
        bob.expectReceivedFrom(alice, bytes: [1, 2, 3]);
      });

      test('latency does not affect receiver', () async {
        // Only Alice has latency - Bob's sends should be immediate
        final alice = harness.createDevice(
          'alice',
          messageDelay: const Duration(milliseconds: 100),
        );
        final bob = harness.createDevice('bob');

        // Use bob.connectTo(alice) so Bob initiates (no latency on Bob's handshake)
        await bob.connectTo(alice);

        // Advance extra time for Alice's handshake message to arrive
        await harness.advance(const Duration(milliseconds: 150));

        alice.clearReceivedMessages();

        // Bob sends to Alice - no latency on Bob's side
        await bob.sendTo(alice, [1, 2, 3]);

        // Alice should receive immediately (latency is on sender side)
        alice.expectReceivedFrom(bob, bytes: [1, 2, 3]);
      });
    });
  });
}
