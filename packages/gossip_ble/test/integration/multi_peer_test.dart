import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_ble/gossip_ble.dart';

import 'test_harness.dart';

void main() {
  group('Multi-Peer Integration Tests', () {
    late BleTestHarness harness;

    setUp(() {
      harness = BleTestHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('single device connects to multiple peers simultaneously', () async {
      final [alice, bob, charlie, diana] = harness.createDevices([
        'alice',
        'bob',
        'charlie',
        'diana',
      ]);

      // Alice connects to bob, charlie, diana
      await alice.connectToAll([bob, charlie, diana]);

      // Alice should have 3 connected peers
      alice.expectPeerCount(3);
      alice.expectConnectedTo(bob);
      alice.expectConnectedTo(charlie);
      alice.expectConnectedTo(diana);

      // Each other device should have 1 connected peer (alice)
      harness.expectAllConnectedTo([bob, charlie, diana], alice);
      bob.expectPeerCount(1);
      charlie.expectPeerCount(1);
      diana.expectPeerCount(1);

      // Alice should have received 3 PeerConnected events
      expect(alice.peerEvents.whereType<PeerConnected>().length, 3);
    });

    test('mesh topology: all devices connect to each other', () async {
      final [alice, bob, charlie, diana] = harness.createDevices([
        'alice',
        'bob',
        'charlie',
        'diana',
      ]);

      // Create full mesh
      await alice.connectToAll([bob, charlie, diana]);
      await bob.connectToAll([charlie, diana]);
      await charlie.connectTo(diana);

      // Each device should have 3 connected peers
      alice.expectPeerCount(3);
      bob.expectPeerCount(3);
      charlie.expectPeerCount(3);
      diana.expectPeerCount(3);

      // Verify specific connections
      alice.expectConnectedTo(bob);
      alice.expectConnectedTo(charlie);
      alice.expectConnectedTo(diana);

      bob.expectConnectedTo(alice);
      bob.expectConnectedTo(charlie);
      bob.expectConnectedTo(diana);

      charlie.expectConnectedTo(alice);
      charlie.expectConnectedTo(bob);
      charlie.expectConnectedTo(diana);

      diana.expectConnectedTo(alice);
      diana.expectConnectedTo(bob);
      diana.expectConnectedTo(charlie);
    });

    test('one peer disconnecting does not affect others', () async {
      final [alice, bob, charlie, diana] = harness.createDevices([
        'alice',
        'bob',
        'charlie',
        'diana',
      ]);

      // Alice connects to bob, charlie, diana
      await alice.connectToAll([bob, charlie, diana]);
      alice.expectPeerCount(3);

      // Charlie disconnects
      await alice.disconnectFrom(charlie);

      // Alice should still have 2 peers
      alice.expectPeerCount(2);
      alice.expectConnectedTo(bob);
      alice.expectConnectedTo(diana);
      alice.expectNotConnectedTo(charlie);

      // Bob and diana should still be connected to alice
      bob.expectPeerCount(1);
      diana.expectPeerCount(1);

      // Charlie should have 0 peers
      charlie.expectPeerCount(0);
    });

    test('metrics track multiple connections correctly', () async {
      final [alice, bob, charlie, diana] = harness.createDevices([
        'alice',
        'bob',
        'charlie',
        'diana',
      ]);

      // Alice connects to bob, charlie, diana
      await alice.connectToAll([bob, charlie, diana]);

      alice.expectMetrics(
        totalConnectionsEstablished: 3,
        totalHandshakesCompleted: 3,
        connectedPeerCount: 3,
        totalHandshakesFailed: 0,
      );

      // Disconnect one
      await alice.disconnectFrom(bob);

      expect(alice.metrics.connectedPeerCount, 2);
      // Historical counts unchanged
      expect(alice.metrics.totalConnectionsEstablished, 3);
      expect(alice.metrics.totalHandshakesCompleted, 3);
    });

    test('rapid sequential connections are handled correctly', () async {
      final alice = harness.createDevice('alice');
      final peers = harness.createDevices(['peer0', 'peer1', 'peer2', 'peer3']);

      // Connect all in rapid succession
      await alice.connectToAll(peers);

      alice.expectPeerCount(4);
      expect(alice.peerEvents.whereType<PeerConnected>().length, 4);
    });

    test('concurrent connect and disconnect operations', () async {
      final [alice, bob, charlie, diana] = harness.createDevices([
        'alice',
        'bob',
        'charlie',
        'diana',
      ]);

      // Connect alice to bob and charlie
      await alice.connectToAll([bob, charlie]);
      alice.expectPeerCount(2);

      // Simultaneously: disconnect bob and connect diana
      await Future.wait([alice.disconnectFrom(bob), alice.connectTo(diana)]);

      // Should have: charlie, diana
      alice.expectPeerCount(2);
      alice.expectConnectedTo(charlie);
      alice.expectConnectedTo(diana);
      alice.expectNotConnectedTo(bob);
    });
  });
}
