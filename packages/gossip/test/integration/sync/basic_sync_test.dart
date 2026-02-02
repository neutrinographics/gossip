import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';

import '../../support/test_network.dart';

void main() {
  group('Basic Sync', () {
    group('Two node sync', () {
      late TestNetwork network;

      setUp(() async {
        network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');
      });

      tearDown(() async {
        await network.dispose();
      });

      test('two coordinators can create the same channel', () async {
        final channelId = ChannelId('shared-channel');

        await network['node1'].createChannel(channelId);
        await network['node2'].createChannel(channelId);

        expect(network['node1'].coordinator.getChannel(channelId), isNotNull);
        expect(network['node2'].coordinator.getChannel(channelId), isNotNull);
      });

      test('entries written on node1 sync to node2', () async {
        final channelId = ChannelId('sync-channel');
        final streamId = StreamId('messages');

        await network.setupChannel(channelId, streamId);

        await network.startAll();
        await network['node1'].write(channelId, streamId, [1, 2, 3]);
        await network['node1'].write(channelId, streamId, [4, 5, 6]);

        expect(
          await network.entryCounts(channelId, streamId),
          equals({'node1': 2, 'node2': 0}),
        );

        await network.runRounds(5);

        expect(await network.hasConverged(channelId, streamId), isTrue);
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(2),
        );
      });

      test('bidirectional sync - entries from both nodes converge', () async {
        final channelId = ChannelId('bidirectional-channel');
        final streamId = StreamId('chat');

        await network.setupChannel(channelId, streamId);

        await network['node1'].write(channelId, streamId, [1, 1, 1]);
        await network['node2'].write(channelId, streamId, [2, 2, 2]);

        expect(
          await network.entryCounts(channelId, streamId),
          equals({'node1': 1, 'node2': 1}),
        );

        await network.startAll();
        await network.runRounds(5);

        expect(await network.hasConverged(channelId, streamId), isTrue);
        expect(
          await network['node1'].entryCount(channelId, streamId),
          equals(2),
        );
      });
    });

    group('Three node sync', () {
      late TestNetwork network;

      setUp(() async {
        network = await TestNetwork.create(['node1', 'node2', 'node3']);
        await network.connect('node1', 'node2');
        await network.connect('node2', 'node3');
      });

      tearDown(() async {
        await network.dispose();
      });

      test('entries propagate through intermediate node', () async {
        final channelId = ChannelId('three-node-channel');
        final streamId = StreamId('messages');

        await network.setupChannel(channelId, streamId);

        // Write entries on edge nodes (not node2)
        await network['node1'].write(channelId, streamId, [1, 1, 1]);
        await network['node3'].write(channelId, streamId, [3, 3, 3]);

        expect(
          await network.entryCounts(channelId, streamId),
          equals({'node1': 1, 'node2': 0, 'node3': 1}),
        );

        await network.startAll();
        await network.runRounds(10);

        // All nodes converged with 2 entries each
        expect(await network.hasConverged(channelId, streamId), isTrue);
        expect(
          await network['node1'].entryCount(channelId, streamId),
          equals(2),
        );
      });

      test('all three nodes writing entries converge', () async {
        final channelId = ChannelId('convergence-channel');
        final streamId = StreamId('events');

        await network.setupChannel(channelId, streamId);

        // Each node writes an entry
        await network['node1'].write(channelId, streamId, [1]);
        await network['node2'].write(channelId, streamId, [2]);
        await network['node3'].write(channelId, streamId, [3]);

        await network.startAll();
        await network.runRounds(10);

        expect(await network.hasConverged(channelId, streamId), isTrue);
        expect(
          await network['node1'].entryCount(channelId, streamId),
          equals(3),
        );
      });
    });

    group('Concurrent and rapid operations', () {
      test('concurrent writes from multiple nodes converge', () async {
        final network = await TestNetwork.create([
          'node1',
          'node2',
          'node3',
          'node4',
        ]);
        await network.connectAll();

        final channelId = ChannelId('concurrent-channel');
        final streamId = StreamId('writes');

        await network.setupChannel(channelId, streamId);
        await network.startAll();

        // All nodes write simultaneously (before any sync)
        await network['node1'].write(channelId, streamId, [1]);
        await network['node2'].write(channelId, streamId, [2]);
        await network['node3'].write(channelId, streamId, [3]);
        await network['node4'].write(channelId, streamId, [4]);

        await network.runRounds(15);

        // All nodes should converge to 4 entries
        expect(await network.hasConverged(channelId, streamId), isTrue);
        expect(
          await network['node1'].entryCount(channelId, streamId),
          equals(4),
        );

        await network.dispose();
      });

      test('rapid sequential writes all sync', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('rapid-channel');
        final streamId = StreamId('burst');

        await network.setupChannel(channelId, streamId);
        await network.startAll();

        // Write many entries rapidly
        for (var i = 0; i < 20; i++) {
          await network['node1'].write(channelId, streamId, [i]);
        }

        await network.runRounds(15);

        expect(await network.hasConverged(channelId, streamId), isTrue);
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(20),
        );

        await network.dispose();
      });

      test('rapid alternating writes from multiple nodes converge', () async {
        final network = await TestNetwork.create(['node1', 'node2', 'node3']);
        await network.connectAll();

        final channelId = ChannelId('alternating-channel');
        final streamId = StreamId('interleaved');

        await network.setupChannel(channelId, streamId);
        await network.startAll();

        // Interleaved writes from different nodes
        for (var i = 0; i < 10; i++) {
          await network['node1'].write(channelId, streamId, [0x10 + i]);
          await network['node2'].write(channelId, streamId, [0x20 + i]);
          await network['node3'].write(channelId, streamId, [0x30 + i]);
          // Run a round between each batch to simulate real-time interleaving
          await network.runRounds(1);
        }

        await network.runRounds(15);

        // All nodes should have all 30 entries (10 from each)
        expect(await network.hasConverged(channelId, streamId), isTrue);
        expect(
          await network['node1'].entryCount(channelId, streamId),
          equals(30),
        );

        // Verify each node's entries have correct sequence numbers
        final entries = await network['node1'].entries(channelId, streamId);
        final node1Entries = entries.where(
          (e) => e.author == network['node1'].id,
        );
        final node2Entries = entries.where(
          (e) => e.author == network['node2'].id,
        );
        final node3Entries = entries.where(
          (e) => e.author == network['node3'].id,
        );

        expect(node1Entries.length, equals(10));
        expect(node2Entries.length, equals(10));
        expect(node3Entries.length, equals(10));

        await network.dispose();
      });
    });

    group('Multiple streams', () {
      late TestNetwork network;

      setUp(() async {
        network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');
      });

      tearDown(() async {
        await network.dispose();
      });

      test('multiple streams in same channel sync independently', () async {
        final channelId = ChannelId('multi-stream-channel');
        final stream1 = StreamId('stream1');
        final stream2 = StreamId('stream2');

        // Setup channel with first stream
        await network.setupChannel(channelId, stream1);

        // Create second stream on both nodes
        await network['node1'].createStream(channelId, stream2);
        await network['node2'].createStream(channelId, stream2);

        // Write to different streams
        await network['node1'].write(channelId, stream1, [1, 1]);
        await network['node2'].write(channelId, stream2, [2, 2]);

        await network.startAll();
        await network.runRounds(10);

        // Both streams should sync
        expect(await network.hasConverged(channelId, stream1), isTrue);
        expect(await network.hasConverged(channelId, stream2), isTrue);
        expect(
          await network['node2'].entryCount(channelId, stream1),
          equals(1),
        );
        expect(
          await network['node1'].entryCount(channelId, stream2),
          equals(1),
        );
      });

      test('stream created after entries exist syncs correctly', () async {
        final channelId = ChannelId('late-stream-channel');
        final streamId = StreamId('late-stream');

        // node1 creates channel and stream, writes entries
        await network['node1'].createChannel(channelId);
        await network['node1'].createStream(channelId, streamId);
        await network['node1'].addMember(channelId, network['node2'].id);
        await network['node1'].write(channelId, streamId, [1]);
        await network['node1'].write(channelId, streamId, [2]);

        await network.startAll();
        await network.runRounds(5);

        // node2 creates channel and stream AFTER entries exist
        await network['node2'].createChannel(channelId);
        await network['node2'].createStream(channelId, streamId);
        await network['node2'].addMember(channelId, network['node1'].id);

        await network.runRounds(10);

        // node2 should receive the entries
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(2),
        );
      });
    });

    group('Multi-channel sync', () {
      test('multiple channels sync simultaneously', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channel1 = ChannelId('channel-1');
        final channel2 = ChannelId('channel-2');
        final channel3 = ChannelId('channel-3');
        final streamId = StreamId('data');

        // Setup all three channels on both nodes
        for (final channelId in [channel1, channel2, channel3]) {
          await network['node1'].createChannel(channelId);
          await network['node1'].createStream(channelId, streamId);
          await network['node1'].addMember(channelId, network['node2'].id);

          await network['node2'].createChannel(channelId);
          await network['node2'].createStream(channelId, streamId);
          await network['node2'].addMember(channelId, network['node1'].id);
        }

        // Write to different channels from different nodes
        await network['node1'].write(channel1, streamId, [0x11]);
        await network['node1'].write(channel1, streamId, [0x12]);
        await network['node2'].write(channel2, streamId, [0x21]);
        await network['node1'].write(channel3, streamId, [0x31]);
        await network['node2'].write(channel3, streamId, [0x32]);

        await network.startAll();
        await network.runRounds(15);

        // All channels should converge independently
        expect(await network.hasConverged(channel1, streamId), isTrue);
        expect(await network.hasConverged(channel2, streamId), isTrue);
        expect(await network.hasConverged(channel3, streamId), isTrue);

        expect(
          await network['node2'].entryCount(channel1, streamId),
          equals(2),
        );
        expect(
          await network['node1'].entryCount(channel2, streamId),
          equals(1),
        );
        expect(
          await network['node1'].entryCount(channel3, streamId),
          equals(2),
        );

        await network.dispose();
      });

      test('different membership per channel syncs correctly', () async {
        final network = await TestNetwork.create(['node1', 'node2', 'node3']);
        await network.connectAll();

        final channelAB = ChannelId('channel-ab'); // node1 and node2 only
        final channelBC = ChannelId('channel-bc'); // node2 and node3 only
        final channelAll = ChannelId('channel-all'); // all nodes
        final streamId = StreamId('data');

        // Channel AB: node1 and node2
        await network['node1'].createChannel(channelAB);
        await network['node1'].createStream(channelAB, streamId);
        await network['node1'].addMember(channelAB, network['node2'].id);
        await network['node2'].createChannel(channelAB);
        await network['node2'].createStream(channelAB, streamId);
        await network['node2'].addMember(channelAB, network['node1'].id);

        // Channel BC: node2 and node3
        await network['node2'].createChannel(channelBC);
        await network['node2'].createStream(channelBC, streamId);
        await network['node2'].addMember(channelBC, network['node3'].id);
        await network['node3'].createChannel(channelBC);
        await network['node3'].createStream(channelBC, streamId);
        await network['node3'].addMember(channelBC, network['node2'].id);

        // Channel All: all three nodes
        await network.setupChannel(channelAll, streamId);

        // Write to each channel
        await network['node1'].write(channelAB, streamId, [0xAB]);
        await network['node2'].write(channelBC, streamId, [0xBC]);
        await network['node1'].write(channelAll, streamId, [0x01]);
        await network['node2'].write(channelAll, streamId, [0x02]);
        await network['node3'].write(channelAll, streamId, [0x03]);

        await network.startAll();
        await network.runRounds(15);

        // Channel AB: node1 and node2 have entry, node3 doesn't have channel
        expect(
          await network['node1'].entryCount(channelAB, streamId),
          equals(1),
        );
        expect(
          await network['node2'].entryCount(channelAB, streamId),
          equals(1),
        );
        expect(network['node3'].coordinator.getChannel(channelAB), isNull);

        // Channel BC: node2 and node3 have entry, node1 doesn't have channel
        expect(network['node1'].coordinator.getChannel(channelBC), isNull);
        expect(
          await network['node2'].entryCount(channelBC, streamId),
          equals(1),
        );
        expect(
          await network['node3'].entryCount(channelBC, streamId),
          equals(1),
        );

        // Channel All: all nodes have all 3 entries
        expect(await network.hasConverged(channelAll, streamId), isTrue);
        expect(
          await network['node1'].entryCount(channelAll, streamId),
          equals(3),
        );

        await network.dispose();
      });

      test('high channel count syncs correctly', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final streamId = StreamId('data');
        final channelCount = 10;

        // Create many channels
        for (var i = 0; i < channelCount; i++) {
          final channelId = ChannelId('channel-$i');
          await network['node1'].createChannel(channelId);
          await network['node1'].createStream(channelId, streamId);
          await network['node1'].addMember(channelId, network['node2'].id);

          await network['node2'].createChannel(channelId);
          await network['node2'].createStream(channelId, streamId);
          await network['node2'].addMember(channelId, network['node1'].id);

          // Write an entry to each channel
          await network['node1'].write(channelId, streamId, [i]);
        }

        await network.startAll();
        await network.runRounds(20);

        // All channels should have synced
        for (var i = 0; i < channelCount; i++) {
          final channelId = ChannelId('channel-$i');
          expect(
            await network['node2'].entryCount(channelId, streamId),
            equals(1),
            reason: 'Channel $i should have synced',
          );
        }

        await network.dispose();
      });
    });
  });
}
