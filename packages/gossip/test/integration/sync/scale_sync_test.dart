import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';

import '../../support/test_network.dart';

void main() {
  group('Scale Sync', () {
    group('Edge cases', () {
      test('empty channel syncs without error', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('empty-channel');
        final streamId = StreamId('empty-stream');

        await network.setupChannel(channelId, streamId);
        // Don't write any entries

        await network.startAll();
        await network.runRounds(5);

        // Should complete without errors
        expect(await network.hasConverged(channelId, streamId), isTrue);
        expect(
          await network['node1'].entryCount(channelId, streamId),
          equals(0),
        );
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(0),
        );

        await network.dispose();
      });

      test('single node network operations work', () async {
        final network = await TestNetwork.create(['solo']);

        final channelId = ChannelId('solo-channel');
        final streamId = StreamId('solo-stream');

        await network['solo'].createChannel(channelId);
        await network['solo'].createStream(channelId, streamId);
        await network['solo'].write(channelId, streamId, [1, 2, 3]);

        await network['solo'].start();
        await network.runRounds(3);

        // Should work fine with no peers
        expect(
          await network['solo'].entryCount(channelId, streamId),
          equals(1),
        );
        expect(network['solo'].peers, isEmpty);

        await network.dispose();
      });

      test('large payload syncs correctly', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('large-payload-channel');
        final streamId = StreamId('large-data');

        await network.setupChannel(channelId, streamId);

        // Create a payload near the 32KB limit (30KB to be safe)
        final largePayload = Uint8List(30 * 1024);
        for (var i = 0; i < largePayload.length; i++) {
          largePayload[i] = i % 256;
        }

        final channel = network['node1'].coordinator.getChannel(channelId)!;
        final stream = await channel.getOrCreateStream(streamId);
        await stream.append(largePayload);

        await network.startAll();
        await network.runRounds(10);

        expect(await network.hasConverged(channelId, streamId), isTrue);

        final entries = await network['node2'].entries(channelId, streamId);
        expect(entries.length, equals(1));
        expect(entries[0].payload.length, equals(30 * 1024));

        await network.dispose();
      });

      test('many entries sync (stress test)', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('stress-channel');
        final streamId = StreamId('stress-stream');

        await network.setupChannel(channelId, streamId);

        // Write 50 entries
        for (var i = 0; i < 50; i++) {
          await network['node1'].write(channelId, streamId, [i]);
        }

        await network.startAll();
        await network.runRounds(20);

        expect(await network.hasConverged(channelId, streamId), isTrue);
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(50),
        );

        await network.dispose();
      });
    });

    group('Scale tests', () {
      test('maximum nodes (8) all sync correctly', () async {
        final nodeNames = List.generate(8, (i) => 'node$i');
        final network = await TestNetwork.create(nodeNames);
        await network.connectAll();

        final channelId = ChannelId('max-nodes-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);

        // Each node writes an entry
        for (var i = 0; i < 8; i++) {
          await network['node$i'].write(channelId, streamId, [i]);
        }

        await network.startAll();
        // More rounds needed for 8-node convergence
        await network.runRounds(30);

        // All nodes should have all 8 entries
        expect(await network.hasConverged(channelId, streamId), isTrue);
        for (final name in nodeNames) {
          expect(
            await network[name].entryCount(channelId, streamId),
            equals(8),
          );
        }

        await network.dispose();
      });

      test('payload at 32KB limit syncs correctly', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('max-payload-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);

        // Create payload just under 32KB (32768 bytes)
        // Account for protocol overhead
        final largePayload = List.generate(32000, (i) => i % 256);
        await network['node1'].write(channelId, streamId, largePayload);

        await network.startAll();
        await network.runRounds(10);

        expect(await network.hasConverged(channelId, streamId), isTrue);

        final entries = await network['node2'].entries(channelId, streamId);
        expect(entries.length, equals(1));
        expect(entries[0].payload.length, equals(32000));

        await network.dispose();
      });

      test('100 entries from single node sync correctly', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('hundred-entries-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);

        // Write 100 entries
        for (var i = 0; i < 100; i++) {
          await network['node1'].write(channelId, streamId, [i % 256]);
        }

        await network.startAll();
        await network.runRounds(30);

        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(100),
        );

        await network.dispose();
      });

      test('entries from all 8 nodes with concurrent writes', () async {
        final nodeNames = List.generate(8, (i) => 'node$i');
        final network = await TestNetwork.create(nodeNames);
        await network.connectAll();

        final channelId = ChannelId('concurrent-8-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);

        // Each node writes 5 entries (40 total)
        for (var i = 0; i < 8; i++) {
          for (var j = 0; j < 5; j++) {
            await network['node$i'].write(channelId, streamId, [i * 10 + j]);
          }
        }

        await network.startAll();
        await network.runRounds(40);

        // All nodes should have all 40 entries
        expect(await network.hasConverged(channelId, streamId), isTrue);
        for (final name in nodeNames) {
          expect(
            await network[name].entryCount(channelId, streamId),
            equals(40),
          );
        }

        await network.dispose();
      });
    });
  });
}
