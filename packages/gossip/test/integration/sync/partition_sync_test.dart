import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';

import '../../support/test_network.dart';

void main() {
  group('Partition Sync', () {
    group('Network partition and recovery', () {
      late TestNetwork network;

      setUp(() async {
        network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');
      });

      tearDown(() async {
        await network.dispose();
      });

      test('partition heals and sync resumes', () async {
        final channelId = ChannelId('heal-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);
        await network['node1'].write(channelId, streamId, [1]);

        await network.startAll();
        await network.runRounds(5);

        // Verify initial sync
        expect(await network.hasConverged(channelId, streamId), isTrue);

        // Partition the network
        network.partition('node2');
        await network['node1'].write(channelId, streamId, [2]);
        await network.runRounds(5);

        // node2 should not have the new entry
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(1),
        );

        // Heal the partition
        network.heal('node2');
        await network.runRounds(10);

        // Now both should have all entries
        expect(await network.hasConverged(channelId, streamId), isTrue);
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(2),
        );
      });

      test('entries written during partition sync after healing', () async {
        final channelId = ChannelId('partition-write-channel');
        final streamId = StreamId('events');

        await network.setupChannel(channelId, streamId);
        await network.startAll();

        // Partition node2
        network.partition('node2');

        // Both nodes write while partitioned
        await network['node1'].write(channelId, streamId, [1, 1]);
        await network['node2'].write(channelId, streamId, [2, 2]);

        await network.runRounds(5);

        // Each node only has their own entry
        expect(
          await network['node1'].entryCount(channelId, streamId),
          equals(1),
        );
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(1),
        );

        // Heal and sync
        network.heal('node2');
        await network.runRounds(10);

        // Both should now have both entries
        expect(await network.hasConverged(channelId, streamId), isTrue);
        expect(
          await network['node1'].entryCount(channelId, streamId),
          equals(2),
        );
      });
    });

    group('Multi-node partition scenarios', () {
      test('divergent writes during partition merge correctly', () async {
        final network = await TestNetwork.create(['node1', 'node2', 'node3']);
        await network.connectAll();

        final channelId = ChannelId('diverge-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);
        await network.startAll();
        await network.runRounds(3);

        // Partition into two groups: {node1} and {node2, node3}
        network.partition('node1');

        // node1 writes in isolation
        await network['node1'].write(channelId, streamId, [0x11]);
        await network['node1'].write(channelId, streamId, [0x12]);

        // node2 and node3 write together
        await network['node2'].write(channelId, streamId, [0x21]);
        await network['node3'].write(channelId, streamId, [0x31]);

        await network.runRounds(10);

        // node2 and node3 should have synced with each other
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(2),
        );
        expect(
          await network['node3'].entryCount(channelId, streamId),
          equals(2),
        );

        // node1 only has its own entries
        expect(
          await network['node1'].entryCount(channelId, streamId),
          equals(2),
        );

        // Heal partition
        network.heal('node1');
        await network.runRounds(15);

        // All nodes should have all 4 entries
        expect(await network.hasConverged(channelId, streamId), isTrue);
        expect(
          await network['node1'].entryCount(channelId, streamId),
          equals(4),
        );

        await network.dispose();
      });

      test('three-way partition heals and all entries merge', () async {
        final network = await TestNetwork.create(['node1', 'node2', 'node3']);
        await network.connectAll();

        final channelId = ChannelId('three-way-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);
        await network.startAll();
        await network.runRounds(3);

        // Partition all nodes from each other
        network.partitionNodes(['node1', 'node2', 'node3']);

        // Each writes in complete isolation
        await network['node1'].write(channelId, streamId, [1]);
        await network['node2'].write(channelId, streamId, [2]);
        await network['node3'].write(channelId, streamId, [3]);

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
        expect(
          await network['node3'].entryCount(channelId, streamId),
          equals(1),
        );

        // Heal all partitions
        network.healAll();
        await network.runRounds(20);

        // All should converge to 3 entries
        expect(await network.hasConverged(channelId, streamId), isTrue);
        expect(
          await network['node1'].entryCount(channelId, streamId),
          equals(3),
        );

        await network.dispose();
      });
    });
  });
}
