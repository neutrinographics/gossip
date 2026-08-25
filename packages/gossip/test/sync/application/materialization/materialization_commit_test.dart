import 'dart:typed_data';

import 'package:gossip/src/sync/application/materialization/fold_cursor.dart';
import 'package:gossip/src/sync/application/materialization/materialization_service.dart';
import 'package:gossip/src/sync/domain/interfaces/state_materializer.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_entry_repository.dart';
import 'package:test/test.dart';

import '../../../support/pump.dart';

/// Counts folded entries; `save()` throws on demand via a settable flag —
/// mirrors `materialization_robustness_test.dart`'s `_ThrowingMaterializer`
/// style (always-on failure), applied here to the save path so a failure
/// can be toggled on and off within a single test.
class _SaveFailingMaterializer extends StateMaterializer<int> {
  int? persistedState;
  String? persistedCursor;
  bool shouldThrowOnSave = false;

  @override
  (int, String?) initial({required bool isReset}) =>
      isReset ? (0, null) : (persistedState ?? 0, persistedCursor);

  @override
  int fold(int state, LogEntry entry) => state + 1;

  @override
  Future<void> save(int state, String cursor) async {
    if (shouldThrowOnSave) {
      throw StateError('save failed');
    }
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
    'incremental fold: a failed save leaves state unmutated and unemitted',
    () async {
      // Arrange: an initialized materializer at state S0 (one entry folded),
      // then make the next save throw.
      final repo = InMemoryEntryRepository();
      final service = MaterializationService(entryRepository: repo);
      final mat = _SaveFailingMaterializer();
      await service.register<int>(channelId, streamId, mat);

      final e1 = entryOf(1);
      await repo.append(channelId, streamId, e1);
      await service.foldEntries(channelId, streamId, [e1]);
      final s0 = await service.getState<int>(channelId, streamId);
      expect(s0, equals(1), reason: 'precondition: one entry folded to S0');

      final emissions = <int>[];
      final sub = service
          .getStateStream<int>(channelId, streamId)!
          .listen(emissions.add);

      mat.shouldThrowOnSave = true;
      final e2 = entryOf(2);
      await repo.append(channelId, streamId, e2);

      // Act: fold a new entry while save is broken.
      await expectLater(
        service.foldEntries(channelId, streamId, [e2]),
        throwsStateError,
        reason: "the save failure must surface to the fold's awaiter",
      );

      // Assert: the failed save must not have mutated or published state.
      // A failed save also marks the materializer uninitialized (CC5-8
      // final-review fix), so — while the save is still broken — a
      // getState call re-attempts initialization and surfaces that same
      // brokenness rather than silently returning a stale cached value.
      await expectLater(
        service.getState<int>(channelId, streamId),
        throwsStateError,
        reason:
            'getState re-initializes when uninitialized; with the save '
            'still broken, re-initialization fails too — no stale read '
            'is silently returned',
      );
      expect(
        emissions,
        isEmpty,
        reason: 'a failed save must not emit on the state stream',
      );

      // Recovery: clear the failure and re-fold the SAME entry. Since the
      // cursor never advanced past it, this is a correct retry, not a
      // double-count.
      mat.shouldThrowOnSave = false;
      await service.foldEntries(channelId, streamId, [e2]);
      await pumpUntil(
        () => emissions.isNotEmpty,
        describe: 'the recovered retry emitting on the state stream',
      );

      expect(
        await service.getState<int>(channelId, streamId),
        equals(2),
        reason:
            're-folding the same entry after the save recovers must fold '
            'it exactly once — the cursor never advanced past it',
      );
      expect(
        emissions,
        hasLength(1),
        reason: 'the recovered retry must emit exactly once',
      );

      await sub.cancel();
    },
  );

