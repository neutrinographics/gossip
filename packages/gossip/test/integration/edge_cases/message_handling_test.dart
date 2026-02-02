import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';

import '../../support/test_network.dart';

void main() {
  group('Message Handling', () {
    group('Idempotency and ordering', () {
      test('duplicate entries are handled idempotently', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('idempotent-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);
        await network['node1'].write(channelId, streamId, [1]);

        await network.startAll();
        // Run many rounds - this will send the same digests/deltas multiple times
        await network.runRounds(20);

        // Should still only have 1 entry (no duplicates)
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(1),
        );

        // Entries should be identical on both nodes
        final entries1 = await network['node1'].entries(channelId, streamId);
        final entries2 = await network['node2'].entries(channelId, streamId);

        expect(entries1.length, equals(1));
        expect(entries2.length, equals(1));
        expect(entries1[0].id, equals(entries2[0].id));

        await network.dispose();
      });

      test('out-of-order entry reception still converges', () async {
        // This tests that version vectors handle entries arriving
        // in different orders on different nodes
        final network = await TestNetwork.create(['node1', 'node2', 'node3']);
        await network.connectAll();

        final channelId = ChannelId('order-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);

        // Write entries in specific order
        await network['node1'].write(channelId, streamId, [1]);
        await network['node2'].write(channelId, streamId, [2]);
        await network['node3'].write(channelId, streamId, [3]);
        await network['node1'].write(channelId, streamId, [4]);
        await network['node2'].write(channelId, streamId, [5]);

        await network.startAll();
        await network.runRounds(15);

        // All nodes should have all 5 entries regardless of reception order
        expect(await network.hasConverged(channelId, streamId), isTrue);
        expect(
          await network['node1'].entryCount(channelId, streamId),
          equals(5),
        );

        await network.dispose();
      });
    });

    group('Message loss and recovery', () {
      test('intermittent partition recovers without data loss', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('intermittent-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);
        await network.startAll();

        // Write first batch
        await network['node1'].write(channelId, streamId, [1]);
        await network.runRounds(5);

        // Partition
        network.partition('node2');

        // Write during partition
        await network['node1'].write(channelId, streamId, [2]);
        await network.runRounds(3);

        // Heal briefly, then partition again
        network.heal('node2');
        await network.runRounds(2);

        network.partition('node2');

        // Write more during second partition
        await network['node1'].write(channelId, streamId, [3]);
        await network.runRounds(3);

        // Final heal
        network.heal('node2');
        await network.runRounds(10);

        // All entries should eventually sync
        expect(await network.hasConverged(channelId, streamId), isTrue);
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(3),
        );

        await network.dispose();
      });

      test('sync resumes correctly after long message gap', () async {
        final network = await TestNetwork.create(['node1', 'node2', 'node3']);
        await network.connectAll();

        final channelId = ChannelId('gap-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);
        await network.startAll();

        // Establish initial sync
        await network['node1'].write(channelId, streamId, [1]);
        await network.runRounds(5);

        expect(await network.hasConverged(channelId, streamId), isTrue);

        // Partition node3 completely
        network.partition('node3');

        // node1 and node2 continue to sync many entries
        for (var i = 2; i <= 20; i++) {
          if (i % 2 == 0) {
            await network['node1'].write(channelId, streamId, [i]);
          } else {
            await network['node2'].write(channelId, streamId, [i]);
          }
        }
        await network.runRounds(15);

        // node3 still only has entry 1
        expect(
          await network['node3'].entryCount(channelId, streamId),
          equals(1),
        );

        // node1 and node2 have all 20
        expect(
          await network['node1'].entryCount(channelId, streamId),
          equals(20),
        );

        // Restore node3
        network.heal('node3');
        await network.runRounds(20);

        // node3 should catch up completely
        expect(await network.hasConverged(channelId, streamId), isTrue);
        expect(
          await network['node3'].entryCount(channelId, streamId),
          equals(20),
        );

        await network.dispose();
      });

      test('asymmetric partition still allows eventual consistency', () async {
        // node1 can send to node2, but node2 cannot send to node1
        // (simulated by partitioning in one direction - not directly possible
        //  with current TestNetwork, but we can test similar scenarios)
        final network = await TestNetwork.create(['node1', 'node2', 'node3']);
        await network.connectAll();

        final channelId = ChannelId('asymmetric-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);
        await network.startAll();

        // Partition node1 from node2, but both connected to node3
        // node1 -- node3 -- node2
        network.partition('node1');
        network.partition('node2');

        // Write on both ends
        await network['node1'].write(channelId, streamId, [1]);
        await network['node2'].write(channelId, streamId, [2]);

        // Only heal connections to node3
        network.heal('node1');
        await network.runRounds(10);
        network.heal('node2');
        await network.runRounds(10);

        // node3 should have both entries
        expect(
          await network['node3'].entryCount(channelId, streamId),
          equals(2),
        );

        // Eventually all converge through node3 as relay
        await network.runRounds(10);
        expect(await network.hasConverged(channelId, streamId), isTrue);

        await network.dispose();
      });
    });

    group('Entry integrity', () {
      test('entries maintain integrity across sync', () async {
        final network = await TestNetwork.create(['node1', 'node2', 'node3']);
        await network.connectAll();

        final channelId = ChannelId('integrity-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);
        await network.startAll();

        // Write entries with specific payloads
        await network['node1'].write(channelId, streamId, [0x01, 0x02, 0x03]);
        await network['node2'].write(channelId, streamId, [0xFF, 0xFE, 0xFD]);
        await network['node3'].write(channelId, streamId, [0x00, 0x00, 0x00]);

        await network.runRounds(15);

        // Get entries from all nodes
        final entries1 = await network['node1'].entries(channelId, streamId);
        final entries2 = await network['node2'].entries(channelId, streamId);
        final entries3 = await network['node3'].entries(channelId, streamId);

        expect(entries1.length, equals(3));
        expect(entries2.length, equals(3));
        expect(entries3.length, equals(3));

        // Helper to find entry by author
        LogEntry findByAuthor(List<LogEntry> entries, String author) {
          return entries.firstWhere((e) => e.author.value == author);
        }

        // Verify payloads are identical on all nodes
        for (final authorName in ['node1', 'node2', 'node3']) {
          final e1 = findByAuthor(entries1, authorName);
          final e2 = findByAuthor(entries2, authorName);
          final e3 = findByAuthor(entries3, authorName);

          // Compare payloads
          expect(e1.payload, equals(e2.payload));
          expect(e2.payload, equals(e3.payload));

          // Compare timestamps
          expect(e1.timestamp, equals(e2.timestamp));
          expect(e2.timestamp, equals(e3.timestamp));

          // Compare sequences
          expect(e1.sequence, equals(e2.sequence));
          expect(e2.sequence, equals(e3.sequence));
        }

        await network.dispose();
      });

      test('large payloads sync correctly', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('large-payload-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);
        await network.startAll();

        // Create a moderately large payload (1KB)
        final largePayload = List.generate(1024, (i) => i % 256);
        await network['node1'].write(channelId, streamId, largePayload);

        await network.runRounds(10);

        final entries = await network['node2'].entries(channelId, streamId);
        expect(entries.length, equals(1));
        expect(entries[0].payload.toList(), equals(largePayload));

        await network.dispose();
      });

      test('empty payload syncs correctly', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('empty-payload-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);
        await network.startAll();

        // Write an empty payload
        await network['node1'].write(channelId, streamId, []);

        await network.runRounds(10);

        final entries = await network['node2'].entries(channelId, streamId);
        expect(entries.length, equals(1));
        expect(entries[0].payload.toList(), isEmpty);

        await network.dispose();
      });
    });
  });
}
