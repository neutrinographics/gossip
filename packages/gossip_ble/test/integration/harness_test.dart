import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_ble/gossip_ble.dart';

import 'test_harness.dart';

/// Tests for the test harness DSL itself.
void main() {
  group('BleTestHarness DSL', () {
    late BleTestHarness harness;

    setUp(() {
      harness = BleTestHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('creates devices with unique identifiers', () {
      final [alice, bob] = harness.createDevices(['alice', 'bob']);

      expect(alice.nodeId, isNot(equals(bob.nodeId)));
      expect(alice.deviceId, isNot(equals(bob.deviceId)));
      expect(alice.name, 'alice');
      expect(bob.name, 'bob');
    });

    test('connectTo establishes bidirectional connection', () async {
      final [alice, bob] = harness.createDevices(['alice', 'bob']);

      await alice.connectTo(bob);

      alice.expectConnectedTo(bob);
      bob.expectConnectedTo(alice);
      alice.expectPeerCount(1);
      bob.expectPeerCount(1);
    });

    test('disconnectFrom removes connection', () async {
      final [alice, bob] = harness.createDevices(['alice', 'bob']);

      await alice.connectTo(bob);
      await alice.disconnectFrom(bob);

      alice.expectNotConnectedTo(bob);
      bob.expectNotConnectedTo(alice);
    });

    test('sendTo delivers message', () async {
      final [alice, bob] = harness.createDevices(['alice', 'bob']);

      await alice.connectTo(bob);
      await alice.sendTo(bob, [1, 2, 3]);

      bob.expectReceivedFrom(alice, bytes: [1, 2, 3]);
    });

    test('failAllSends causes send errors', () async {
      final [alice, bob] = harness.createDevices(['alice', 'bob']);

      await alice.connectTo(bob);
      alice.failAllSends();
      await alice.sendTo(bob, [1, 2, 3]);

      alice.expectError<SendFailedError>();
      bob.expectReceivedCount(0);
    });

    test('clearEvents removes collected events', () async {
      final [alice, bob] = harness.createDevices(['alice', 'bob']);

      await alice.connectTo(bob);
      expect(alice.peerEvents, isNotEmpty);

      alice.clearEvents();
      expect(alice.peerEvents, isEmpty);
    });

    test('expectMetrics validates metric values', () async {
      final [alice, bob] = harness.createDevices(['alice', 'bob']);

      alice.expectMetrics(
        totalConnectionsEstablished: 0,
        totalHandshakesCompleted: 0,
        connectedPeerCount: 0,
      );

      await alice.connectTo(bob);

      alice.expectMetrics(
        totalConnectionsEstablished: 1,
        totalHandshakesCompleted: 1,
        connectedPeerCount: 1,
      );
    });

    test('MalformedData provides test byte sequences', () {
      expect(MalformedData.empty, isEmpty);
      expect(MalformedData.unknownMessageType, hasLength(1));
      expect(MalformedData.handshakeNoPayload, hasLength(1));
      expect(MalformedData.handshakeInvalidUtf8.first, 0x01); // handshake type
      expect(MalformedData.gossipNoPayload.first, 0x02); // gossip type
    });

    test('createDevices creates multiple devices at once', () {
      final devices = harness.createDevices(['a', 'b', 'c', 'd', 'e']);

      expect(devices, hasLength(5));
      expect(devices.map((d) => d.name), ['a', 'b', 'c', 'd', 'e']);
    });

    test('connectToAll connects to multiple peers', () async {
      final [alice, bob, charlie, diana] = harness.createDevices([
        'alice',
        'bob',
        'charlie',
        'diana',
      ]);

      await alice.connectToAll([bob, charlie, diana]);

      alice.expectPeerCount(3);
      alice.expectConnectedTo(bob);
      alice.expectConnectedTo(charlie);
      alice.expectConnectedTo(diana);
    });

    test('disconnectFromAll disconnects from multiple peers', () async {
      final [alice, bob, charlie] = harness.createDevices([
        'alice',
        'bob',
        'charlie',
      ]);

      await alice.connectToAll([bob, charlie]);
      await alice.disconnectFromAll([bob, charlie]);

      alice.expectPeerCount(0);
    });

    test('connectToSilentPeer creates silent peer connection', () async {
      final alice = harness.createDevice('alice');

      final silentPeer = alice.connectToSilentPeer();
      await harness.advance();

      // Should have pending handshake (silent peer never responds)
      alice.expectMetrics(pendingHandshakeCount: 1);
      expect(silentPeer.value, startsWith('silent-'));
    });

    test('expectAllConnectedTo checks multiple connections', () async {
      final alice = harness.createDevice('alice');
      final peers = harness.createDevices(['bob', 'charlie', 'diana']);

      await alice.connectToAll(peers);

      harness.expectAllConnectedTo(peers, alice);
    });

    test('expectNoErrorsOnAll checks no errors on multiple devices', () async {
      final devices = harness.createDevices(['alice', 'bob', 'charlie']);
      final [alice, bob, charlie] = devices;

      await alice.connectToAll([bob, charlie]);

      harness.expectNoErrorsOnAll(devices);
    });

    test('clearAllEvents clears events on all devices', () async {
      final [alice, bob] = harness.createDevices(['alice', 'bob']);

      await alice.connectTo(bob);
      expect(alice.peerEvents, isNotEmpty);
      expect(bob.peerEvents, isNotEmpty);

      harness.clearAllEvents();

      expect(alice.peerEvents, isEmpty);
      expect(bob.peerEvents, isEmpty);
    });

    group('harness disposal', () {
      test('harness dispose cleans up all devices', () async {
        final localHarness = BleTestHarness();
        final [alice, bob, charlie] = localHarness.createDevices([
          'alice',
          'bob',
          'charlie',
        ]);

        await alice.connectToAll([bob, charlie]);

        // Dispose entire harness
        await localHarness.dispose();

        // All devices should be disposed (can't easily verify, but shouldn't crash)
      });

      test('harness dispose after partial device disposal', () async {
        final localHarness = BleTestHarness();
        final [alice, bob] = localHarness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);
        await alice.transport.dispose(); // Manually dispose alice

        // Harness dispose should handle already-disposed device
        await localHarness.dispose();
      });
    });
  });
}
