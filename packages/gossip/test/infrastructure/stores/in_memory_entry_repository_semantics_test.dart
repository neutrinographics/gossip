import 'dart:typed_data';

import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:test/test.dart';

void main() {
  final channel = ChannelId('ch1');
  final stream = StreamId('s1');

  LogEntry entryOf(
    String author,
    int seq,
    int tsMs, {
    List<int> payload = const [1],
  }) {
    return LogEntry(
      author: NodeId(author),
      sequence: seq,
      timestamp: Hlc(tsMs, 0),
      payload: Uint8List.fromList(payload),
    );
  }

  group('InMemoryEntryRepository duplicate handling', () {
    test('append throws on a duplicate (author, sequence)', () async {
      final repo = InMemoryEntryRepository();
      await repo.append(channel, stream, entryOf('a', 1, 1000));

      // The interface contract says append throws on duplicates. Silent
      // dropping is how the appendEntry sequence race loses data with no
      // trace.
      await expectLater(
        () => repo.append(channel, stream, entryOf('a', 1, 2000, payload: [9])),
        throwsA(isA<StateError>()),
      );
      expect(await repo.entryCount(channel, stream), equals(1));
    });

    test('appendAll is all-or-nothing when the batch contains a duplicate',
        () async {
      final repo = InMemoryEntryRepository();
      await repo.append(channel, stream, entryOf('a', 1, 1000));

      await expectLater(
        () => repo.appendAll(channel, stream, [
          entryOf('a', 2, 2000),
          entryOf('a', 1, 1000), // duplicate
          entryOf('a', 3, 3000),
        ]),
        throwsA(isA<StateError>()),
      );
      expect(
        await repo.entryCount(channel, stream),
        equals(1),
        reason: 'contract: if any entry fails validation, none are added',
      );
    });
  });

  group('InMemoryEntryRepository compaction semantics', () {
    test('removeEntries does not regress latestSequence or the version '
        'vector', () async {
      final repo = InMemoryEntryRepository();
      final entries = [for (var i = 1; i <= 5; i++) entryOf('a', i, 1000 + i)];
      await repo.appendAll(channel, stream, entries);

      // Compact ALL of the author's entries away (time-based retention on
      // an idle stream does exactly this).
      await repo.removeEntries(
        channel,
        stream,
        entries.map((e) => e.id).toList(),
      );

      expect(
        await repo.latestSequence(channel, stream, NodeId('a')),
        equals(5),
        reason:
            'sequence allocation must never go backwards — reusing seq 1-5 '
            'makes new entries permanently invisible to peers whose version '
            'vector already covers them',
      );
      expect(
        (await repo.getVersionVector(channel, stream))[NodeId('a')],
        equals(5),
        reason:
            'a regressed digest makes peers re-send pruned entries, undoing '
            'compaction every gossip round',
      );
    });

    test('partial compaction keeps the high-water mark', () async {
      final repo = InMemoryEntryRepository();
      final entries = [for (var i = 1; i <= 5; i++) entryOf('a', i, 1000 + i)];
      await repo.appendAll(channel, stream, entries);

      // Remove the NEWEST entries (seq 4, 5).
      await repo.removeEntries(channel, stream, [
        entries[3].id,
        entries[4].id,
      ]);

      expect(
        await repo.latestSequence(channel, stream, NodeId('a')),
        equals(5),
      );
    });
  });

  group('InMemoryEntryRepository ordering', () {
    test('HLC ties are broken by author so all peers converge to the same '
        'order', () async {
      final repo = InMemoryEntryRepository();
      // Same timestamp, inserted in reverse-author order (models two nodes
      // writing concurrently at the same HLC instant, arriving in
      // different orders on different peers).
      await repo.append(channel, stream, entryOf('bbb', 1, 1000));
      await repo.append(channel, stream, entryOf('aaa', 1, 1000));

      final all = await repo.getAll(channel, stream);
      expect(
        all.map((e) => e.author.value).toList(),
        equals(['aaa', 'bbb']),
        reason:
            'LogEntry.compareTo defines timestamp→author→sequence; arrival '
            'order would diverge across peers and non-commutative '
            'materializers would never converge',
      );
    });
  });
}
