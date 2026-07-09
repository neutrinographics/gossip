import 'dart:async';
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

// ---------------------------------------------------------------------------
// Test materializers
// ---------------------------------------------------------------------------

/// Counts the number of entries folded.
class CountMaterializer extends StateMaterializer<int> {
  @override
  (int, String?) initial({required bool isReset}) => (0, null);

  @override
  int fold(int state, LogEntry entry) => state + 1;
}

/// Sums the first byte of each entry's payload.
class SumMaterializer extends StateMaterializer<int> {
  @override
  (int, String?) initial({required bool isReset}) => (0, null);

  @override
  int fold(int state, LogEntry entry) {
    return state + (entry.payload.isNotEmpty ? entry.payload[0] : 0);
  }
}

/// Returns the last entry's author as a string.
class LastAuthorMaterializer extends StateMaterializer<String> {
  @override
  (String, String?) initial({required bool isReset}) => ('', null);

  @override
  String fold(String state, LogEntry entry) => entry.author.value;
}

/// Materializer that returns a cursor from initial(), enabling cursor tests.
class CursorAwareMaterializer extends StateMaterializer<int> {
  final String? _storedCursor;
  final List<String> savedCursors = [];
  final List<int> savedStates = [];
  int initialCallCount = 0;
  bool lastIsReset = false;

  CursorAwareMaterializer({String? storedCursor})
    : _storedCursor = storedCursor;

  @override
  (int, String?) initial({required bool isReset}) {
    initialCallCount++;
    lastIsReset = isReset;
    if (isReset) return (0, null);
    return (100, _storedCursor); // 100 = cached state from "disk"
  }

  @override
  int fold(int state, LogEntry entry) => state + 1;