  test('incremental fold: recovery after a failed save must not permanently '
      'skip the failed batch — re-initialization refolds it from the '
      'repository', () async {
    // Regression pin: the old recovery premise assumed the NEXT fold
    // call would retry the SAME batch. Production callers instead fold
    // whatever is new — the failed batch (e2) is never re-submitted, so
    // a recovery that just resumes from the pre-failure cursor silently
    // skips it forever.

    // Arrange: e1 committed, then break save.
    final repo = InMemoryEntryRepository();
    final service = MaterializationService(entryRepository: repo);
    final mat = _SaveFailingMaterializer();
    await service.register<int>(channelId, streamId, mat);

    final e1 = entryOf(1);
    await repo.append(channelId, streamId, e1);
    await service.foldEntries(channelId, streamId, [e1]);
    expect(
      await service.getState<int>(channelId, streamId),
      equals(1),
      reason: 'precondition: e1 committed',
    );

    mat.shouldThrowOnSave = true;
    final e2 = entryOf(2);
    await repo.append(channelId, streamId, e2);
    await expectLater(
      service.foldEntries(channelId, streamId, [e2]),
      throwsStateError,
      reason: "the save failure must surface to the fold's awaiter",
    );

    // Heal, then fold a NEW batch (e3) — as production callers do, not a
    // manual retry of e2.
    mat.shouldThrowOnSave = false;
    final e3 = entryOf(3);
    await repo.append(channelId, streamId, e3);
    await service.foldEntries(channelId, streamId, [e3]);

    expect(
      await service.getState<int>(channelId, streamId),
      equals(3),
      reason:
          'a failed save must not durably lose its batch: state must '
          'reflect e1+e2+e3, not just e1+e3 — the durable-loss '
          'regression this test pins',
    );
    expect(
      mat.persistedState,
      equals(3),
      reason:
          'the persisted snapshot recorded by save() must reflect the '
          'full sequence, not skip the failed batch',
    );
    expect(
      mat.persistedCursor,
      equals(FoldCursor.fromEntry(e3).toString()),
      reason:
          'the persisted cursor must only advance past e3 once the '
          'full sequence has actually been folded and saved',
    );
  });

  test('full rebuild: a failed save throws to the fold\'s awaiter and leaves '
      'the materializer uninitialized, so a later read throws too instead of '
      'returning stale state', () async {
    // Arrange: an initialized materializer at state S0 (one entry folded),
    // then make the next save throw.
    final repo = InMemoryEntryRepository();
    final service = MaterializationService(entryRepository: repo);
    final mat = _SaveFailingMaterializer();
    await service.register<int>(channelId, streamId, mat);

    final e1 = entryOf(1);
    await repo.append(channelId, streamId, e1);
    await service.foldEntries(channelId, streamId, [e1]);
    final s0 = await service.getState<int>(channelId, streamId);
    expect(s0, equals(1), reason: 'precondition: one entry folded to S0');

    final emissions = <int>[];
    final sub = service
        .getStateStream<int>(channelId, streamId)!
        .listen(emissions.add);

    mat.shouldThrowOnSave = true;
    final e2 = entryOf(2);
    await repo.append(channelId, streamId, e2);

    // Act: force a full rebuild while save is broken.
    await expectLater(
      service.foldEntries(channelId, streamId, [
        e2,
      ], containsOutOfOrderEntries: true),
      throwsStateError,
      reason: "the save failure must surface to the fold's awaiter",
    );

    // Assert: the failed save must not have published the rebuilt state.
    // A failed save also marks the materializer uninitialized (CC5-8
    // final-review fix), so — while the save is still broken — a
    // getState call re-attempts initialization and surfaces that same
    // brokenness rather than silently returning a stale cached value.
    await expectLater(
      service.getState<int>(channelId, streamId),
      throwsStateError,
      reason:
          'getState re-initializes when uninitialized; with the save '
          'still broken, re-initialization fails too — no stale read '
          'is silently returned',
    );
    expect(
      emissions,
      isEmpty,
      reason: 'a failed save must not emit on the state stream',
    );

    // Recovery: a later rebuild with a healthy save succeeds and emits.
    mat.shouldThrowOnSave = false;
    await service.foldEntries(channelId, streamId, [
      e2,
    ], containsOutOfOrderEntries: true);
    await pumpUntil(
      () => emissions.isNotEmpty,
      describe: 'the recovered rebuild emitting on the state stream',
    );

    expect(
      await service.getState<int>(channelId, streamId),
      equals(2),
      reason: 'the recovered rebuild must publish the rebuilt state',
    );
    expect(
      emissions,
      equals([2]),
      reason: 'the recovered rebuild must emit the rebuilt state',
    );

    await sub.cancel();
  });

