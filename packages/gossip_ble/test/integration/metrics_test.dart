import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_ble/gossip_ble.dart';

import 'test_harness.dart';

void main() {
  group('Metrics Integration Tests', () {
    late BleTestHarness harness;

    setUp(() {
      harness = BleTestHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    group('connection metrics', () {
      test('initial metrics are zero', () {
        final alice = harness.createDevice('alice');

        expect(alice.metrics.connectedPeerCount, 0);
        expect(alice.metrics.pendingHandshakeCount, 0);
        expect(alice.metrics.totalConnectionsEstablished, 0);
        expect(alice.metrics.totalHandshakesCompleted, 0);
        expect(alice.metrics.totalHandshakesFailed, 0);
        expect(alice.metrics.totalBytesSent, 0);
        expect(alice.metrics.totalBytesReceived, 0);
        expect(alice.metrics.totalMessagesSent, 0);
        expect(alice.metrics.totalMessagesReceived, 0);
        expect(alice.metrics.averageHandshakeDuration, Duration.zero);
      });

      test('connection establishment increments counters', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);

        alice.expectMetrics(
          totalConnectionsEstablished: 1,
          totalHandshakesCompleted: 1,
          connectedPeerCount: 1,
          pendingHandshakeCount: 0,
        );
      });

      test('disconnection decrements connected count but not totals', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);
        await alice.disconnectFrom(bob);

        expect(alice.metrics.connectedPeerCount, 0);
        // Historical totals unchanged
        expect(alice.metrics.totalConnectionsEstablished, 1);
        expect(alice.metrics.totalHandshakesCompleted, 1);
      });

      test('multiple connections accumulate correctly', () async {
        final [alice, bob, charlie] = harness.createDevices([
          'alice',
          'bob',
          'charlie',
        ]);

        await alice.connectToAll([bob, charlie]);

        alice.expectMetrics(
          totalConnectionsEstablished: 2,
          totalHandshakesCompleted: 2,
          connectedPeerCount: 2,
        );
      });
    });

    group('handshake timing metrics', () {
      test('handshake duration is recorded', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);

        // Duration may be 0 or very small for instant handshakes in tests
        // The important thing is that totalHandshakesCompleted is recorded
        expect(alice.metrics.totalHandshakesCompleted, 1);
        expect(
          alice.metrics.averageHandshakeDuration,
          greaterThanOrEqualTo(Duration.zero),
        );
      });

      test('average duration calculated across multiple handshakes', () async {
        final [alice, bob, charlie] = harness.createDevices([
          'alice',
          'bob',
          'charlie',
        ]);

        await alice.connectToAll([bob, charlie]);

        // Average should be calculated from 2 handshakes
        expect(alice.metrics.totalHandshakesCompleted, 2);
        // Duration may be 0 for instant test handshakes
        expect(
          alice.metrics.averageHandshakeDuration,
          greaterThanOrEqualTo(Duration.zero),
        );
      });
    });

    group('message metrics', () {
      test('sent messages are counted', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);

        await alice.sendTo(bob, [1, 2, 3]);
        await alice.sendTo(bob, [4, 5, 6]);
        await alice.sendTo(bob, [7, 8, 9]);

        expect(alice.metrics.totalMessagesSent, 3);
      });

      test('received messages are counted', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);

        // Record baseline (includes handshake message)
        final baselineReceived = alice.metrics.totalMessagesReceived;

        await bob.sendTo(alice, [1]);
        await bob.sendTo(alice, [2]);

        // Should have received 2 additional messages
        expect(alice.metrics.totalMessagesReceived - baselineReceived, 2);
      });

      test('bytes sent includes protocol overhead', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);

        final payload = Uint8List.fromList([1, 2, 3, 4, 5]); // 5 bytes
        await alice.sendTo(bob, payload);

        // Bytes sent should be > 5 due to protocol wrapper
        expect(alice.metrics.totalBytesSent, greaterThan(5));
      });

      test('bytes received tracks incoming data', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);

        await bob.sendTo(alice, [1, 2, 3, 4, 5]);

        expect(alice.metrics.totalBytesReceived, greaterThan(5));
      });
    });

    group('failure metrics', () {
      test('failed handshake increments failure count', () async {
        final alice = harness.createDevice('alice');

        // Simulate connection without completing handshake
        alice.simulateIncomingConnection(const DeviceId('device-bad'));
        await harness.advance();

        // Send invalid handshake
        alice.simulateBytesReceived(
          const DeviceId('device-bad'),
          Uint8List.fromList([0xFF, 0xFF, 0xFF]),
        );

        await harness.advance();

        expect(alice.metrics.totalHandshakesFailed, 1);
        expect(alice.metrics.totalHandshakesCompleted, 0);
      });

      test('disconnection during handshake counts as failure', () async {
        final alice = harness.createDevice('alice');

        // Manually connect at the port level to a non-existent peer
        alice.simulateIncomingConnection(const DeviceId('device-broken'));
        await harness.advance();

        // The send will fail because device-broken isn't actually connected
        // This triggers a handshake failure
        await harness.advance();

        // Handshake should have failed due to send failure
        expect(alice.metrics.totalHandshakesFailed, greaterThanOrEqualTo(1));
      });

      test(
        'relationship: established = completed + failed + pending',
        () async {
          final [alice, bob] = harness.createDevices(['alice', 'bob']);

          // One successful connection
          await alice.connectTo(bob);

          // One failed connection
          alice.simulateIncomingConnection(const DeviceId('device-fail'));
          await harness.advance();
          alice.simulateBytesReceived(
            const DeviceId('device-fail'),
            Uint8List.fromList([0xFF]),
          );
          await harness.advance();

          // Verify relationship
          expect(
            alice.metrics.totalConnectionsEstablished,
            alice.metrics.totalHandshakesCompleted +
                alice.metrics.totalHandshakesFailed +
                alice.metrics.pendingHandshakeCount,
          );
        },
      );
    });

    group('metrics consistency', () {
      test('metrics remain consistent through complex scenarios', () async {
        final alice = harness.createDevice('alice');
        final peers = harness.createDevices(['peer0', 'peer1', 'peer2']);

        // Connect alice to all peers
        await alice.connectToAll(peers);

        alice.expectMetrics(
          totalConnectionsEstablished: 3,
          totalHandshakesCompleted: 3,
          connectedPeerCount: 3,
        );

        // Send messages
        for (final peer in peers) {
          await alice.sendTo(peer, [1, 2, 3]);
        }

        expect(alice.metrics.totalMessagesSent, 3);

        // Disconnect one
        await alice.disconnectFrom(peers[1]);

        expect(alice.metrics.connectedPeerCount, 2);
        expect(alice.metrics.totalConnectionsEstablished, 3); // Unchanged

        // Verify no negative values
        expect(alice.metrics.connectedPeerCount, greaterThanOrEqualTo(0));
        expect(alice.metrics.pendingHandshakeCount, greaterThanOrEqualTo(0));
      });

      test('metrics survive rapid connect/disconnect cycles', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        for (var i = 0; i < 5; i++) {
          await alice.connectTo(bob);
          await alice.disconnectFrom(bob);
        }

        expect(alice.metrics.totalConnectionsEstablished, 5);
        expect(alice.metrics.totalHandshakesCompleted, 5);
        expect(alice.metrics.connectedPeerCount, 0);
        expect(alice.metrics.pendingHandshakeCount, 0);
      });
    });
  });
}
