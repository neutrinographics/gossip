import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'package:gossip/src/domain/value_objects/version_vector.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';

void main() {
  group('InMemoryEntryRepository', () {
    test('append and getAll stores and retrieves entries', () async {
      final store = InMemoryEntryRepository();
      final channelId = ChannelId('channel-1');
      final streamId = StreamId('stream-1');
      final author = NodeId('author-1');
      final entry = LogEntry(
        author: author,
        sequence: 1,
        timestamp: Hlc(1000, 0),
        payload: Uint8List.fromList([1, 2, 3]),
      );

      await store.append(channelId, streamId, entry);
      final entries = await store.getAll(channelId, streamId);

      expect(entries, hasLength(1));
      expect(entries[0].author, equals(author));
      expect(entries[0].sequence, equals(1));
    });

    test('entriesSince returns only entries after version vector', () async {
      final store = InMemoryEntryRepository();
      final channelId = ChannelId('channel-1');
      final streamId = StreamId('stream-1');
      final author1 = NodeId('author-1');
      final author2 = NodeId('author-2');

      await store.append(
        channelId,
        streamId,
        LogEntry(
          author: author1,
          sequence: 1,
          timestamp: Hlc(1000, 0),
          payload: Uint8List.fromList([1]),
        ),
      );
      await store.append(
        channelId,
        streamId,
        LogEntry(
          author: author1,
          sequence: 2,
          timestamp: Hlc(2000, 0),
          payload: Uint8List.fromList([2]),
        ),
      );
      await store.append(
        channelId,
        streamId,
        LogEntry(
          author: author2,
          sequence: 1,
          timestamp: Hlc(1500, 0),
          payload: Uint8List.fromList([3]),
        ),
      );

      final since = VersionVector({author1: 1, author2: 0});
      final newEntries = await store.entriesSince(channelId, streamId, since);

      expect(newEntries, hasLength(2)); // author1:2 and author2:1
      expect(
        newEntries.any((e) => e.author == author1 && e.sequence == 2),
        isTrue,
      );
      expect(
        newEntries.any((e) => e.author == author2 && e.sequence == 1),
        isTrue,
      );
    });

    test('latestSequence returns highest sequence for author', () async {
      final store = InMemoryEntryRepository();
      final channelId = ChannelId('channel-1');
      final streamId = StreamId('stream-1');
      final author = NodeId('author-1');

      expect(
        await store.latestSequence(channelId, streamId, author),
        equals(0),
      );

      await store.append(
        channelId,
        streamId,
        LogEntry(
          author: author,
          sequence: 1,
          timestamp: Hlc(1000, 0),
          payload: Uint8List.fromList([1]),
        ),
      );
      expect(
        await store.latestSequence(channelId, streamId, author),
        equals(1),
      );

      await store.append(
        channelId,
        streamId,
        LogEntry(
          author: author,
          sequence: 3,
          timestamp: Hlc(2000, 0),
          payload: Uint8List.fromList([2]),
        ),
      );
      expect(
        await store.latestSequence(channelId, streamId, author),
        equals(3),
      );
    });

    test('removeEntries removes specified entries', () async {
      final store = InMemoryEntryRepository();
      final channelId = ChannelId('channel-1');
      final streamId = StreamId('stream-1');
      final author = NodeId('author-1');

      final entry1 = LogEntry(
        author: author,
        sequence: 1,
        timestamp: Hlc(1000, 0),
        payload: Uint8List.fromList([1]),
      );
      final entry2 = LogEntry(
        author: author,
        sequence: 2,
        timestamp: Hlc(2000, 0),
        payload: Uint8List.fromList([2]),
      );

      await store.append(channelId, streamId, entry1);
      await store.append(channelId, streamId, entry2);
      expect(await store.entryCount(channelId, streamId), equals(2));

      await store.removeEntries(channelId, streamId, [entry1.id]);

      expect(await store.entryCount(channelId, streamId), equals(1));
      final remaining = await store.getAll(channelId, streamId);
      expect(remaining[0].sequence, equals(2));
    });

    test('sizeBytes calculates total size of entries', () async {
      final store = InMemoryEntryRepository();
      final channelId = ChannelId('channel-1');
      final streamId = StreamId('stream-1');
      final author = NodeId('author-1');

      final entry1 = LogEntry(
        author: author,
        sequence: 1,
        timestamp: Hlc(1000, 0),
        payload: Uint8List.fromList([1, 2, 3]),
      );
      final entry2 = LogEntry(
        author: author,
        sequence: 2,
        timestamp: Hlc(2000, 0),
        payload: Uint8List.fromList([4, 5]),
      );

      await store.append(channelId, streamId, entry1);
      await store.append(channelId, streamId, entry2);

      final expectedSize = entry1.sizeBytes + entry2.sizeBytes;
      expect(await store.sizeBytes(channelId, streamId), equals(expectedSize));
    });

    test(
      'append ignores duplicate entries with same author and sequence',
      () async {
        final store = InMemoryEntryRepository();
        final channelId = ChannelId('channel-1');
        final streamId = StreamId('stream-1');
        final author = NodeId('author-1');

        final entry1 = LogEntry(
          author: author,
          sequence: 1,
          timestamp: Hlc(1000, 0),
          payload: Uint8List.fromList([1, 2, 3]),
        );

        // Same author and sequence, different timestamp and payload
        final duplicate = LogEntry(
          author: author,
          sequence: 1,
          timestamp: Hlc(2000, 0),
          payload: Uint8List.fromList([4, 5, 6]),
        );

        await store.append(channelId, streamId, entry1);
        await store.append(channelId, streamId, duplicate);

        final entries = await store.getAll(channelId, streamId);
        expect(entries, hasLength(1));
        // Original entry is preserved
        expect(entries[0].timestamp, equals(Hlc(1000, 0)));
        expect(entries[0].payload, equals(Uint8List.fromList([1, 2, 3])));
      },
    );

    test('appendAll ignores duplicate entries', () async {
      final store = InMemoryEntryRepository();
      final channelId = ChannelId('channel-1');
      final streamId = StreamId('stream-1');
      final author = NodeId('author-1');

      final entry1 = LogEntry(
        author: author,
        sequence: 1,
        timestamp: Hlc(1000, 0),
        payload: Uint8List.fromList([1]),
      );
      final entry2 = LogEntry(
        author: author,
        sequence: 2,
        timestamp: Hlc(2000, 0),
        payload: Uint8List.fromList([2]),
      );

      // First append
      await store.appendAll(channelId, streamId, [entry1, entry2]);
      expect(await store.entryCount(channelId, streamId), equals(2));

      // Append same entries again (simulating gossip re-sync)
      await store.appendAll(channelId, streamId, [entry1, entry2]);
      expect(await store.entryCount(channelId, streamId), equals(2));

      // Append mix of new and duplicate
      final entry3 = LogEntry(
        author: author,
        sequence: 3,
        timestamp: Hlc(3000, 0),
        payload: Uint8List.fromList([3]),
      );
      await store.appendAll(channelId, streamId, [entry1, entry3]);
      expect(await store.entryCount(channelId, streamId), equals(3));
    });

    group('getVersionVector', () {
      test('returns empty version vector for empty stream', () async {
        final store = InMemoryEntryRepository();
        final channelId = ChannelId('channel-1');
        final streamId = StreamId('stream-1');

        final vv = await store.getVersionVector(channelId, streamId);

        expect(vv.entries, isEmpty);
      });

      test('returns version vector with max sequence per author', () async {
        final store = InMemoryEntryRepository();
        final channelId = ChannelId('channel-1');
        final streamId = StreamId('stream-1');
        final author1 = NodeId('author-1');
        final author2 = NodeId('author-2');

        await store.append(
          channelId,
          streamId,
          LogEntry(
            author: author1,
            sequence: 1,
            timestamp: Hlc(1000, 0),
            payload: Uint8List.fromList([1]),
          ),
        );
        await store.append(
          channelId,
          streamId,
          LogEntry(
            author: author1,
            sequence: 2,
            timestamp: Hlc(2000, 0),
            payload: Uint8List.fromList([2]),
          ),
        );
        await store.append(
          channelId,
          streamId,
          LogEntry(
            author: author2,
            sequence: 1,
            timestamp: Hlc(1500, 0),
            payload: Uint8List.fromList([3]),
          ),
        );
        await store.append(
          channelId,
          streamId,
          LogEntry(
            author: author2,
            sequence: 3,
            timestamp: Hlc(2500, 0),
            payload: Uint8List.fromList([4]),
          ),
        );

        final vv = await store.getVersionVector(channelId, streamId);

        expect(vv[author1], equals(2));
        expect(vv[author2], equals(3));
      });

      test('returns separate version vectors for different streams', () async {
        final store = InMemoryEntryRepository();
        final channelId = ChannelId('channel-1');
        final streamId1 = StreamId('stream-1');
        final streamId2 = StreamId('stream-2');
        final author = NodeId('author-1');

        await store.append(
          channelId,
          streamId1,
          LogEntry(
            author: author,
            sequence: 1,
            timestamp: Hlc(1000, 0),
            payload: Uint8List.fromList([1]),
          ),
        );
        await store.append(
          channelId,
          streamId2,
          LogEntry(
            author: author,
            sequence: 5,
            timestamp: Hlc(2000, 0),
            payload: Uint8List.fromList([2]),
          ),
        );

        final vv1 = await store.getVersionVector(channelId, streamId1);
        final vv2 = await store.getVersionVector(channelId, streamId2);

        expect(vv1[author], equals(1));
        expect(vv2[author], equals(5));
      });

      test('version vector updates after appendAll', () async {
        final store = InMemoryEntryRepository();
        final channelId = ChannelId('channel-1');
        final streamId = StreamId('stream-1');
        final author = NodeId('author-1');

        await store.appendAll(channelId, streamId, [
          LogEntry(
            author: author,
            sequence: 1,
            timestamp: Hlc(1000, 0),
            payload: Uint8List.fromList([1]),
          ),
          LogEntry(
            author: author,
            sequence: 2,
            timestamp: Hlc(2000, 0),
            payload: Uint8List.fromList([2]),
          ),
        ]);

        final vv = await store.getVersionVector(channelId, streamId);

        expect(vv[author], equals(2));
      });
    });
  });
}
