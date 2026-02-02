import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_ble/gossip_ble.dart';

import 'test_harness.dart';

/// Tests for BleTransport lifecycle edge cases and unusual usage patterns.
void main() {
  group('BleTransport Lifecycle Edge Cases', () {
    late BleTestHarness harness;

    setUp(() {
      harness = BleTestHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    group('advertising and discovery', () {
      test('start advertising twice is idempotent', () async {
        final alice = harness.createDevice('alice');

        await alice.startAdvertising();
        expect(alice.isAdvertising, isTrue);

        await alice.startAdvertising(); // Should not throw
        expect(alice.isAdvertising, isTrue);
      });

      test('stop advertising without start is safe', () async {
        final alice = harness.createDevice('alice');

        expect(alice.isAdvertising, isFalse);
        await alice.stopAdvertising(); // Should not throw
        expect(alice.isAdvertising, isFalse);
      });

      test('start discovery twice is idempotent', () async {
        final alice = harness.createDevice('alice');

        await alice.startDiscovery();
        expect(alice.isDiscovering, isTrue);

        await alice.startDiscovery(); // Should not throw
        expect(alice.isDiscovering, isTrue);
      });

      test('stop discovery without start is safe', () async {
        final alice = harness.createDevice('alice');

        expect(alice.isDiscovering, isFalse);
        await alice.stopDiscovery(); // Should not throw
        expect(alice.isDiscovering, isFalse);
      });

      test('advertising and discovery can be active simultaneously', () async {
        final alice = harness.createDevice('alice');

        await alice.startAdvertising();
        await alice.startDiscovery();

        expect(alice.isAdvertising, isTrue);
        expect(alice.isDiscovering, isTrue);

        await alice.stopAdvertising();
        expect(alice.isAdvertising, isFalse);
        expect(alice.isDiscovering, isTrue);

        await alice.stopDiscovery();
        expect(alice.isDiscovering, isFalse);
      });

      test('connection works regardless of advertising state', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        // Connect without advertising
        expect(alice.isAdvertising, isFalse);
        await alice.connectTo(bob);
        alice.expectConnectedTo(bob);
      });
    });

    group('message port usage', () {
      test('messagePort is available immediately', () async {
        final alice = harness.createDevice('alice');

        // MessagePort should exist even before any connections
        expect(alice.transport.messagePort, isNotNull);
      });

      test('send to unconnected peer fails gracefully', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        // Try to send without connecting
        await alice.sendToNodeId(bob.nodeId, [1, 2, 3]);

        alice.expectError<ConnectionNotFoundError>();
      });

      test('incoming stream works across multiple connections', () async {
        final [alice, bob, charlie] = harness.createDevices([
          'alice',
          'bob',
          'charlie',
        ]);

        await alice.connectTo(bob);
        await bob.sendTo(alice, [1]);

        await alice.connectTo(charlie);
        await charlie.sendTo(alice, [2]);

        expect(alice.receivedMessages.length, 2);
      });
    });

    group('concurrent access patterns', () {
      test('multiple listeners on peerEvents work correctly', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        final events1 = <PeerEvent>[];
        final events2 = <PeerEvent>[];

        alice.transport.peerEvents.listen(events1.add);
        alice.transport.peerEvents.listen(events2.add);

        await alice.connectTo(bob);

        // Both listeners should receive the event
        expect(events1.length, 1);
        expect(events2.length, 1);
      });

      test('multiple listeners on errors work correctly', () async {
        final alice = harness.createDevice('alice');

        final errors1 = <ConnectionError>[];
        final errors2 = <ConnectionError>[];

        alice.transport.errors.listen(errors1.add);
        alice.transport.errors.listen(errors2.add);

        await alice.sendToNodeId(NodeId('nonexistent'), [1]);
        await harness.advance();

        // Both listeners should receive the error
        expect(errors1.length, 1);
        expect(errors2.length, 1);
      });

      test('multiple listeners on incoming messages work correctly', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        final messages1 = <IncomingMessage>[];
        final messages2 = <IncomingMessage>[];

        alice.transport.messagePort.incoming.listen(messages1.add);
        alice.transport.messagePort.incoming.listen(messages2.add);

        await alice.connectTo(bob);
        await bob.sendTo(alice, [1, 2, 3]);

        // Both listeners should receive the message
        expect(messages1.length, 1);
        expect(messages2.length, 1);
      });
    });

    group('empty and boundary inputs', () {
      test('empty message payload is delivered', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);
        await alice.sendTo(bob, []);

        bob.expectReceivedFrom(alice, bytes: []);
      });

      test('single byte message is delivered', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        await alice.connectTo(bob);
        await alice.sendTo(bob, [42]);

        bob.expectReceivedFrom(alice, bytes: [42]);
      });
    });

    group('LocalNodeId handling', () {
      test('localNodeId is unique per transport', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);

        expect(alice.nodeId, isNot(equals(bob.nodeId)));
      });

      test('localNodeId is consistent throughout lifecycle', () async {
        final [alice, bob] = harness.createDevices(['alice', 'bob']);
        final initialNodeId = alice.nodeId;

        await alice.startAdvertising();
        expect(alice.nodeId, initialNodeId);

        await alice.connectTo(bob);
        expect(alice.nodeId, initialNodeId);

        await alice.disconnectFrom(bob);
        expect(alice.nodeId, initialNodeId);
      });
    });
  });
}
