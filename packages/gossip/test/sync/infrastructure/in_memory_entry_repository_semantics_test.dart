import 'dart:typed_data';

import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_entry_repository.dart';
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

    test(
      'appendAll is all-or-nothing when the batch contains a duplicate',
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
      },
    );
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
      await repo.removeEntries(channel, stream, [entries[3].id, entries[4].id]);

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

  group('InMemoryEntryRepository appendAll atomicity (COR3-9)', () {
    test(
      'concurrent overlapping appendAll calls cannot partially apply',
      () async {
        final repo = InMemoryEntryRepository();
        final batch1 = [
          for (final s in [1, 2, 3, 4]) entryOf('a', s, 1000 + s),
        ];
        // Overlaps batch1 mid-flight (not at its head, so the second
        // call's up-front validation cannot catch it — the collision only
        // materializes while both insert loops are interleaving).
        final batch2 = [
          for (final s in [3, 4, 5]) entryOf('a', s, 1000 + s),
        ];

        // Two overlapping merges race (the engine's per-peer pending keys
        // deliberately allow concurrent same-stream pulls from two peers).
        final results = await Future.wait([
          repo
              .appendAll(channel, stream, batch1)
              .then<Object?>((_) => null, onError: (Object e) => e),
          repo
              .appendAll(channel, stream, batch2)
              .then<Object?>((_) => null, onError: (Object e) => e),
        ]);

        expect(
          results.whereType<StateError>(),
          hasLength(1),
          reason: 'exactly one call must win',
        );
        final stored = (await repo.getAll(
          channel,
          stream,
        )).map((e) => e.sequence).toList();
        final winner = results[0] == null ? batch1 : batch2;
        expect(
          stored,
          equals(winner.map((e) => e.sequence).toList()),
          reason:
              'all-or-nothing: the losing call must leave no entries '
              'behind — a partial batch is covered by the version vector '
              'but never reported to the application',
        );
      },
    );
  });

  group('InMemoryEntryRepository compaction floor (COR3-1)', () {
    Future<InMemoryEntryRepository> repoWith(String author, int upTo) async {
      final repo = InMemoryEntryRepository();
      for (var i = 1; i <= upTo; i++) {
        await repo.append(channel, stream, entryOf(author, i, 1000 + i));
      }
      return repo;
    }

    test('starts empty for a fresh stream', () async {
      final repo = await repoWith('a', 3);
      final floor = await repo.getCompactionFloor(channel, stream);
      expect(floor.entries, isEmpty);
    });

    test(
      'removeEntries raises the floor to the highest removed sequence',
      () async {
        final repo = await repoWith('a', 5);
        final all = await repo.getAll(channel, stream);
        await repo.removeEntries(
          channel,
          stream,
          all.take(3).map((e) => e.id).toList(), // seqs 1..3
        );

        final floor = await repo.getCompactionFloor(channel, stream);
        expect(floor[NodeId('a')], equals(3));
        // High-water mark unaffected (existing invariant).
        final vv = await repo.getVersionVector(channel, stream);
        expect(vv[NodeId('a')], equals(5));
      },
    );

    test('the floor is monotonic across removals', () async {
      final repo = await repoWith('a', 5);
      final all = await repo.getAll(channel, stream);
      await repo.removeEntries(channel, stream, [all[2].id]); // seq 3
      await repo.removeEntries(channel, stream, [all[0].id]); // seq 1

      final floor = await repo.getCompactionFloor(channel, stream);
      expect(
        floor[NodeId('a')],
        equals(3),
        reason: 'a later removal of a lower sequence must not regress it',
      );
    });

    test('adoptVersionFloor raises floor AND high-water mark', () async {
      final repo = InMemoryEntryRepository();

      // A fresh joiner accepts truncated history for author a up to 10.
      await repo.adoptVersionFloor(
        channel,
        stream,
        VersionVector({NodeId('a'): 10}),
      );

      final floor = await repo.getCompactionFloor(channel, stream);
      expect(floor[NodeId('a')], equals(10));
      final vv = await repo.getVersionVector(channel, stream);
      expect(
        vv[NodeId('a')],
        equals(10),
        reason:
            'the adopted range counts as covered so it is never re-requested',
      );
      expect(
        await repo.latestSequence(channel, stream, NodeId('a')),
        equals(10),
      );
    });

    test(
      'adoptVersionFloor is monotonic (adopting lower is a no-op)',
      () async {
        final repo = await repoWith('a', 5);
        await repo.adoptVersionFloor(
          channel,
          stream,
          VersionVector({NodeId('a'): 2}),
        );

        final vv = await repo.getVersionVector(channel, stream);
        expect(vv[NodeId('a')], equals(5));
        final floor = await repo.getCompactionFloor(channel, stream);
        expect(floor.entries, isEmpty, reason: 'nothing was ever pruned');
      },
    );

    test('clearStream resets the floor with the stream identity', () async {
      final repo = await repoWith('a', 3);
      final all = await repo.getAll(channel, stream);
      await repo.removeEntries(channel, stream, [all[0].id]);
      await repo.clearStream(channel, stream);

      final floor = await repo.getCompactionFloor(channel, stream);
      expect(floor.entries, isEmpty);
    });
  });
}
