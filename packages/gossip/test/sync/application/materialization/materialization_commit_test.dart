import 'dart:typed_data';

import 'package:gossip/src/sync/application/materialization/materialization_service.dart';
import 'package:gossip/src/sync/domain/interfaces/state_materializer.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_entry_repository.dart';
import 'package:test/test.dart';

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
      expect(
        await service.getState<int>(channelId, streamId),
        equals(1),
        reason: 'a failed save must leave cached state at S0, unmutated',
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
      await Future.delayed(Duration.zero);

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

  test('full rebuild: a failed save leaves prior state visible', () async {
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
    expect(
      await service.getState<int>(channelId, streamId),
      equals(1),
      reason:
          'a failed save must leave prior state S0 visible, not the '
          'rebuilt state',
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
    await Future.delayed(Duration.zero);

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
      await Future.delayed(Duration.zero);

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
}
