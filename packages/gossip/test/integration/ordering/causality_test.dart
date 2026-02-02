import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';

import '../../support/test_network.dart';

void main() {
  group('Causality and Ordering', () {
    group('HLC timestamp ordering', () {
      test('HLC timestamps preserve causal ordering across sync', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('causality-channel');
        final streamId = StreamId('events');

        await network.setupChannel(channelId, streamId);
        await network.startAll();

        // node1 writes first entry
        await network['node1'].write(channelId, streamId, [1]);
        await network.runRounds(5);

        // node2 sees entry, then writes (should have higher HLC)
        await network['node2'].write(channelId, streamId, [2]);
        await network.runRounds(5);

        // node1 sees node2's entry, then writes (should have even higher HLC)
        await network['node1'].write(channelId, streamId, [3]);
        await network.runRounds(5);

        // Get all entries from node2 and verify causal ordering
        final entries = await network['node2'].entries(channelId, streamId);
        expect(entries.length, equals(3));

        // Sort by HLC timestamp
        entries.sort((a, b) => a.timestamp.compareTo(b.timestamp));

        // Verify payloads are in causal order
        expect(entries[0].payload[0], equals(1));
        expect(entries[1].payload[0], equals(2));
        expect(entries[2].payload[0], equals(3));

        // Verify HLC timestamps are strictly increasing
        expect(
          entries[1].timestamp.compareTo(entries[0].timestamp),
          greaterThan(0),
        );
        expect(
          entries[2].timestamp.compareTo(entries[1].timestamp),
          greaterThan(0),
        );

        await network.dispose();
      });

      test('concurrent writes at different times have distinct HLCs', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('concurrent-hlc-channel');
        final streamId = StreamId('events');

        await network.setupChannel(channelId, streamId);

        // Advance node1's time slightly so writes have different timestamps
        await network['node1'].timePort.advance(Duration(milliseconds: 100));

        // Both nodes write before any sync (concurrent but at different times)
        await network['node1'].write(channelId, streamId, [0xA1]);
        await network['node2'].write(channelId, streamId, [0xB1]);

        await network.startAll();
        await network.runRounds(10);

        // Get all entries
        final entries = await network['node1'].entries(channelId, streamId);
        expect(entries.length, equals(2));

        final entry1 = entries.firstWhere(
          (e) => e.author == network['node1'].id,
        );
        final entry2 = entries.firstWhere(
          (e) => e.author == network['node2'].id,
        );

        // Both entries should have valid HLCs
        expect(entry1.timestamp.physicalMs, greaterThanOrEqualTo(0));
        expect(entry2.timestamp.physicalMs, greaterThanOrEqualTo(0));

        // The HLCs should be distinct because they were written at different times
        expect(entry1.timestamp == entry2.timestamp, isFalse);

        // node1's entry should have higher physical time since we advanced its clock
        expect(
          entry1.timestamp.physicalMs,
          greaterThan(entry2.timestamp.physicalMs),
        );

        await network.dispose();
      });

      test('later writes have higher HLC due to time advancement', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('hlc-update-channel');
        final streamId = StreamId('events');

        await network.setupChannel(channelId, streamId);
        await network.startAll();

        // node1 writes first entry
        await network['node1'].write(channelId, streamId, [1]);

        // Sync and advance time - runRounds advances time on all nodes
        await network.runRounds(5);

        // node2 writes after time has advanced - should have higher physical time
        await network['node2'].write(channelId, streamId, [2]);
        await network.runRounds(5);

        final entries = await network['node1'].entries(channelId, streamId);
        expect(entries.length, equals(2));

        final entry1 = entries.firstWhere(
          (e) => e.author == network['node1'].id,
        );
        final entry2 = entries.firstWhere(
          (e) => e.author == network['node2'].id,
        );

        // node2's entry should have higher HLC because it was written later
        // (after runRounds advanced node2's clock)
        expect(entry2.timestamp.compareTo(entry1.timestamp), greaterThan(0));

        await network.dispose();
      });

      test('HLC updates on receive ensures causal ordering', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('hlc-receive-channel');
        final streamId = StreamId('events');

        await network.setupChannel(channelId, streamId);

        // Advance node1's clock way ahead (simulating clock skew)
        await network['node1'].timePort.advance(Duration(seconds: 100));

        // node1 writes with high HLC (physicalMs = 100000)
        await network['node1'].write(channelId, streamId, [1]);

        // node2's clock is still at 0, but after receiving node1's entry,
        // its HLC should be updated
        await network.startAll();
        await network.runRounds(5);

        // Verify node2 received the entry
        final entriesBefore = await network['node2'].entries(
          channelId,
          streamId,
        );
        expect(entriesBefore.length, equals(1));

        // node2 writes - even though its physical clock is behind,
        // the HLC should be higher than node1's entry because
        // hlcClock.receive() was called when the entry was synced
        await network['node2'].write(channelId, streamId, [2]);
        await network.runRounds(5);

        final entries = await network['node1'].entries(channelId, streamId);
        expect(entries.length, equals(2));

        final entry1 = entries.firstWhere((e) => e.payload[0] == 1);
        final entry2 = entries.firstWhere((e) => e.payload[0] == 2);

        // node2's entry must have HLC > node1's entry
        // This proves that receiving entries updates the local HLC clock
        expect(
          entry2.timestamp.compareTo(entry1.timestamp),
          greaterThan(0),
          reason:
              'Entry written after receiving should have higher HLC. '
              'entry1: ${entry1.timestamp}, entry2: ${entry2.timestamp}',
        );

        await network.dispose();
      });

      test(
        'entries sorted by HLC are globally consistent across nodes',
        () async {
          final network = await TestNetwork.create(['node1', 'node2', 'node3']);
          await network.connectAll();

          final channelId = ChannelId('global-sort-channel');
          final streamId = StreamId('events');

          await network.setupChannel(channelId, streamId);
          await network.startAll();

          // Create a causal chain: node1 -> node2 -> node3 -> node1
          // Each write happens after sync, so physical time advances
          await network['node1'].write(channelId, streamId, [1]);
          await network.runRounds(10);

          await network['node2'].write(channelId, streamId, [2]);
          await network.runRounds(10);

          await network['node3'].write(channelId, streamId, [3]);
          await network.runRounds(10);

          await network['node1'].write(channelId, streamId, [4]);
          await network.runRounds(10);

          // Get entries from all nodes and sort by HLC
          final entries1 = await network['node1'].entries(channelId, streamId);
          final entries2 = await network['node2'].entries(channelId, streamId);
          final entries3 = await network['node3'].entries(channelId, streamId);

          // All nodes should have all 4 entries
          expect(entries1.length, equals(4));
          expect(entries2.length, equals(4));
          expect(entries3.length, equals(4));

          entries1.sort((a, b) => a.timestamp.compareTo(b.timestamp));
          entries2.sort((a, b) => a.timestamp.compareTo(b.timestamp));
          entries3.sort((a, b) => a.timestamp.compareTo(b.timestamp));

          // All nodes should have same order when sorted by HLC
          final order1 = entries1.map((e) => e.payload[0]).toList();
          final order2 = entries2.map((e) => e.payload[0]).toList();
          final order3 = entries3.map((e) => e.payload[0]).toList();

          expect(order1, equals([1, 2, 3, 4]));
          expect(order2, equals([1, 2, 3, 4]));
          expect(order3, equals([1, 2, 3, 4]));

          await network.dispose();
        },
      );

      test('HLC physical time advances with simulated time', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('time-advance-channel');
        final streamId = StreamId('events');

        await network.setupChannel(channelId, streamId);
        await network.startAll();

        // Write first entry
        await network['node1'].write(channelId, streamId, [1]);

        // Advance time significantly
        await network['node1'].timePort.advance(Duration(seconds: 5));

        // Write second entry
        await network['node1'].write(channelId, streamId, [2]);

        await network.runRounds(5);

        final entries = await network['node1'].entries(channelId, streamId);
        entries.sort((a, b) => a.sequence.compareTo(b.sequence));

        // Second entry should have higher physical time
        expect(
          entries[1].timestamp.physicalMs,
          greaterThan(entries[0].timestamp.physicalMs),
        );

        // The difference should be approximately 5 seconds (5000ms)
        final timeDiff =
            entries[1].timestamp.physicalMs - entries[0].timestamp.physicalMs;
        expect(timeDiff, greaterThanOrEqualTo(5000));

        await network.dispose();
      });

      test('clock skew is reflected in HLC physical timestamps', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('clock-skew-channel');
        final streamId = StreamId('events');

        await network.setupChannel(channelId, streamId);

        // Advance node2's clock ahead (simulates clock skew)
        await network['node2'].timePort.advance(Duration(seconds: 10));

        // node2 writes with "future" time
        await network['node2'].write(channelId, streamId, [2]);

        // node1 writes with "past" time (no advancement yet)
        await network['node1'].write(channelId, streamId, [1]);

        await network.startAll();
        await network.runRounds(10);

        final entries = await network['node1'].entries(channelId, streamId);
        expect(entries.length, equals(2));

        final entryFrom1 = entries.firstWhere((e) => e.payload[0] == 1);
        final entryFrom2 = entries.firstWhere((e) => e.payload[0] == 2);

        // node2's entry should have higher physical time due to clock skew
        expect(
          entryFrom2.timestamp.physicalMs,
          greaterThan(entryFrom1.timestamp.physicalMs),
        );

        // The difference should reflect the 10 second skew
        final skew =
            entryFrom2.timestamp.physicalMs - entryFrom1.timestamp.physicalMs;
        expect(skew, greaterThanOrEqualTo(10000));

        await network.dispose();
      });

      test(
        'entries with identical HLCs are sorted deterministically by author',
        () async {
          // This tests the tiebreaker behavior when two entries have the exact
          // same HLC timestamp (can happen with concurrent writes at same time)
          final network = await TestNetwork.create(['alice', 'bob', 'charlie']);
          await network.connectAll();

          final channelId = ChannelId('identical-hlc-channel');
          final streamId = StreamId('events');

          await network.setupChannel(channelId, streamId);

          // All nodes write at the exact same simulated time (time=0)
          // This creates entries with identical HLCs: Hlc(0, 0)
          await network['alice'].write(channelId, streamId, [0xAA]);
          await network['bob'].write(channelId, streamId, [0xBB]);
          await network['charlie'].write(channelId, streamId, [0xCC]);

          await network.startAll();
          await network.runRounds(15);

          // Get entries from all nodes and sort
          final entries1 = await network['alice'].entries(channelId, streamId);
          final entries2 = await network['bob'].entries(channelId, streamId);
          final entries3 = await network['charlie'].entries(
            channelId,
            streamId,
          );

          expect(entries1.length, equals(3));
          expect(entries2.length, equals(3));
          expect(entries3.length, equals(3));

          // Sort using LogEntry.compareTo (which includes author tiebreaker)
          entries1.sort();
          entries2.sort();
          entries3.sort();

          // All nodes should produce the same order
          final order1 = entries1.map((e) => e.author.value).toList();
          final order2 = entries2.map((e) => e.author.value).toList();
          final order3 = entries3.map((e) => e.author.value).toList();

          expect(order1, equals(order2));
          expect(order2, equals(order3));

          // The order should be alphabetical by author (alice < bob < charlie)
          expect(order1, equals(['alice', 'bob', 'charlie']));

          await network.dispose();
        },
      );
    });

    group('HLC overflow handling', () {
      test('rapid writes increment logical counter without overflow', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('rapid-write-channel');
        final streamId = StreamId('events');

        await network.setupChannel(channelId, streamId);
        await network.startAll();

        // Write many entries without advancing time
        // This tests the logical counter incrementing
        for (var i = 0; i < 100; i++) {
          await network['node1'].write(channelId, streamId, [i]);
        }

        await network.runRounds(15);

        final entries = await network['node2'].entries(channelId, streamId);
        expect(entries.length, equals(100));

        // Sort by HLC
        entries.sort();

        // All entries should have unique HLCs with increasing logical counters
        // since they were written at the same physical time
        for (var i = 1; i < entries.length; i++) {
          expect(
            entries[i].timestamp.compareTo(entries[i - 1].timestamp),
            greaterThan(0),
            reason: 'Entry $i should have higher HLC than entry ${i - 1}',
          );
        }

        // Logical counters should be incrementing consecutively
        final firstLogical = entries[0].timestamp.logical;
        for (var i = 0; i < entries.length; i++) {
          expect(entries[i].timestamp.logical, equals(firstLogical + i));
        }

        await network.dispose();
      });
    });

    group('Sequence number ordering', () {
      test(
        'sequential writes from same node have increasing sequence numbers',
        () async {
          final network = await TestNetwork.create(['node1', 'node2']);
          await network.connect('node1', 'node2');

          final channelId = ChannelId('sequence-channel');
          final streamId = StreamId('events');

          await network.setupChannel(channelId, streamId);
          await network.startAll();

          // node1 writes multiple entries
          await network['node1'].write(channelId, streamId, [1]);
          await network['node1'].write(channelId, streamId, [2]);
          await network['node1'].write(channelId, streamId, [3]);

          await network.runRounds(5);

          // Get entries and verify sequence numbers
          final entries = await network['node2'].entries(channelId, streamId);
          expect(entries.length, equals(3));

          // Filter to node1's entries and sort by sequence
          final node1Entries =
              entries.where((e) => e.author == network['node1'].id).toList()
                ..sort((a, b) => a.sequence.compareTo(b.sequence));

          expect(node1Entries[0].sequence, equals(1));
          expect(node1Entries[1].sequence, equals(2));
          expect(node1Entries[2].sequence, equals(3));

          // Verify payloads match sequence order
          expect(node1Entries[0].payload[0], equals(1));
          expect(node1Entries[1].payload[0], equals(2));
          expect(node1Entries[2].payload[0], equals(3));

          await network.dispose();
        },
      );

      test(
        'concurrent writes have independent sequence numbers per author',
        () async {
          final network = await TestNetwork.create(['node1', 'node2']);
          await network.connect('node1', 'node2');

          final channelId = ChannelId('concurrent-seq-channel');
          final streamId = StreamId('events');

          await network.setupChannel(channelId, streamId);

          // Both nodes write before sync starts (concurrent)
          await network['node1'].write(channelId, streamId, [0xA1]);
          await network['node1'].write(channelId, streamId, [0xA2]);
          await network['node2'].write(channelId, streamId, [0xB1]);
          await network['node2'].write(channelId, streamId, [0xB2]);

          await network.startAll();
          await network.runRounds(10);

          // Get all entries from node1
          final entries = await network['node1'].entries(channelId, streamId);
          expect(entries.length, equals(4));

          // Check node1's sequence numbers
          final node1Entries = entries
              .where((e) => e.author == network['node1'].id)
              .toList();
          expect(node1Entries.map((e) => e.sequence).toSet(), equals({1, 2}));

          // Check node2's sequence numbers (independent)
          final node2Entries = entries
              .where((e) => e.author == network['node2'].id)
              .toList();
          expect(node2Entries.map((e) => e.sequence).toSet(), equals({1, 2}));

          await network.dispose();
        },
      );

      test('sequence numbers are contiguous with no gaps', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('no-gaps-channel');
        final streamId = StreamId('events');

        await network.setupChannel(channelId, streamId);
        await network.startAll();

        // Write many entries
        for (var i = 0; i < 20; i++) {
          await network['node1'].write(channelId, streamId, [i]);
        }

        await network.runRounds(10);

        final entries = await network['node1'].entries(channelId, streamId);
        expect(entries.length, equals(20));

        // Get all sequence numbers and sort
        final sequences = entries.map((e) => e.sequence).toList()..sort();

        // Verify contiguous: 1, 2, 3, ..., 20
        for (var i = 0; i < 20; i++) {
          expect(sequences[i], equals(i + 1));
        }

        await network.dispose();
      });

      test(
        'multiple streams have independent sequence counters per stream',
        () async {
          final network = await TestNetwork.create(['node1', 'node2']);
          await network.connect('node1', 'node2');

          final channelId = ChannelId('multi-stream-seq-channel');
          final stream1 = StreamId('stream1');
          final stream2 = StreamId('stream2');

          // Setup channel with two streams
          await network.setupChannel(channelId, stream1);
          await network['node1'].createStream(channelId, stream2);
          await network['node2'].createStream(channelId, stream2);

          await network.startAll();

          // Write to stream1
          await network['node1'].write(channelId, stream1, [0x11]);
          await network['node1'].write(channelId, stream1, [0x12]);
          await network['node1'].write(channelId, stream1, [0x13]);

          // Write to stream2 (should have independent sequence)
          await network['node1'].write(channelId, stream2, [0x21]);
          await network['node1'].write(channelId, stream2, [0x22]);

          await network.runRounds(10);

          // Check stream1 sequences
          final entries1 = await network['node2'].entries(channelId, stream1);
          final sequences1 = entries1.map((e) => e.sequence).toList()..sort();
          expect(sequences1, equals([1, 2, 3]));

          // Check stream2 sequences (independent, starts at 1)
          final entries2 = await network['node2'].entries(channelId, stream2);
          final sequences2 = entries2.map((e) => e.sequence).toList()..sort();
          expect(sequences2, equals([1, 2]));

          await network.dispose();
        },
      );

      test('sequence numbers persist correctly across sync', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('persist-seq-channel');
        final streamId = StreamId('events');

        await network.setupChannel(channelId, streamId);
        await network.startAll();

        // node1 writes entries
        await network['node1'].write(channelId, streamId, [1]);
        await network['node1'].write(channelId, streamId, [2]);
        await network.runRounds(5);

        // node2 writes entries (its own sequence)
        await network['node2'].write(channelId, streamId, [3]);
        await network['node2'].write(channelId, streamId, [4]);
        await network.runRounds(5);

        // Verify sequences on both nodes
        final entries1 = await network['node1'].entries(channelId, streamId);
        final entries2 = await network['node2'].entries(channelId, streamId);

        // Both should have all 4 entries
        expect(entries1.length, equals(4));
        expect(entries2.length, equals(4));

        // Check that sequences match between nodes for same author
        for (final e1 in entries1) {
          final matching = entries2.firstWhere(
            (e2) => e2.author == e1.author && e2.sequence == e1.sequence,
          );
          expect(matching.payload, equals(e1.payload));
        }

        await network.dispose();
      });
    });
  });
}
