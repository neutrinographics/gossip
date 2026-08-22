import 'dart:async';
import 'dart:typed_data';

import 'package:gossip/src/application/services/materialization_service.dart';
import 'package:gossip/src/domain/interfaces/state_materializer.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:test/test.dart';

/// Counts entries; `initial()` can be gated on a completer, and the FIRST
/// `save()` call can be gated on another.
class _GatedMaterializer extends StateMaterializer<int> {
  int initialCallCount = 0;
  Completer<void>? gateInitial;
  Completer<void>? gateFirstSave;
  var _saveCalls = 0;

  @override
  Future<(int, String?)> initial({required bool isReset}) async {
    initialCallCount++;
    final gate = gateInitial;
    if (gate != null) await gate.future;
    return (0, null);
  }

  @override
  int fold(int state, LogEntry entry) => state + 1;

  @override
  Future<void> save(int state, String cursor) async {
    _saveCalls++;
    if (_saveCalls == 1) {
      final gate = gateFirstSave;
      if (gate != null) await gate.future;
    }
  }
}

void main() {
  final channelId = ChannelId('ch1');
  final streamId = StreamId('s1');

  LogEntry entryOf(int seq, int tsMs) => LogEntry(
    author: NodeId('author'),
    sequence: seq,
    timestamp: Hlc(tsMs, 0),
    payload: Uint8List.fromList([seq]),
  );

  group('MaterializationService initialization reentrancy', () {
    test('concurrent getState calls initialize exactly once', () async {
      final repo = InMemoryEntryRepository();
      await repo.append(channelId, streamId, entryOf(1, 1000));
      final service = MaterializationService(entryRepository: repo);
      final mat = _GatedMaterializer()..gateInitial = Completer<void>();
      await service.register<int>(channelId, streamId, mat);

      final g1 = service.getState<int>(channelId, streamId);
      final g2 = service.getState<int>(channelId, streamId);
      mat.gateInitial!.complete();

      expect(await g1, equals(1));
      expect(await g2, equals(1));
      expect(
        mat.initialCallCount,
        equals(1),
        reason: 'two racing initializations clobber each other\'s state',
      );
    });

    test('an entry folded while initialization is saving is not lost and '
        'state never regresses on the stream', () async {
      final repo = InMemoryEntryRepository();
      await repo.append(channelId, streamId, entryOf(1, 1000));
      final service = MaterializationService(entryRepository: repo);
      final mat = _GatedMaterializer()..gateFirstSave = Completer<void>();
      await service.register<int>(channelId, streamId, mat);

      final emissions = <int>[];
      final sub = service
          .getStateStream<int>(channelId, streamId)!
          .listen(emissions.add);

      // Initialization runs to its save() and suspends there.
      final init = service.getState<int>(channelId, streamId);
      await Future.delayed(Duration.zero);

      // A new entry lands and is folded mid-initialization.
      final e2 = entryOf(2, 2000);
      await repo.append(channelId, streamId, e2);
      final fold = service.foldEntries(channelId, streamId, [e2]);

      mat.gateFirstSave!.complete();
      await Future.wait([init, fold]);
      await Future.delayed(Duration.zero);

      expect(
        await service.getState<int>(channelId, streamId),
        equals(2),
        reason: 'the mid-init entry\'s fold must not be clobbered',
      );
      expect(
        emissions.isNotEmpty && emissions.last == 2,
        isTrue,
        reason: 'the stream must not end on a stale (regressed) state: '
            'emissions were $emissions',
      );

      await sub.cancel();
    });
  });

  group('MaterializationService register', () {
    test('replacing a materializer closes the old state stream', () async {
      final repo = InMemoryEntryRepository();
      final service = MaterializationService(entryRepository: repo);
      final first = _GatedMaterializer();
      await service.register<int>(channelId, streamId, first);

      var done = false;
      final sub = service
          .getStateStream<int>(channelId, streamId)!
          .listen((_) {}, onDone: () => done = true);

      await service.register<int>(channelId, streamId, _GatedMaterializer());
      await Future.delayed(Duration.zero);

      expect(
        done,
        isTrue,
        reason: 'the replaced state must be disposed (awaited, not dropped)',
      );
      await sub.cancel();
    });
  });
}
