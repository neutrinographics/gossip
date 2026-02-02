import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';

import '../../support/test_network.dart';

void main() {
  group('Churn Sync', () {
    group('Churn and dynamic membership', () {
      test('node joins mid-sync and receives existing entries', () async {
        final network = await TestNetwork.create(['node1', 'node2', 'node3']);
        // Initially only node1 and node2 are connected
        await network.connect('node1', 'node2');

        final channelId = ChannelId('join-channel');
        final streamId = StreamId('data');

        // Setup channel on node1 and node2 only
        await network.setupChannel(
          channelId,
          streamId,
          members: ['node1', 'node2'],
        );

        await network['node1'].write(channelId, streamId, [1]);
        await network['node1'].write(channelId, streamId, [2]);

        // Start node1 and node2, sync between them
        await network['node1'].start();
        await network['node2'].start();
        await network.runRounds(5);

        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(2),
        );

        // Now node3 joins using the helper
        await network.joinChannel(
          'node3',
          channelId,
          streamId,
          existingMembers: ['node1', 'node2'],
        );

        // Connect node3 to the network and start
        await network.connect('node1', 'node3');
        await network.connect('node2', 'node3');
        await network['node3'].start();

        // Sync should bring node3 up to date
        await network.runRounds(10);

        expect(
          await network['node3'].entryCount(channelId, streamId),
          equals(2),
        );

        await network.dispose();
      });

      test('node rejoins with stale data and syncs missing entries', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('rejoin-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);
        await network['node1'].write(channelId, streamId, [1]);

        await network.startAll();
        await network.runRounds(5);

        // Both have entry 1
        expect(await network.hasConverged(channelId, streamId), isTrue);

        // Partition node2 (simulates going offline)
        network.partition('node2');

        // node1 writes more entries while node2 is offline
        await network['node1'].write(channelId, streamId, [2]);
        await network['node1'].write(channelId, streamId, [3]);
        await network.runRounds(5);

        // node2 still only has 1 entry
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(1),
        );

        // node2 comes back online
        network.heal('node2');
        await network.runRounds(10);

        // node2 should now have all 3 entries
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(3),
        );

        await network.dispose();
      });

      test('node writes while offline, syncs after reconnect', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('offline-write-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);
        await network.startAll();
        await network.runRounds(3);

        // Partition node2
        network.partition('node2');

        // Both write while partitioned
        await network['node1'].write(channelId, streamId, [1]);
        await network['node2'].write(channelId, streamId, [2]);

        await network.runRounds(5);

        // Each only has their own entry
        expect(
          await network['node1'].entryCount(channelId, streamId),
          equals(1),
        );
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(1),
        );

        // Reconnect
        network.heal('node2');
        await network.runRounds(10);

        // Both should have both entries
        expect(await network.hasConverged(channelId, streamId), isTrue);
        expect(
          await network['node1'].entryCount(channelId, streamId),
          equals(2),
        );

        await network.dispose();
      });

      test('sync after long offline period with many missed entries', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('long-offline-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);
        await network.startAll();
        await network.runRounds(3);

        // Partition node2
        network.partition('node2');

        // node1 writes many entries while node2 is offline
        for (var i = 0; i < 30; i++) {
          await network['node1'].write(channelId, streamId, [i]);
        }

        await network.runRounds(5);

        // node2 still has 0 entries
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(0),
        );

        // Reconnect after "long" offline period
        network.heal('node2');
        await network.runRounds(20);

        // node2 should have all 30 entries
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(30),
        );

        await network.dispose();
      });
    });

    group('Node restart and recovery', () {
      test('node recovers after stop and restart', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('restart-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);
        await network.startAll();

        // Initial sync
        await network['node1'].write(channelId, streamId, [1]);
        await network.runRounds(5);
        expect(await network.hasConverged(channelId, streamId), isTrue);

        // Stop node2
        await network['node2'].coordinator.stop();

        // node1 writes while node2 is stopped
        await network['node1'].write(channelId, streamId, [2]);
        await network.runRounds(5);

        // node2 hasn't received the new entry (it's stopped)
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(1),
        );

        // Restart node2
        await network['node2'].coordinator.start();
        await network.runRounds(10);

        // node2 should catch up after restart
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(2),
        );

        await network.dispose();
      });

      test('multiple nodes restart in sequence', () async {
        final network = await TestNetwork.create(['node1', 'node2', 'node3']);
        await network.connectAll();

        final channelId = ChannelId('multi-restart-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);
        await network.startAll();

        // Initial entry
        await network['node1'].write(channelId, streamId, [1]);
        await network.runRounds(10);
        expect(await network.hasConverged(channelId, streamId), isTrue);

        // Stop node2, write on node1
        await network['node2'].coordinator.stop();
        await network['node1'].write(channelId, streamId, [2]);
        await network.runRounds(5);

        // Stop node3, restart node2, write on node1
        await network['node3'].coordinator.stop();
        await network['node2'].coordinator.start();
        await network['node1'].write(channelId, streamId, [3]);
        await network.runRounds(10);

        // node2 should have caught up
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(3),
        );

        // Restart node3
        await network['node3'].coordinator.start();
        await network.runRounds(10);

        // node3 should catch up to all 3 entries
        expect(
          await network['node3'].entryCount(channelId, streamId),
          equals(3),
        );

        await network.dispose();
      });

      test('all nodes restart and recover', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('full-restart-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);
        await network.startAll();

        // Write entries
        await network['node1'].write(channelId, streamId, [1]);
        await network['node2'].write(channelId, streamId, [2]);
        await network.runRounds(10);
        expect(await network.hasConverged(channelId, streamId), isTrue);

        // Stop all nodes
        await network['node1'].coordinator.stop();
        await network['node2'].coordinator.stop();

        // Restart all nodes
        await network['node1'].coordinator.start();
        await network['node2'].coordinator.start();

        // Write new entries after restart
        await network['node1'].write(channelId, streamId, [3]);
        await network.runRounds(10);

        // Both should have all 3 entries
        expect(await network.hasConverged(channelId, streamId), isTrue);
        expect(
          await network['node1'].entryCount(channelId, streamId),
          equals(3),
        );

        await network.dispose();
      });

      test('node with stale clock recovers HLC state', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('hlc-recovery-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);

        // Advance node1's clock significantly
        await network['node1'].timePort.advance(Duration(seconds: 100));

        await network.startAll();

        // node1 writes with high HLC
        await network['node1'].write(channelId, streamId, [1]);
        await network.runRounds(5);

        // node2 receives and updates its HLC
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(1),
        );

        // node2 writes - should have HLC > node1's entry
        await network['node2'].write(channelId, streamId, [2]);
        await network.runRounds(5);

        final entries = await network['node1'].entries(channelId, streamId);
        entries.sort();

        // Verify causal ordering is maintained
        expect(entries[0].payload[0], equals(1));
        expect(entries[1].payload[0], equals(2));
        expect(
          entries[1].timestamp.compareTo(entries[0].timestamp),
          greaterThan(0),
        );

        await network.dispose();
      });
    });
  });
}