  test(
    'initialize: a failed save leaves the materializer uninitialized',
    () async {
      // Pins the already-correct path so the unification cannot regress it.

      // Arrange: an unregistered-then-registered materializer whose first
      // save (during initialization) throws.
      final repo = InMemoryEntryRepository();
      final service = MaterializationService(entryRepository: repo);
      final mat = _SaveFailingMaterializer()..shouldThrowOnSave = true;
      await service.register<int>(channelId, streamId, mat);

      final e1 = entryOf(1);
      await repo.append(channelId, streamId, e1);

      final emissions = <int>[];
      final sub = service
          .getStateStream<int>(channelId, streamId)!
          .listen(emissions.add);

      // Act: the first getState triggers initialization, whose save fails.
      await expectLater(
        service.getState<int>(channelId, streamId),
        throwsStateError,
        reason: "the save failure must surface to the getState awaiter",
      );

      // Assert: nothing was published.
      expect(
        emissions,
        isEmpty,
        reason: 'a failed initialization save must not emit',
      );

      // Recovery: a later getState with a healthy save completes
      // initialization normally.
      mat.shouldThrowOnSave = false;
      final state = await service.getState<int>(channelId, streamId);
      await pumpUntil(
        () => emissions.isNotEmpty,
        describe: 'the completed initialization emitting on the state stream',
      );

      expect(
        state,
        equals(1),
        reason: 'a later getState with a healthy save must initialize',
      );
      expect(
        emissions,
        equals([1]),
        reason: 'the completed initialization must emit exactly once',
      );

      await sub.cancel();
    },
  );

  test('out-of-order entries below the committed cursor survive a '
      'failed-save re-initialization', () async {
    // Arrange: e1, e2 fold and commit together (the materializer's very
    // first fold — the "no separate fold needed" comment on
    // _foldForState's uninitialized branch), landing the persisted
    // cursor on e2.
    final repo = InMemoryEntryRepository();
    final service = MaterializationService(entryRepository: repo);
    final mat = _SaveFailingMaterializer();
    await service.register<int>(channelId, streamId, mat);

    final e1 = entryOf(1);
    final e2 = entryOf(2);
    await repo.append(channelId, streamId, e1);
    await repo.append(channelId, streamId, e2);
    await service.foldEntries(channelId, streamId, [e1, e2]);
    expect(
      await service.getState<int>(channelId, streamId),
      equals(2),
      reason: 'precondition: e1+e2 committed, cursor at e2',
    );

    // Break save, fold e3 — the save throws, and per _commit's why-doc
    // marks the materializer uninitialized rather than leaving it as-is
    // (so a later fold of only NEW entries can't silently skip e3
    // forever). The persisted snapshot/cursor stay at e1+e2.
    mat.shouldThrowOnSave = true;
    final e3 = entryOf(3);
    await repo.append(channelId, streamId, e3);
    await expectLater(
      service.foldEntries(channelId, streamId, [e3]),
      throwsStateError,
      reason: "the save failure must surface to the fold's awaiter",
    );

    // Heal, then arrange an entry that sorts BELOW the committed cursor
    // (e2's position) via a direct repository append — bypassing
    // foldEntries entirely, the way a peer's out-of-order delta lands:
    // this node never folded it, but its HLC is older than anything
    // already folded.
    mat.shouldThrowOnSave = false;
    final belowCursorAuthor = NodeId('author-b');
    final eBelow = LogEntry(
      author: belowCursorAuthor,
      sequence: 1,
      timestamp: Hlc(500, 0), // older than e2's Hlc(1002, 0) cursor
      payload: Uint8List.fromList([0]),
    );
    await repo.append(channelId, streamId, eBelow);

    // Act: fold the below-cursor entry as an out-of-order batch, while
    // the materializer is still uninitialized from the failed e3 save
    // above.
    await service.foldEntries(channelId, streamId, [
      eBelow,
    ], containsOutOfOrderEntries: true);

    // Assert: state reflects ALL FOUR entries. The skip hazard this
    // pins: _foldForState's uninitialized branch resumes from the
    // persisted cursor via _initialize regardless of
    // containsOutOfOrderEntries — FoldCursor.isBefore's getAll()-minus-
    // already-folded reasoning only holds for entries the cursor
    // actually advanced past. eBelow never was folded, but its older
    // HLC sorts it below the cursor, so _initialize's cursor filter
    // would silently and permanently drop it instead of folding it.
    expect(
      await service.getState<int>(channelId, streamId),
      equals(4),
      reason:
          "the skip hazard: a below-cursor entry that was never folded "
          "must not be dropped by re-initialization after a failed "
          "save — containsOutOfOrderEntries:true must force a full "
          "rebuild instead of a cursor-resuming _initialize",
    );
  });
}
