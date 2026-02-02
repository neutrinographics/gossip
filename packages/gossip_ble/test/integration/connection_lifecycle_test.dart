import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_ble/gossip_ble.dart';

import 'test_harness.dart';

void main() {
  group('Connection Lifecycle Integration Tests', () {
    late BleTestHarness harness;

    setUp(() {
      harness = BleTestHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('two devices complete handshake and become connected', () async {
      final [alice, bob] = harness.createDevices(['alice', 'bob']);

      await alice.connectTo(bob);

      // Both sides should have received PeerConnected
      alice.expectPeerConnectedEvent(bob);
      bob.expectPeerConnectedEvent(alice);

      // Both transports should show 1 connected peer
      alice.expectPeerCount(1);
      bob.expectPeerCount(1);

      alice.expectConnectedTo(bob);
      bob.expectConnectedTo(alice);
    });

    test('disconnection is detected by both sides', () async {
      final [alice, bob] = harness.createDevices(['alice', 'bob']);

      await alice.connectTo(bob);

      // Verify connected
      alice.expectPeerCount(1);
      bob.expectPeerCount(1);

      // Disconnect from alice's side
      await alice.disconnectFrom(bob);

      // Both should have received PeerDisconnected
      alice.expectPeerDisconnectedEvent(bob);
      bob.expectPeerDisconnectedEvent(alice);

      // Both should show 0 connected peers
      alice.expectPeerCount(0);
      bob.expectPeerCount(0);
    });

    test('reconnection after disconnect works correctly', () async {
      final [alice, bob] = harness.createDevices(['alice', 'bob']);

      // First connection
      await alice.connectTo(bob);
      alice.expectPeerCount(1);

      // Disconnect
      await alice.disconnectFrom(bob);
      alice.expectPeerCount(0);

      // Reconnect
      await alice.connectTo(bob);
      alice.expectPeerCount(1);

      // Should have: PeerConnected, PeerDisconnected, PeerConnected
      expect(alice.peerEvents, hasLength(3));
      expect(alice.peerEvents[0], isA<PeerConnected>());
      expect(alice.peerEvents[1], isA<PeerDisconnected>());
      expect(alice.peerEvents[2], isA<PeerConnected>());
    });

    test('advertising and discovery state is tracked correctly', () async {
      final alice = harness.createDevice('alice');

      expect(alice.isAdvertising, isFalse);
      expect(alice.isDiscovering, isFalse);

      await alice.startAdvertising();
      expect(alice.isAdvertising, isTrue);
      expect(alice.port.isAdvertising, isTrue);

      await alice.startDiscovery();
      expect(alice.isDiscovering, isTrue);
      expect(alice.port.isDiscovering, isTrue);

      await alice.stopAdvertising();
      expect(alice.isAdvertising, isFalse);
      expect(alice.port.isAdvertising, isFalse);

      await alice.stopDiscovery();
      expect(alice.isDiscovering, isFalse);
      expect(alice.port.isDiscovering, isFalse);
    });

    test('metrics are updated during connection lifecycle', () async {
      final [alice, bob] = harness.createDevices(['alice', 'bob']);

      // Initial state
      alice.expectMetrics(
        totalConnectionsEstablished: 0,
        totalHandshakesCompleted: 0,
        connectedPeerCount: 0,
      );

      // Connect
      await alice.connectTo(bob);

      alice.expectMetrics(
        totalConnectionsEstablished: 1,
        totalHandshakesCompleted: 1,
        connectedPeerCount: 1,
      );
      // Duration may be 0 for instant test handshakes
      expect(
        alice.metrics.averageHandshakeDuration,
        greaterThanOrEqualTo(Duration.zero),
      );

      // Disconnect
      await alice.disconnectFrom(bob);

      expect(alice.metrics.connectedPeerCount, 0);
      // Total counts should remain the same
      expect(alice.metrics.totalConnectionsEstablished, 1);
      expect(alice.metrics.totalHandshakesCompleted, 1);
    });
  });
}