  @override
  Future<void> save(int state, String cursor) async {
    savedStates.add(state);
    savedCursors.add(cursor);
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

LogEntry _entry(int physicalMs, {int logical = 0, int payloadByte = 0}) {
  return LogEntry(
    author: NodeId('node'),
    sequence: physicalMs, // use physicalMs as sequence for simplicity
    timestamp: Hlc(physicalMs, logical),
    payload: Uint8List.fromList([payloadByte]),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late InMemoryEntryRepository entryRepo;
  late MaterializationService service;
  final channelId = ChannelId('ch1');
  final streamId = StreamId('s1');

  setUp(() {
    entryRepo = InMemoryEntryRepository();
    service = MaterializationService(entryRepository: entryRepo);
  });

  group('MaterializationService', () {
    group('register and getState basics', () {
      test('getState returns null when no materializer registered', () async {
        final state = await service.getState<int>(channelId, streamId);
        expect(state, isNull);
      });

      test('getState returns initial state when no entries exist', () async {
        service.register(channelId, streamId, CountMaterializer());
        final state = await service.getState<int>(channelId, streamId);
        expect(state, equals(0));
      });

      test('getState folds entries correctly (count)', () async {
        await entryRepo.append(channelId, streamId, _entry(1));
        await entryRepo.append(channelId, streamId, _entry(2));
        await entryRepo.append(channelId, streamId, _entry(3));

        service.register(channelId, streamId, CountMaterializer());
        final state = await service.getState<int>(channelId, streamId);
        expect(state, equals(3));
      });

      test('getState folds entries correctly (sum)', () async {
        await entryRepo.append(channelId, streamId, _entry(1, payloadByte: 10));
        await entryRepo.append(channelId, streamId, _entry(2, payloadByte: 20));
        await entryRepo.append(channelId, streamId, _entry(3, payloadByte: 5));

        service.register(channelId, streamId, SumMaterializer());
        final state = await service.getState<int>(channelId, streamId);
        expect(state, equals(35));
      });

      test('register replaces previous materializer of same type', () async {
        await entryRepo.append(channelId, streamId, _entry(1, payloadByte: 10));
        await entryRepo.append(channelId, streamId, _entry(2, payloadByte: 20));

        // Both CountMaterializer and SumMaterializer are StateMaterializer<int>,
        // so registering SumMaterializer replaces CountMaterializer.
        service.register(channelId, streamId, CountMaterializer());
        var state = await service.getState<int>(channelId, streamId);
        expect(state, equals(2));

        service.register(channelId, streamId, SumMaterializer());
        state = await service.getState<int>(channelId, streamId);
        expect(state, equals(30));
      });

      test('getState returns null for unregistered type', () async {
        service.register(channelId, streamId, CountMaterializer());
        final state = await service.getState<String>(channelId, streamId);
        expect(state, isNull);
      });
    });

    group('incremental fold', () {
      test('foldEntries accumulates state incrementally', () async {
        service.register(channelId, streamId, CountMaterializer());

        // Initialize
        await service.getState<int>(channelId, streamId);
        expect(await service.getState<int>(channelId, streamId), equals(0));

        // Fold one at a time
        final e1 = _entry(1);
        await entryRepo.append(channelId, streamId, e1);
        await service.foldEntries(channelId, streamId, [e1]);
        expect(await service.getState<int>(channelId, streamId), equals(1));

        final e2 = _entry(2);
        await entryRepo.append(channelId, streamId, e2);
        await service.foldEntries(channelId, streamId, [e2]);
        expect(await service.getState<int>(channelId, streamId), equals(2));
      });

      test('foldEntries handles batch of entries', () async {
        service.register(channelId, streamId, CountMaterializer());
        await service.getState<int>(channelId, streamId);

        final entries = [_entry(1), _entry(2), _entry(3)];
        for (final e in entries) {
          await entryRepo.append(channelId, streamId, e);
        }
        await service.foldEntries(channelId, streamId, entries);
        expect(await service.getState<int>(channelId, streamId), equals(3));
      });

      test('foldEntries is no-op when no materializer registered', () async {
        // Should not throw
        await service.foldEntries(channelId, streamId, [_entry(1)]);
      });
    });

    group('out-of-order rebuild', () {
      test('containsOutOfOrderEntries triggers full rebuild', () async {
        final e1 = _entry(1, payloadByte: 10);
        final e2 = _entry(2, payloadByte: 20);
        await entryRepo.append(channelId, streamId, e1);
        await entryRepo.append(channelId, streamId, e2);

        service.register(channelId, streamId, SumMaterializer());
        await service.getState<int>(channelId, streamId);
        expect(await service.getState<int>(channelId, streamId), equals(30));

        // Insert an out-of-order entry and rebuild
        final e3 = _entry(3, payloadByte: 5);
        await entryRepo.append(channelId, streamId, e3);
        await service.foldEntries(channelId, streamId, [
          e3,
        ], containsOutOfOrderEntries: true);

        // Full rebuild reads all 3 entries from repo
        expect(await service.getState<int>(channelId, streamId), equals(35));
      });
    });

    group('cursor support', () {
      test('startup with cursor folds only entries after cursor', () async {
        // Pre-populate entries
        await entryRepo.append(channelId, streamId, _entry(100));
        await entryRepo.append(channelId, streamId, _entry(200));
        await entryRepo.append(channelId, streamId, _entry(300));

        // Materializer claims cursor at Hlc(200, 0) — should fold only entry 300
        final mat = CursorAwareMaterializer(storedCursor: 'Hlc(200:0)');
        service.register(channelId, streamId, mat);

        final state = await service.getState<int>(channelId, streamId);
        // Initial state was 100 (from cache), plus 1 folded entry = 101
        expect(state, equals(101));
        expect(mat.initialCallCount, equals(1));
        expect(mat.lastIsReset, isFalse);
      });

      test('null cursor folds all entries from scratch', () async {
        await entryRepo.append(channelId, streamId, _entry(100));
        await entryRepo.append(channelId, streamId, _entry(200));

        final mat = CursorAwareMaterializer(storedCursor: null);
        service.register(channelId, streamId, mat);

        final state = await service.getState<int>(channelId, streamId);
        // Initial state 100 + 2 entries = 102
        expect(state, equals(102));
      });

      test('invalid cursor triggers full rebuild', () async {
        await entryRepo.append(channelId, streamId, _entry(100));
        await entryRepo.append(channelId, streamId, _entry(200));

        final mat = CursorAwareMaterializer(storedCursor: 'garbage');
        service.register(channelId, streamId, mat);

        final state = await service.getState<int>(channelId, streamId);
        // Full rebuild: initial(isReset: true) returns 0, then folds 2 entries
        expect(state, equals(2));
        // initial called twice: once for normal init, then for reset
        expect(mat.initialCallCount, equals(2));
      });

      test('save is called with cursor after initialization', () async {
        await entryRepo.append(channelId, streamId, _entry(100));
        await entryRepo.append(channelId, streamId, _entry(200));

        final mat = CursorAwareMaterializer();
        service.register(channelId, streamId, mat);
        await service.getState<int>(channelId, streamId);

        expect(mat.savedCursors, hasLength(1));
        // Full fold position: timestamp|author|sequence (COR3-27 — the
        // timestamp alone cannot disambiguate HLC ties across authors).
        expect(mat.savedCursors.first, equals('Hlc(200:0)|node|200'));
      });

      test('save is called once per foldEntries batch', () async {
        final mat = CursorAwareMaterializer();
        service.register(channelId, streamId, mat);
        await service.getState<int>(channelId, streamId);

        // Clear saves from initialization
        mat.savedCursors.clear();
        mat.savedStates.clear();

        final entries = [_entry(300), _entry(400), _entry(500)];
        for (final e in entries) {
          await entryRepo.append(channelId, streamId, e);
        }
        await service.foldEntries(channelId, streamId, entries);

        // Only one save call for the whole batch
        expect(mat.savedCursors, hasLength(1));
        expect(mat.savedCursors.first, equals('Hlc(500:0)|node|500'));
      });
    });

    group('stateStream', () {
      test('returns null when no materializer registered', () {
        final stream = service.getStateStream<int>(channelId, streamId);
        expect(stream, isNull);
      });

      test('emits state updates on fold', () async {
        service.register(channelId, streamId, CountMaterializer());

        final emissions = <int>[];
        final stream = service.getStateStream<int>(channelId, streamId)!;
        final sub = stream.listen(emissions.add);

        // Initialize (emits initial state)
        await service.getState<int>(channelId, streamId);
        await Future.delayed(Duration.zero);
        expect(emissions, equals([0]));

        // Fold entries
        final e1 = _entry(1);
        await entryRepo.append(channelId, streamId, e1);
        await service.foldEntries(channelId, streamId, [e1]);
        await Future.delayed(Duration.zero);
        expect(emissions, equals([0, 1]));

        await sub.cancel();
      });
    });

    group('reset', () {
      test('reset calls initial with isReset true and re-folds all', () async {
        await entryRepo.append(channelId, streamId, _entry(1));
        await entryRepo.append(channelId, streamId, _entry(2));

        final mat = CursorAwareMaterializer(storedCursor: 'Hlc(1:0)');
        service.register(channelId, streamId, mat);

        // Initialize — folds entries after cursor
        await service.getState<int>(channelId, streamId);
        expect(mat.initialCallCount, equals(1));
        expect(mat.lastIsReset, isFalse);

        // Reset — should call initial(isReset: true) and refold all
        await service.reset(channelId, streamId);
        expect(mat.lastIsReset, isTrue);

        final state = await service.getState<int>(channelId, streamId);
        // Reset: initial returns 0, folds 2 entries = 2
        expect(state, equals(2));
      });
    });

    group('multiple materializers per stream', () {
      test('two materializers with different types coexist', () async {
        await entryRepo.append(channelId, streamId, _entry(1, payloadByte: 10));
        await entryRepo.append(channelId, streamId, _entry(2, payloadByte: 20));

        service.register(channelId, streamId, CountMaterializer());
        service.register(channelId, streamId, LastAuthorMaterializer());

        final count = await service.getState<int>(channelId, streamId);
        final author = await service.getState<String>(channelId, streamId);

        expect(count, equals(2));
        expect(author, equals('node'));
      });

      test('registering different type does not dispose existing', () async {
        service.register(channelId, streamId, CountMaterializer());
        final intStream = service.getStateStream<int>(channelId, streamId)!;

        // Register a different type — int materializer should survive
        service.register(channelId, streamId, LastAuthorMaterializer());

        // int stream should still be open
        final emissions = <int>[];
        final sub = intStream.listen(emissions.add);

        await service.getState<int>(channelId, streamId);
        await Future.delayed(Duration.zero);
        expect(emissions, equals([0]));

        await sub.cancel();
      });

      test('foldEntries fans out to all registered materializers', () async {
        service.register(channelId, streamId, CountMaterializer());
        service.register(channelId, streamId, LastAuthorMaterializer());

        // Initialize both
        await service.getState<int>(channelId, streamId);
        await service.getState<String>(channelId, streamId);

        final e1 = _entry(1);
        await entryRepo.append(channelId, streamId, e1);
        await service.foldEntries(channelId, streamId, [e1]);

        expect(await service.getState<int>(channelId, streamId), equals(1));
        expect(
          await service.getState<String>(channelId, streamId),
          equals('node'),
        );
      });

      test('each type has independent state stream', () async {
        service.register(channelId, streamId, CountMaterializer());
        service.register(channelId, streamId, LastAuthorMaterializer());

        final intEmissions = <int>[];
        final strEmissions = <String>[];

        final intSub = service
            .getStateStream<int>(channelId, streamId)!
            .listen(intEmissions.add);
        final strSub = service
            .getStateStream<String>(channelId, streamId)!
            .listen(strEmissions.add);

        // Initialize both
        await service.getState<int>(channelId, streamId);
        await service.getState<String>(channelId, streamId);
        await Future.delayed(Duration.zero);

        expect(intEmissions, equals([0]));
        expect(strEmissions, equals(['']));

        // Fold an entry
        final e1 = _entry(1);
        await entryRepo.append(channelId, streamId, e1);
        await service.foldEntries(channelId, streamId, [e1]);
        await Future.delayed(Duration.zero);

        expect(intEmissions, equals([0, 1]));
        expect(strEmissions, equals(['', 'node']));

        await intSub.cancel();
        await strSub.cancel();
      });

      test('reset rebuilds all materializers for the stream', () async {
        await entryRepo.append(channelId, streamId, _entry(1));
        await entryRepo.append(channelId, streamId, _entry(2));

        service.register(channelId, streamId, CountMaterializer());
        service.register(channelId, streamId, LastAuthorMaterializer());

        // Initialize both
        await service.getState<int>(channelId, streamId);
        await service.getState<String>(channelId, streamId);

        await service.reset(channelId, streamId);

        final count = await service.getState<int>(channelId, streamId);
        final author = await service.getState<String>(channelId, streamId);

        expect(count, equals(2));
        expect(author, equals('node'));
      });

      test('disposeChannel disposes all types for the channel', () async {
        service.register(channelId, streamId, CountMaterializer());
        service.register(channelId, streamId, LastAuthorMaterializer());

        await service.disposeChannel(channelId);

        expect(service.getStateStream<int>(channelId, streamId), isNull);
        expect(service.getStateStream<String>(channelId, streamId), isNull);
      });
    });

    group('dispose', () {
      test('disposeChannel closes stream controllers for channel', () async {
        service.register(channelId, streamId, CountMaterializer());
        final stream = service.getStateStream<int>(channelId, streamId)!;

        await service.disposeChannel(channelId);

        // After disposal, getStateStream returns null (entry removed)
        expect(service.getStateStream<int>(channelId, streamId), isNull);

        // The old stream should be done
        final completer = Completer<void>();
        stream.listen(null, onDone: completer.complete);
        await completer.future;
      });

      test('disposeChannel does not affect other channels', () async {
        final otherChannelId = ChannelId('ch2');
        service.register(channelId, streamId, CountMaterializer());
        service.register(otherChannelId, streamId, CountMaterializer());

        await service.disposeChannel(channelId);

        expect(service.getStateStream<int>(channelId, streamId), isNull);
        expect(
          service.getStateStream<int>(otherChannelId, streamId),
          isNotNull,
        );
      });

      test('disposeAll clears all state', () async {
        service.register(channelId, streamId, CountMaterializer());
        service.register(ChannelId('ch2'), streamId, CountMaterializer());

        await service.disposeAll();

        expect(service.getStateStream<int>(channelId, streamId), isNull);
        expect(service.getStateStream<int>(ChannelId('ch2'), streamId), isNull);
      });
    });
  });
}
