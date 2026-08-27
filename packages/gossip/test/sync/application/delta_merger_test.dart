import 'dart:typed_data';

import 'package:gossip/src/shared/domain/errors/sync_error.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:gossip/src/sync/application/delta_merger.dart';
import 'package:gossip/src/sync/domain/messages/delta_response.dart';
import 'package:gossip/src/sync/domain/services/hlc_clock.dart';
import 'package:gossip/src/shared/domain/services/time_source.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_entry_repository.dart';
import 'package:test/test.dart';

/// Unit tests for [DeltaMerger], extracted from `GossipEngine`:
/// `_mergeChain`, `_selectContiguousEntries`/`ContiguityGap`,
/// `_reportedGaps`/`_reportContiguityGaps`, the merge body of
/// `_mergeInner` from its floor-adoption block onward, and
/// `_updateHlcFromEntries`. Driven against a real
/// [InMemoryEntryRepository] — no mocks of the repository — per the
/// engine's own testing convention.
///
/// The old engine-level tests in gossip_engine_contiguity_test.dart and
/// gossip_engine_catchup_test.dart stay in place unmodified — they pin the
/// same behavior end-to-end through the engine's public API, now via
/// [DeltaMerger] underneath.
void main() {
  final channelId = ChannelId('ch1');
  final streamId = StreamId('s1');
  final authorA = NodeId('author-a');
  final authorB = NodeId('author-b');
  final peer1 = NodeId('peer1');

  LogEntry entryOf(NodeId author, int seq, int tsMs) => LogEntry(
    author: author,
    sequence: seq,
    timestamp: Hlc(tsMs, 0),
    payload: Uint8List.fromList([seq]),
  );

  DeltaResponse deltaOf(
    List<LogEntry> entries, {
    NodeId? sender,
    bool hasMore = false,
    VersionVector floor = VersionVector.empty,
  }) => DeltaResponse(
    sender: sender ?? peer1,
    channelId: channelId,
    streamId: streamId,
    entries: entries,
    hasMore: hasMore,
    floor: floor,
  );

  /// Builds a [DeltaMerger] wired to a real [InMemoryEntryRepository],
  /// recording every observable side effect for assertions. Individual
  /// tests override only the callbacks/collaborators they care about.
  ({
    DeltaMerger merger,
    InMemoryEntryRepository entryRepository,
    HlcClock hlcClock,
    List<SyncError> errors,
    List<
      ({
        ChannelId channelId,
        StreamId streamId,
        List<LogEntry> entries,
        bool containsOutOfOrderEntries,
      })
    >
    mergedEntries,
    List<String> logs,
    List<(NodeId, ChannelId, StreamId)> continuationsIssued,
    List<void> newEntriesMergedCalls,
    List<String> callOrder,
  })
  build({NodeId? localNode}) {
    final entryRepository = InMemoryEntryRepository();
    final timePort = InMemoryTimePort();
    final hlcClock = HlcClock(TimeSource(timePort));
    final errors = <SyncError>[];
    final mergedEntries =
        <
          ({
            ChannelId channelId,
            StreamId streamId,
            List<LogEntry> entries,
            bool containsOutOfOrderEntries,
          })
        >[];
    final logs = <String>[];
    final continuationsIssued = <(NodeId, ChannelId, StreamId)>[];
    final newEntriesMergedCalls = <void>[];
    final callOrder = <String>[];

    final merger = DeltaMerger(
      localNode: localNode ?? NodeId('local'),
      entryRepository: entryRepository,
      hlcClock: hlcClock,
      localNodeRepository: InMemoryLocalNodeRepository(),
      onError: errors.add,
      onLog: (level, message, [error, stack]) => logs.add('$level: $message'),
      onEntriesMerged:
          (channelId, streamId, entries, containsOutOfOrderEntries) async {
            callOrder.add('onEntriesMerged');
            mergedEntries.add((
              channelId: channelId,
              streamId: streamId,
              entries: entries,
              containsOutOfOrderEntries: containsOutOfOrderEntries,
            ));
          },
      onNewEntriesMerged: () {
        callOrder.add('onNewEntriesMerged');
        newEntriesMergedCalls.add(null);
      },
      onContinuationIssued: (peer, channelId, streamId) {
        callOrder.add('onContinuationIssued');
        continuationsIssued.add((peer, channelId, streamId));
      },
    );

    return (
      merger: merger,
      entryRepository: entryRepository,
      hlcClock: hlcClock,
      errors: errors,
      mergedEntries: mergedEntries,
      logs: logs,
      continuationsIssued: continuationsIssued,
      newEntriesMergedCalls: newEntriesMergedCalls,
      callOrder: callOrder,
    );
  }

  group('DeltaMerger — contiguous merge', () {
    test('contiguous entries merge and advance the vector', () async {
      final h = build();

      final result = await h.merger.merge(
        deltaOf([entryOf(authorA, 1, 1001), entryOf(authorA, 2, 1002)]),
        solicited: true,
      );

      expect(result.mergedNewEntries, isTrue);
      expect(result.continuation, isNull);
      final vv = await h.entryRepository.getVersionVector(channelId, streamId);
      expect(vv[authorA], equals(2));
      expect(h.mergedEntries, hasLength(1));
      expect(
        h.mergedEntries.single.entries.map((e) => e.sequence),
        equals([1, 2]),
      );
    });
  });

  group('DeltaMerger — contiguity guard', () {
    test(
      'a gapped author is truncated at the gap with the prefix kept',
      () async {
        final h = build();

        final result = await h.merger.merge(
          deltaOf([
            entryOf(authorA, 1, 1001),
            entryOf(authorA, 2, 1002),
            entryOf(authorA, 4, 1004), // gap at 3
          ]),
          solicited: true,
        );

        expect(result.mergedNewEntries, isTrue);
        final all = await h.entryRepository.getAll(channelId, streamId);
        expect(
          all.map((e) => e.sequence),
          equals([1, 2]),
          reason:
              'seq 4 must be dropped — merging it would strand seq 3 '
              'forever',
        );
      },
    );

    test('duplicate/stale batches are filtered — no repository throw, no '
        'onEntriesMerged', () async {
      final h = build();
      await h.entryRepository.append(
        channelId,
        streamId,
        entryOf(authorA, 1, 1001),
      );

      final result = await h.merger.merge(
        deltaOf([entryOf(authorA, 1, 1001)]), // already held
        solicited: true,
      );

      expect(result.mergedNewEntries, isFalse);
      expect(result.continuation, isNull);
      expect(h.mergedEntries, isEmpty);
    });
  });

  group('DeltaMerger — floor adoption', () {
    test('solicited floor adoption raises the mark', () async {
      final h = build();

      await h.merger.merge(
        deltaOf([
          entryOf(authorA, 11, 1011),
        ], floor: VersionVector({authorA: 10})),
        solicited: true,
      );

      final vv = await h.entryRepository.getVersionVector(channelId, streamId);
      expect(
        vv[authorA],
        equals(11),
        reason: 'the floor raises the mark to 10, then seq 11 is contiguous',
      );
    });

    test('unsolicited floor is IGNORED', () async {
      final h = build();

      await h.merger.merge(
        deltaOf([
          entryOf(authorA, 11, 1011),
        ], floor: VersionVector({authorA: 10})),
        solicited: false,
      );

      final vv = await h.entryRepository.getVersionVector(channelId, streamId);
      expect(
        vv[authorA],
        equals(0),
        reason:
            'an unsolicited claim must not move our floor — seq 11 is '
            'gapped against an empty local vector and dropped',
      );
      expect(h.mergedEntries, isEmpty);
    });
  });

  group('DeltaMerger — gap reporting', () {
    test('solicited gaps emit the error once per position (dedup)', () async {
      final h = build();

      await h.merger.merge(
        deltaOf([entryOf(authorA, 11, 1011)]),
        solicited: true,
      );
      expect(h.errors, hasLength(1));
      expect(h.errors.single.message, contains('11'));

      // Same gap position again — must not re-report.
      await h.merger.merge(
        deltaOf([entryOf(authorA, 11, 1011)]),
        solicited: true,
      );
      expect(h.errors, hasLength(1), reason: 'same gap reported once');
    });

    test('unsolicited gaps only trace-log — no error', () async {
      final h = build();

      await h.merger.merge(
        deltaOf([entryOf(authorA, 11, 1011)]),
        solicited: false,
      );

      expect(h.errors, isEmpty);
      expect(
        h.logs.any((l) => l.startsWith('LogLevel.trace:')),
        isTrue,
        reason: 'an unsolicited gap must still be diagnosable via trace',
      );
    });

    test(
      'clearReportedGaps allows the same gap to be reported again',
      () async {
        final h = build();

        await h.merger.merge(
          deltaOf([entryOf(authorA, 11, 1011)]),
          solicited: true,
        );
        expect(h.errors, hasLength(1));

        h.merger.clearReportedGaps();

        await h.merger.merge(
          deltaOf([entryOf(authorA, 11, 1011)]),
          solicited: true,
        );
        expect(h.errors, hasLength(2));
      },
    );

    test(
      'clearReportedGapsForPeer only clears that peer\'s reported gaps',
      () async {
        final h = build();
        final peerA = NodeId('peerA');
        final peerB = NodeId('peerB');

        await h.merger.merge(
          deltaOf([entryOf(authorA, 11, 1011)], sender: peerA),
          solicited: true,
        );
        await h.merger.merge(
          deltaOf([entryOf(authorB, 11, 1011)], sender: peerB),
          solicited: true,
        );
        expect(h.errors, hasLength(2));

        h.merger.clearReportedGapsForPeer(peerA);

        // peerA's gap reports again; peerB's stays deduped.
        await h.merger.merge(
          deltaOf([entryOf(authorA, 11, 1011)], sender: peerA),
          solicited: true,
        );
        await h.merger.merge(
          deltaOf([entryOf(authorB, 11, 1011)], sender: peerB),
          solicited: true,
        );
        expect(h.errors, hasLength(3));
      },
    );
  });

  group('DeltaMerger — HLC', () {
    test('HLC advances only from accepted entries', () async {
      final h = build();
      final before = h.hlcClock.current;

      // Gapped against empty vector: dropped, must not touch the clock.
      await h.merger.merge(
        deltaOf([entryOf(authorA, 5, 2000)]),
        solicited: true,
      );
      expect(h.hlcClock.current, equals(before));

      // Contiguous: accepted, must advance the clock.
      await h.merger.merge(
        deltaOf([entryOf(authorA, 1, 2000)]),
        solicited: true,
      );
      expect(h.hlcClock.current, isNot(equals(before)));
    });
  });

  group('DeltaMerger — continuation', () {
    test('hasMore + progress → continuation at the advanced vector', () async {
      final h = build(localNode: NodeId('local'));

      final result = await h.merger.merge(
        deltaOf([
          entryOf(authorA, 1, 1001),
          entryOf(authorA, 2, 1002),
        ], hasMore: true),
        solicited: true,
      );

      expect(result.continuation, isNotNull);
      expect(result.continuation!.channelId, equals(channelId));
      expect(result.continuation!.streamId, equals(streamId));
      expect(result.continuation!.since[authorA], equals(2));
      expect(result.continuation!.sender, equals(NodeId('local')));
      expect(h.continuationsIssued, hasLength(1));
      expect(
        h.continuationsIssued.single,
        equals((peer1, channelId, streamId)),
      );
    });

    test('hasMore + no progress → null continuation', () async {
      final h = build();
      await h.entryRepository.append(
        channelId,
        streamId,
        entryOf(authorA, 1, 1001),
      );

      final result = await h.merger.merge(
        deltaOf([entryOf(authorA, 1, 1001)], hasMore: true), // duplicate
        solicited: true,
      );

      expect(
        result.continuation,
        isNull,
        reason:
            'no progress must not issue a continuation (infinite '
            'loop guard)',
      );
      expect(result.mergedNewEntries, isFalse);
      expect(h.continuationsIssued, isEmpty);
    });

    test('callback order: onNewEntriesMerged fires before onEntriesMerged, '
        'which fires before onContinuationIssued', () async {
      final h = build();

      await h.merger.merge(
        deltaOf([entryOf(authorA, 1, 1001)], hasMore: true),
        solicited: true,
      );

      expect(
        h.callOrder,
        equals([
          'onNewEntriesMerged',
          'onEntriesMerged',
          'onContinuationIssued',
        ]),
        reason:
            'preserves the exact callback order: count+news '
            'before onEntriesMerged, pending re-mark right before the '
            'chained merge returns',
      );
    });
  });

  group('DeltaMerger — chain serialization', () {
    test('two concurrent same-stream merges serialize — no partial batches, '
        'no spurious errors', () async {
      final h = build();
      final peerA = NodeId('peerA');
      final peerB = NodeId('peerB');

      DeltaResponse from(NodeId sender, List<int> seqs) => DeltaResponse(
        sender: sender,
        channelId: channelId,
        streamId: streamId,
        entries: [for (final s in seqs) entryOf(authorA, s, 2000 + s)],
      );

      final results = await Future.wait([
        h.merger.merge(from(peerA, [1, 2, 3]), solicited: false),
        h.merger.merge(from(peerB, [1, 2, 3, 4]), solicited: false),
      ]);

      expect(h.errors, isEmpty);
      final stored = await h.entryRepository.getAll(channelId, streamId);
      expect(stored.map((e) => e.sequence), equals([1, 2, 3, 4]));
      // Every entry reported exactly once across the merge callbacks.
      final reported =
          h.mergedEntries
              .expand((m) => m.entries)
              .map((e) => e.sequence)
              .toList()
            ..sort();
      expect(reported, equals([1, 2, 3, 4]));
      expect(
        results.where((r) => r.mergedNewEntries).length,
        equals(2),
        reason: 'both batches contributed genuinely new entries',
      );
    });
  });
}
