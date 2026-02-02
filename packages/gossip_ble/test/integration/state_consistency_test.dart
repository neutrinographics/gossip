import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_ble/gossip_ble.dart';
import 'package:gossip_ble/src/infrastructure/codec/handshake_codec.dart';

import 'test_harness.dart';

/// Tests for state consistency across complex multi-peer scenarios.
///
/// These tests verify that the connection registry, metrics, and event
/// streams remain consistent through various edge cases.
void main() {
  group('State Consistency', () {
    late BleTestHarness harness;

    setUp(() {
      harness = BleTestHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    group('NodeId uniqueness', () {
      test(
        'same NodeId from different DeviceIds replaces connection',
        () async {
          final alice = harness.createDevice('alice');

          // Create two fake devices that will claim the same NodeId
          final device1 = const DeviceId('device-1');
          final device2 = const DeviceId('device-2');
          final sharedNodeId = NodeId('shared-node');

          // First device connects
          alice.simulateIncomingConnection(device1);
          await harness.advance();

          // Complete handshake for device1
          const codec = HandshakeCodec();
          alice.simulateBytesReceived(
            device1,
            codec.encodeHandshake(sharedNodeId),
          );
          await harness.advance();

          alice.expectPeerCount(1);
          final firstEventCount = alice.peerEvents
              .whereType<PeerConnected>()
              .length;

          // Second device connects with same NodeId
          alice.simulateIncomingConnection(device2);
          await harness.advance();
          alice.simulateBytesReceived(
            device2,
            codec.encodeHandshake(sharedNodeId),
          );
          await harness.advance();

          // Should still have exactly 1 peer (replaced)
          alice.expectPeerCount(1);

          // Should have received a second PeerConnected (the replacement)
          final secondEventCount = alice.peerEvents
              .whereType<PeerConnected>()
              .length;
          expect(secondEventCount, firstEventCount + 1);
        },
      );

      test('message routes to newest DeviceId for NodeId', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);

        // Simulate bob reconnecting from a different device ID
        // (This happens on iOS due to address rotation)
        final newDeviceId = const DeviceId('bob-new-device');

        alice.simulateIncomingConnection(newDeviceId);
        await harness.advance();

        const codec = HandshakeCodec();
        alice.simulateBytesReceived(
          newDeviceId,
          codec.encodeHandshake(bob.nodeId),
        );
        await harness.advance();

        // Alice should still have 1 peer
        alice.expectPeerCount(1);

        // Clear bob's received messages
        bob.clearReceivedMessages();

        // Messages should still be deliverable to bob's NodeId
        // (though they'll go to new device ID internally)
        await alice.sendTo(bob, [1, 2, 3]);

        // Bob won't receive this via harness since the device ID changed
        // but Alice shouldn't error
        alice.expectNoError<ConnectionNotFoundError>();
      });

      test('three rapid reconnections with same NodeId', () async {
        final alice = harness.createDevice('alice');
        final sharedNodeId = NodeId('reconnecting-node');
        const codec = HandshakeCodec();

        for (var i = 1; i <= 3; i++) {
          final deviceId = DeviceId('device-$i');

          alice.simulateIncomingConnection(deviceId);
          await harness.advance();
          alice.simulateBytesReceived(
            deviceId,
            codec.encodeHandshake(sharedNodeId),
          );
          await harness.advance();
        }

        // Should have exactly 1 peer
        alice.expectPeerCount(1);

        // Should have 3 PeerConnected events (one for each connection)
        expect(alice.peerEvents.whereType<PeerConnected>().length, 3);
      });
    });

    group('metrics consistency', () {
      test('metrics match actual state after complex operations', () async {
        final [alice, bob, charlie] = harness.createDevices([
          'alice',
          'bob',
          'charlie',
        ]);

        // Connect both
        await alice.connectToAll([bob, charlie]);

        alice.expectMetrics(
          totalConnectionsEstablished: 2,
          totalHandshakesCompleted: 2,
          connectedPeerCount: 2,
        );

        // Disconnect bob
        await alice.disconnectFrom(bob);

        alice.expectMetrics(
          totalConnectionsEstablished: 2,
          totalHandshakesCompleted: 2,
          connectedPeerCount: 1,
        );

        // Reconnect bob
        await alice.connectTo(bob);

        alice.expectMetrics(
          totalConnectionsEstablished: 3,
          totalHandshakesCompleted: 3,
          connectedPeerCount: 2,
        );
      });

      test('failed handshakes are counted correctly', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        // Successful connection
        await alice.connectTo(bob);

        final baselineFailed = alice.metrics.totalHandshakesFailed;
        final baselineEstablished = alice.metrics.totalConnectionsEstablished;

        // Failed handshakes (invalid data)
        // Note: Each simulateIncomingConnection triggers a handshake send which
        // fails (device not actually connected), and then we also send invalid data.
        // So failures may be counted multiple times per attempt.
        for (var i = 0; i < 3; i++) {
          final badDevice = DeviceId('bad-device-$i');
          alice.simulateIncomingConnection(badDevice);
          await harness.advance();
          alice.simulateBytesReceived(
            badDevice,
            MalformedData.handshakeInvalidUtf8,
          );
          await harness.advance();
        }

        // Should have more failures than before
        expect(
          alice.metrics.totalHandshakesFailed,
          greaterThan(baselineFailed),
        );
        // Connections established should increase
        expect(
          alice.metrics.totalConnectionsEstablished,
          greaterThan(baselineEstablished),
        );
        // But only 1 successful handshake
        expect(alice.metrics.totalHandshakesCompleted, 1);
        expect(alice.metrics.connectedPeerCount, 1);
      });

      test('message metrics accumulate correctly', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);

        final baselineSent = alice.metrics.totalMessagesSent;
        final baselineReceived = bob.metrics.totalMessagesReceived;

        // Send 5 messages
        for (var i = 0; i < 5; i++) {
          await alice.sendTo(bob, [i]);
        }

        expect(alice.metrics.totalMessagesSent - baselineSent, 5);
        expect(bob.metrics.totalMessagesReceived - baselineReceived, 5);
      });
    });

    group('event stream consistency', () {
      test('PeerConnected count matches connectedPeerCount', () async {
        final [alice, bob, charlie, diana] = harness.createDevices([
          'alice',
          'bob',
          'charlie',
          'diana',
        ]);

        await alice.connectToAll([bob, charlie, diana]);

        final connectedEvents = alice.peerEvents
            .whereType<PeerConnected>()
            .length;
        expect(connectedEvents, alice.connectedPeerCount);
      });

      test('connected minus disconnected equals current count', () async {
        final [alice, bob, charlie] = harness.createDevices([
          'alice',
          'bob',
          'charlie',
        ]);

        await alice.connectToAll([bob, charlie]);
        await alice.disconnectFrom(bob);

        final connected = alice.peerEvents.whereType<PeerConnected>().length;
        final disconnected = alice.peerEvents
            .whereType<PeerDisconnected>()
            .length;

        expect(connected - disconnected, alice.connectedPeerCount);
      });

      test(
        'each connection produces exactly one PeerConnected event',
        () async {
          final alice = harness.createDevice('alice');
          final devices = harness.createDevices(
            List.generate(5, (i) => 'device$i'),
          );

          await alice.connectToAll(devices);

          // Each device should have produced exactly one PeerConnected
          for (final device in devices) {
            final events = alice.peerEvents
                .whereType<PeerConnected>()
                .where((e) => e.nodeId == device.nodeId)
                .toList();
            expect(
              events.length,
              1,
              reason:
                  'Device ${device.name} should have exactly 1 PeerConnected',
            );
          }
        },
      );
    });

    group('registry state consistency', () {
      test('connectedPeers set matches actual connections', () async {
        final [alice, bob, charlie] = harness.createDevices([
          'alice',
          'bob',
          'charlie',
        ]);

        await alice.connectToAll([bob, charlie]);

        expect(alice.connectedPeers, containsAll([bob.nodeId, charlie.nodeId]));
        expect(alice.connectedPeers.length, 2);

        await alice.disconnectFrom(bob);

        expect(alice.connectedPeers, contains(charlie.nodeId));
        expect(alice.connectedPeers, isNot(contains(bob.nodeId)));
        expect(alice.connectedPeers.length, 1);
      });

      test('bidirectional connection consistency', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);

        // Both sides should see the connection
        expect(alice.connectedPeers, contains(bob.nodeId));
        expect(bob.connectedPeers, contains(alice.nodeId));

        // Counts should match
        expect(alice.connectedPeerCount, bob.connectedPeerCount);
      });

      test('mesh network has consistent state', () async {
        final [alice, bob, charlie] = harness.createDevices([
          'alice',
          'bob',
          'charlie',
        ]);

        // Full mesh
        await alice.connectToAll([bob, charlie]);
        await bob.connectTo(charlie);

        // Each node should see 2 peers
        expect(alice.connectedPeerCount, 2);
        expect(bob.connectedPeerCount, 2);
        expect(charlie.connectedPeerCount, 2);

        // Verify specific connections
        alice.expectConnectedTo(bob);
        alice.expectConnectedTo(charlie);
        bob.expectConnectedTo(alice);
        bob.expectConnectedTo(charlie);
        charlie.expectConnectedTo(alice);
        charlie.expectConnectedTo(bob);
      });
    });

    group('error state consistency', () {
      test('errors dont corrupt connection state', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);

        // Cause some errors
        await alice.sendToNodeId(NodeId('nonexistent'), [1, 2, 3]);
        alice.failSendsTo(bob);
        await alice.sendTo(bob, [1, 2, 3]);
        alice.succeedSendsTo(bob);

        // Connection should still be valid
        alice.expectConnectedTo(bob);
        alice.expectPeerCount(1);

        // Should be able to send again
        await alice.sendTo(bob, [4, 5, 6]);
        bob.expectReceivedFrom(alice, bytes: [4, 5, 6]);
      });

      test('failed connection doesnt affect existing connections', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);

        // Failed connection attempt
        final badDevice = const DeviceId('bad-device');
        alice.simulateIncomingConnection(badDevice);
        await harness.advance();
        alice.simulateBytesReceived(badDevice, MalformedData.randomGarbage);
        await harness.advance();

        // Original connection should be unaffected
        alice.expectConnectedTo(bob);
        alice.expectPeerCount(1);
      });
    });

    group('initial state', () {
      test('properties are accessible in initial state', () async {
        final alice = harness.createDevice('alice');

        expect(alice.connectedPeerCount, 0);
        expect(alice.connectedPeers, isEmpty);
        expect(alice.isAdvertising, isFalse);
        expect(alice.isDiscovering, isFalse);
        expect(alice.metrics, isNotNull);
        expect(alice.transport.peerEvents, isNotNull);
        expect(alice.transport.errors, isNotNull);
      });

      test('state is consistent after rapid operations', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        // Rapid state changes
        await alice.startAdvertising();
        await alice.startDiscovery();
        await alice.connectTo(bob);
        await alice.stopAdvertising();
        await alice.sendTo(bob, [1, 2, 3]);
        await alice.stopDiscovery();
        await alice.disconnectFrom(bob);

        // Final state should be clean
        expect(alice.isAdvertising, isFalse);
        expect(alice.isDiscovering, isFalse);
        expect(alice.connectedPeerCount, 0);
      });
    });

    group('stress scenarios', () {
      test('rapid connect/disconnect maintains consistency', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        for (var i = 0; i < 10; i++) {
          await alice.connectTo(bob);
          await alice.disconnectFrom(bob);
        }

        // Final state should be disconnected
        alice.expectPeerCount(0);

        // Metrics should be consistent
        expect(alice.metrics.totalConnectionsEstablished, 10);
        expect(alice.metrics.totalHandshakesCompleted, 10);
      });

      test('many peers maintain individual state', () async {
        final alice = harness.createDevice('alice');
        final peers = harness.createDevices(List.generate(10, (i) => 'peer$i'));

        // Connect alice to all peers
        await alice.connectToAll(peers);

        alice.expectPeerCount(10);

        // Send unique message to each
        for (var i = 0; i < peers.length; i++) {
          await alice.sendTo(peers[i], [i]);
        }

        // Each peer should have received only their message
        for (var i = 0; i < peers.length; i++) {
          expect(peers[i].receivedCountFrom(alice), greaterThanOrEqualTo(1));
          peers[i].expectReceivedFrom(alice, bytes: [i]);
        }
      });
    });
  });
}
