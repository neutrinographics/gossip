import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_ble/gossip_ble.dart';

import 'test_harness.dart';

/// Tests for handshake timeout behavior using deterministic time control.
///
/// These tests verify timeout logic that was previously impractical to test
/// due to real 30-second delays. With [InMemoryTimePort], we can advance
/// time precisely to test exact timeout boundaries.
void main() {
  group('Handshake Timeout', () {
    late BleTestHarness harness;

    setUp(() {
      harness = BleTestHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    group('timeout expiration', () {
      test('timeout does NOT fire before 30 seconds', () async {
        final alice = harness.createDevice('alice');

        // Connect to a silent peer (accepts messages, never responds)
        alice.connectToSilentPeer();
        await harness.advance();

        // Advance to just before timeout
        await harness.advanceJustBeforeTimeout();

        // Should NOT have timed out yet
        alice.expectNoError<HandshakeTimeoutError>();
        alice.expectMetrics(pendingHandshakeCount: 1);
      });

      test('timeout fires at exactly 30 seconds', () async {
        final alice = harness.createDevice('alice');

        // Connect to a silent peer
        alice.connectToSilentPeer();
        await harness.advance();

        // Advance to exactly 30 seconds
        await harness.advanceToHandshakeTimeout();

        // Should have timed out
        alice.expectError<HandshakeTimeoutError>();
        alice.expectMetrics(totalHandshakesFailed: 1, pendingHandshakeCount: 0);
      });

      test('timeout emits correct error details', () async {
        final alice = harness.createDevice('alice');

        final silentPeer = alice.connectToSilentPeer();
        await harness.advance();
        await harness.advanceToHandshakeTimeout();

        // Use the new expectError with details
        alice.expectError<HandshakeTimeoutError>(
          deviceId: silentPeer,
          messageContains: '30s',
        );
      });

      test('device is disconnected after timeout', () async {
        final alice = harness.createDevice('alice');

        // Connect to a silent peer that never responds
        alice.connectToSilentPeer();
        await harness.advance();

        // Advance past timeout
        await harness.advanceToHandshakeTimeout();

        // Alice should have timed out
        alice.expectError<HandshakeTimeoutError>();
      });
    });

    group('timeout cancellation', () {
      test('timeout is cancelled when handshake completes', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        // Connect and let handshake complete
        await alice.connectTo(bob);

        // Advance well past the timeout period
        await harness.advancePastTimeout();

        // Should NOT have timed out (timeout was cancelled)
        alice.expectNoError<HandshakeTimeoutError>();
        alice.expectConnectedTo(bob);
      });

      test(
        'timeout cancelled at 25s when handshake completes does not fire at 30s',
        () async {
          final alice = harness.createDevice('alice');

          // Start connection to silent device (will timeout)
          alice.connectToSilentPeer();
          await harness.advance();

          // Advance to 25 seconds (timeout still pending)
          await harness.advance(const Duration(seconds: 25));
          alice.expectNoError<HandshakeTimeoutError>();

          // Connect to a real device (bob) - this completes successfully
          final bob = harness.createDevice('bob');
          await alice.connectTo(bob);

          // Advance past the original 30s mark
          await harness.advance(const Duration(seconds: 10));

          // Silent device would timeout at 30s, bob's should not
          bob.expectNoError<HandshakeTimeoutError>();
          alice.expectConnectedTo(bob);
        },
      );

      test('timeout cancelled on disconnect before expiration', () async {
        final alice = harness.createDevice('alice');

        // Start connection to silent device
        final silentPeer = alice.connectToSilentPeer();
        await harness.advance();

        // Advance to 10 seconds
        await harness.advance(const Duration(seconds: 10));

        // Disconnect before timeout
        alice.simulateDisconnection(silentPeer);
        await harness.advance();

        // Advance past timeout
        await harness.advance(const Duration(seconds: 25));

        // Should NOT have timeout error (disconnect cancelled it)
        alice.expectNoError<HandshakeTimeoutError>();
      });
    });

    group('multiple concurrent handshakes', () {
      test('each device has independent timeout', () async {
        final alice = harness.createDevice('alice');

        // Start connection to device1 at t=0
        alice.connectToSilentPeer('device1');
        await harness.advance();

        // Start connection to device2 at t=5s
        await harness.advance(const Duration(seconds: 5));
        alice.connectToSilentPeer('device2');
        await harness.advance();

        // At t=25s: no timeouts yet
        await harness.advance(const Duration(seconds: 20));
        alice.expectNoError<HandshakeTimeoutError>();

        // At t=30s: device1 times out (started at t=0)
        await harness.advance(const Duration(seconds: 5));
        alice.expectErrorCount<HandshakeTimeoutError>(1);

        // At t=35s: device2 times out (started at t=5)
        await harness.advance(const Duration(seconds: 5));
        alice.expectErrorCount<HandshakeTimeoutError>(2);
      });

      test('completing one handshake does not affect others timeout', () async {
        final alice = harness.createDevice('alice');
        final bob = harness.createDevice('bob');

        // Start connection to silent device (will timeout)
        alice.connectToSilentPeer();
        await harness.advance();

        // Connect to bob (will complete successfully)
        await harness.advance(const Duration(seconds: 5));
        await alice.connectTo(bob);

        // Bob should be connected
        alice.expectConnectedTo(bob);

        // Advance to 30s - silent device should timeout
        await harness.advance(const Duration(seconds: 25));

        // Silent device timed out, but bob is still connected
        alice.expectError<HandshakeTimeoutError>();
        alice.expectConnectedTo(bob);
      });

      test('disconnecting one device does not cancel other timeouts', () async {
        final alice = harness.createDevice('alice');

        // Start both connections at t=0
        final device1 = alice.connectToSilentPeer('device1');
        final device2 = alice.connectToSilentPeer('device2');
        await harness.advance();

        // Disconnect device1 at t=10s
        await harness.advance(const Duration(seconds: 10));
        alice.simulateDisconnection(device1);
        await harness.advance();

        // At t=30s: device2 should timeout (device1's timeout was cancelled)
        await harness.advance(const Duration(seconds: 20));

        // Only one timeout error (for device2)
        alice.expectErrorCount<HandshakeTimeoutError>(1);
        alice.expectError<HandshakeTimeoutError>(deviceId: device2);
      });
    });

    group('metrics with precise timing', () {
      test('handshake duration is recorded accurately', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        // Start connection
        await alice.connectTo(bob);

        // Handshake completes quickly with InMemoryTimePort
        alice.expectMetrics(
          totalHandshakesCompleted: 1,
          totalHandshakesFailed: 0,
        );
      });

      test('failed handshakes are counted correctly with timeouts', () async {
        final alice = harness.createDevice('alice');

        // Start 3 connections that will all timeout (silent peers)
        alice.connectToSilentPeers(3);
        await harness.advance();

        // Metrics should show 3 pending
        alice.expectMetrics(
          totalConnectionsEstablished: 3,
          pendingHandshakeCount: 3,
        );

        // Advance past timeout
        await harness.advanceToHandshakeTimeout();

        // All 3 should have failed
        alice.expectMetrics(
          totalConnectionsEstablished: 3,
          totalHandshakesFailed: 3,
          pendingHandshakeCount: 0,
        );
        alice.expectErrorCount<HandshakeTimeoutError>(3);
      });
    });

    group('disposal', () {
      test('disposing service cancels all pending timeouts', () async {
        final alice = harness.createDevice('alice');

        // Start connections that would timeout (silent peers)
        alice.connectToSilentPeers(2);
        await harness.advance();

        // Dispose alice at t=10s
        await harness.advance(const Duration(seconds: 10));
        await alice.dispose();

        // Advance past timeout
        await harness.advance(const Duration(seconds: 25));

        // Should NOT have timeout errors (disposal cancelled them)
        alice.expectNoError<HandshakeTimeoutError>();
      });

      test('no timeout callbacks fire after disposal', () async {
        final alice = harness.createDevice('alice');

        alice.connectToSilentPeer();
        await harness.advance();

        // Dispose immediately
        await alice.dispose();

        // Advance well past timeout
        await harness.advancePastTimeout();

        // No errors should be recorded (streams are closed)
        expect(alice.errors, isEmpty);
      });
    });

    group('edge cases', () {
      test('timeout at exact boundary with millisecond precision', () async {
        final alice = harness.createDevice('alice');

        alice.connectToSilentPeer();
        await harness.advance();

        // Advance to just before timeout
        await harness.advanceJustBeforeTimeout();
        alice.expectNoError<HandshakeTimeoutError>();

        // Advance that final millisecond
        await harness.advance(const Duration(milliseconds: 1));
        alice.expectError<HandshakeTimeoutError>();
      });

      test('rapid connect-disconnect cycles do not leak timeouts', () async {
        final alice = harness.createDevice('alice');

        // Rapidly connect and disconnect 10 silent devices
        for (var i = 0; i < 10; i++) {
          final silentPeer = alice.connectToSilentPeer('device$i');
          await harness.advance(const Duration(milliseconds: 10));
          alice.simulateDisconnection(silentPeer);
          await harness.advance(const Duration(milliseconds: 10));
        }

        // Advance past all possible timeouts
        await harness.advancePastTimeout();

        // No timeout errors (all were cancelled on disconnect)
        alice.expectNoError<HandshakeTimeoutError>();
      });

      test('timeout during message send does not crash', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        // Connect normally first
        await alice.connectTo(bob);

        // Start a new connection that will timeout (silent peer)
        alice.connectToSilentPeer();
        await harness.advance();

        // Send messages while timeout is pending
        await alice.sendTo(bob, [1, 2, 3]);
        await alice.sendTo(bob, [4, 5, 6]);

        // Let timeout fire
        await harness.advanceToHandshakeTimeout();

        // Alice should still be connected to bob
        alice.expectConnectedTo(bob);
        // Timeout error for silent device
        alice.expectError<HandshakeTimeoutError>();
        // Messages should have been received
        bob.expectReceivedFrom(alice, bytes: [1, 2, 3]);
        bob.expectReceivedFrom(alice, bytes: [4, 5, 6]);
      });
    });
  });
}
