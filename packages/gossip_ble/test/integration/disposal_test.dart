import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_ble/gossip_ble.dart';

import 'fake_ble_port.dart';
import 'test_harness.dart';

/// Tests for proper resource cleanup and disposal behavior.
///
/// These tests verify that disposing the transport at various stages
/// doesn't cause crashes, memory leaks, or inconsistent state.
void main() {
  group('Disposal and Cleanup', () {
    group('basic disposal', () {
      test('dispose with no connections succeeds', () async {
        final harness = BleTestHarness();
        final alice = harness.createDevice('alice');

        // Dispose immediately
        await alice.transport.dispose();

        // Should not throw
      });

      test('dispose with active connections cleans up', () async {
        final harness = BleTestHarness();
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);
        alice.expectPeerCount(1);

        await alice.transport.dispose();

        // Bob should see disconnect
        await harness.advance();
        bob.expectPeerCount(0);

        await harness.dispose();
      });

      test('double dispose is safe', () async {
        final harness = BleTestHarness();
        final alice = harness.createDevice('alice');

        await alice.transport.dispose();
        await alice.transport.dispose(); // Should not throw

        await harness.dispose();
      });

      test('dispose cancels pending handshake timers', () async {
        final harness = BleTestHarness();
        final alice = harness.createDevice('alice');

        // Start a handshake that won't complete (silent peer)
        alice.connectToSilentPeer();
        await harness.advance();

        // Dispose before handshake timeout
        await alice.transport.dispose();

        // Wait longer than any potential timeout callback
        await Future<void>.delayed(const Duration(milliseconds: 100));

        // Should not crash from timer firing after dispose
        await harness.dispose();
      });
    });

    group('operations after dispose', () {
      test('startAdvertising after dispose is safe', () async {
        final harness = BleTestHarness();
        final alice = harness.createDevice('alice');

        await alice.transport.dispose();

        // Should handle gracefully (may throw or no-op)
        try {
          await alice.startAdvertising();
        } catch (e) {
          // Expected - port is disposed
          expect(e, isA<StateError>());
        }

        await harness.dispose();
      });

      test('startDiscovery after dispose is safe', () async {
        final harness = BleTestHarness();
        final alice = harness.createDevice('alice');

        await alice.transport.dispose();

        try {
          await alice.startDiscovery();
        } catch (e) {
          expect(e, isA<StateError>());
        }

        await harness.dispose();
      });

      test('send after dispose fails gracefully', () async {
        final harness = BleTestHarness();
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);
        final bobNodeId = bob.nodeId;

        await alice.transport.dispose();

        // Sending after dispose should not crash
        // The messagePort is closed, so this should be a no-op
        await alice.transport.messagePort.send(
          bobNodeId,
          Uint8List.fromList([1, 2, 3]),
        );

        await harness.dispose();
      });

      test('accessing connectedPeers after dispose is safe', () async {
        final harness = BleTestHarness();
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);
        await alice.transport.dispose();

        // Should not throw when accessing
        // Note: Registry state may still show old connections
        // since dispose doesn't necessarily clear the registry
        final peers = alice.transport.connectedPeers;
        expect(peers, isA<Set<NodeId>>());

        await harness.dispose();
      });
    });

    group('dispose during operations', () {
      test('dispose during send operation completes', () async {
        final harness = BleTestHarness();
        final alice = harness.createDevice(
          'alice',
          messageDelay: const Duration(milliseconds: 50),
        );
        final bob = harness.createDevice('bob');

        await alice.connectTo(bob);

        // Start send with delay (don't await yet)
        final sendFuture = alice.transport.messagePort.send(
          bob.nodeId,
          Uint8List.fromList([1, 2, 3]),
        );

        // Dispose while send is in progress
        await alice.transport.dispose();

        // Advance time to let the delayed send complete
        await harness.advance(const Duration(milliseconds: 100));

        // Send should complete (or fail gracefully) - the delay completes
        // but the peer is disconnected so nothing bad happens
        await sendFuture;

        await harness.dispose();
      });

      test('dispose while connecting cleans up correctly', () async {
        final harness = BleTestHarness();
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        // Start connection without waiting
        FakeBlePort.connect(alice.port, bob.port);

        // Immediately dispose
        await alice.transport.dispose();
        await harness.advance();

        // Bob may or may not see the connection depending on timing
        // The important thing is no crash
        await harness.dispose();
      });

      test('dispose with messages in flight', () async {
        final harness = BleTestHarness();
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);

        // Queue up multiple sends
        for (var i = 0; i < 10; i++) {
          unawaited(
            alice.transport.messagePort.send(
              bob.nodeId,
              Uint8List.fromList([i]),
            ),
          );
        }

        // Dispose immediately
        await alice.transport.dispose();
        await harness.advance();

        // Some messages may have been delivered, some may not
        // Important: no crash
        await harness.dispose();
      });
    });

    group('event streams after dispose', () {
      test('peerEvents stream closes on dispose', () async {
        final harness = BleTestHarness();
        final alice = harness.createDevice('alice');

        var streamClosed = false;
        alice.transport.peerEvents.listen(
          (_) {},
          onDone: () => streamClosed = true,
        );

        await alice.transport.dispose();
        await harness.advance();

        expect(streamClosed, isTrue);

        await harness.dispose();
      });

      test('errors stream closes on dispose', () async {
        final harness = BleTestHarness();
        final alice = harness.createDevice('alice');

        var streamClosed = false;
        alice.transport.errors.listen(
          (_) {},
          onDone: () => streamClosed = true,
        );

        await alice.transport.dispose();
        await harness.advance();

        expect(streamClosed, isTrue);

        await harness.dispose();
      });

      test('incoming messages stream closes on dispose', () async {
        final harness = BleTestHarness();
        final alice = harness.createDevice('alice');

        var streamClosed = false;
        alice.transport.messagePort.incoming.listen(
          (_) {},
          onDone: () => streamClosed = true,
        );

        await alice.transport.dispose();
        await harness.advance();

        expect(streamClosed, isTrue);

        await harness.dispose();
      });
    });

    group('peer disposal effects', () {
      test('peer disposing triggers local disconnect event', () async {
        final harness = BleTestHarness();
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);
        alice.clearPeerEvents();

        // Bob disposes
        await bob.transport.dispose();
        await harness.advance();

        // Alice should see disconnect
        alice.expectPeerDisconnectedEvent(bob);
        alice.expectPeerCount(0);

        await harness.dispose();
      });

      test('multiple peers disposing in sequence', () async {
        final harness = BleTestHarness();
        final [alice, bob, charlie] = harness.createDevices([
          'alice',
          'bob',
          'charlie',
        ]);

        await alice.connectToAll([bob, charlie]);
        alice.expectPeerCount(2);

        await bob.transport.dispose();
        await harness.advance();
        alice.expectPeerCount(1);

        await charlie.transport.dispose();
        await harness.advance();
        alice.expectPeerCount(0);

        await harness.dispose();
      });

      test('simultaneous disposal of multiple peers', () async {
        final harness = BleTestHarness();
        final [alice, bob, charlie] = harness.createDevices([
          'alice',
          'bob',
          'charlie',
        ]);

        await alice.connectToAll([bob, charlie]);

        // Dispose both simultaneously
        await Future.wait([
          bob.transport.dispose(),
          charlie.transport.dispose(),
        ]);
        await harness.advance();

        alice.expectPeerCount(0);

        await harness.dispose();
      });
    });

    group('resource leak prevention', () {
      test('timers are cancelled on dispose', () async {
        final harness = BleTestHarness();
        final alice = harness.createDevice('alice');

        // Create multiple pending handshakes (each has a timer)
        alice.connectToSilentPeers(5);
        await harness.advance();

        // Dispose should cancel all timers
        await alice.transport.dispose();

        // Wait to ensure no timer callbacks fire after dispose
        await Future<void>.delayed(const Duration(milliseconds: 100));

        await harness.dispose();
      });

      test('stream subscriptions are cancelled on dispose', () async {
        final harness = BleTestHarness();
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);

        // Add listener and track if done was called
        var eventCount = 0;
        var doneCount = 0;
        alice.transport.peerEvents.listen(
          (_) => eventCount++,
          onDone: () => doneCount++,
        );

        final initialEventCount = eventCount;
        await alice.transport.dispose();
        await harness.advance();

        // Stream should be closed (onDone called)
        expect(doneCount, 1);

        // No new events should be received after dispose
        // (can't test by simulating since port is disposed)
        expect(eventCount, initialEventCount);

        await harness.dispose();
      });
    });
  });
}
