import 'dart:typed_data';

import 'package:gossip/src/application/services/materialization_service.dart';
import 'package:gossip/src/domain/interfaces/state_materializer.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:test/test.dart';

/// Always throws when folding — simulates a buggy app materializer.
class _ThrowingMaterializer extends StateMaterializer<int> {
  @override
  (int, String?) initial({required bool isReset}) => (0, null);

  @override
  int fold(int state, LogEntry entry) => throw StateError('app bug');
}

/// Counts folded entries into a string state (distinct type so it can be
/// registered alongside the int materializer — the registry is type-keyed).
class _CountingMaterializer extends StateMaterializer<String> {
  @override
  (String, String?) initial({required bool isReset}) => ('0', null);

  @override
  String fold(String state, LogEntry entry) =>
      (int.parse(state) + 1).toString();
}

class _NoopMaterializer extends StateMaterializer<double> {
  @override
  (double, String?) initial({required bool isReset}) => (0, null);

  @override
  double fold(double state, LogEntry entry) => state;
}

/// Persists state + cursor to outer storage, like a real app materializer.
class _PersistingCounter extends StateMaterializer<int> {
  int? persistedState;
  String? persistedCursor;

  _PersistingCounter({this.persistedState, this.persistedCursor});

  @override
  (int, String?) initial({required bool isReset}) =>
      isReset ? (0, null) : (persistedState ?? 0, persistedCursor);

  @override
  int fold(int state, LogEntry entry) => state + 1;

  @override
  Future<void> save(int state, String cursor) async {
    persistedState = state;
    persistedCursor = cursor;
  }
}

void main() {
  final channelId = ChannelId('ch1');
  final streamId = StreamId('s1');
  final author = NodeId('author-a');

  LogEntry entryOf(int seq) => LogEntry(
    author: author,
    sequence: seq,
    timestamp: Hlc(1000 + seq, 0),
    payload: Uint8List.fromList([seq]),
  );

  test(
    'one throwing materializer does not starve its siblings of the batch '
    '(COR3-13)',
    () async {
      final repo = InMemoryEntryRepository();
      final service = MaterializationService(entryRepository: repo);
      // The thrower registers FIRST so it is folded first.
      await service.register<int>(channelId, streamId, _ThrowingMaterializer());
      await service.register<String>(
        channelId,
        streamId,
        _CountingMaterializer(),
      );
      // Initialize both on the empty stream (no folds yet).
      await service.getState<int>(channelId, streamId);
      await service.getState<String>(channelId, streamId);

      for (final seq in [1, 2]) {
        final entry = entryOf(seq);
        await repo.append(channelId, streamId, entry);
        // The thrower's failure must surface, but must not prevent the
        // sibling from receiving the batch — a starved sibling's cursor
        // jumps over the batch on its next fold, silently and permanently.
        await expectLater(
          service.foldEntries(channelId, streamId, [entry]),
          throwsStateError,
        );
      }

      expect(
        await service.getState<String>(channelId, streamId),
        equals('2'),
        reason: 'the sibling must have folded every batch',
      );
    },
  );

  test(
    'an equal-timestamp entry landing after a restart is not skipped by '
    'the persisted cursor (COR3-27)',
    () async {
      final repo = InMemoryEntryRepository();
      final authorB = NodeId('author-b');

      // Session 1: fold one entry, persist state + cursor.
      final session1 = _PersistingCounter();
      final service1 = MaterializationService(entryRepository: repo);
      await service1.register<int>(channelId, streamId, session1);
      final e1 = LogEntry(
        author: author,
        sequence: 1,
        timestamp: Hlc(1000, 0),
        payload: Uint8List.fromList([1]),
      );
      await repo.append(channelId, streamId, e1);
      await service1.foldEntries(channelId, streamId, [e1]);
      await service1.disposeAll();

      // Between sessions an entry with the SAME timestamp but a later
      // author arrives (HLC ties across authors are legal).
      await repo.append(
        channelId,
        streamId,
        LogEntry(
          author: authorB,
          sequence: 1,
          timestamp: Hlc(1000, 0),
          payload: Uint8List.fromList([2]),
        ),
      );

      // Session 2 restores from the persisted cursor: the tying entry
      // sorts after the folded one, so it must be folded — a
      // timestamp-only strictly-greater filter drops it forever.
      final session2 = _PersistingCounter(
        persistedState: session1.persistedState,
        persistedCursor: session1.persistedCursor,
      );
      final service2 = MaterializationService(entryRepository: repo);
      await service2.register<int>(channelId, streamId, session2);

      expect(
        await service2.getState<int>(channelId, streamId),
        equals(2),
        reason: 'both entries must be counted after the restart',
      );
    },
  );

  test('disposeAll tolerates a register landing mid-dispose (MIN-1)',
      () async {
    final repo = InMemoryEntryRepository();
    final service = MaterializationService(entryRepository: repo);
    await service.register<int>(channelId, streamId, _ThrowingMaterializer());
    await service.register<String>(
      channelId,
      streamId,
      _CountingMaterializer(),
    );

    // disposeAll suspends on its first await; the register mutates the
    // states map in that window.
    final disposing = service.disposeAll();
    await service.register<double>(channelId, streamId, _NoopMaterializer());

    await expectLater(disposing, completes);
  });
}
