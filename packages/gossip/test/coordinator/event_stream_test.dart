import 'dart:typed_data';

import 'package:gossip/src/sync/application/channel_service.dart';
import 'package:gossip/src/sync/application/materialization/materialization_service.dart';
import 'package:gossip/src/sync/domain/aggregates/channel_aggregate.dart';
import 'package:gossip/src/sync/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/sync/domain/interfaces/state_materializer.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/coordinator/event_stream.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_channel_repository.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_entry_repository.dart';
import 'package:test/test.dart';

// Test materializer that counts entries
class CountMaterializer extends StateMaterializer<int> {
  @override
  (int, String?) initial({required bool isReset}) => (0, null);

  @override
  int fold(int state, LogEntry entry) => state + 1;
}

// Test materializer that sums payload values
class SumMaterializer extends StateMaterializer<int> {
  @override
  (int, String?) initial({required bool isReset}) => (0, null);

  @override
  int fold(int state, LogEntry entry) {
    // Interpret first byte of payload as the value to add
    final value = entry.payload.isNotEmpty ? entry.payload[0] : 0;
    return state + value;
  }
}

// Test materializer that tracks the last entry's author
class LastAuthorMaterializer extends StateMaterializer<String> {
  @override
  (String, String?) initial({required bool isReset}) => ('', null);

  @override
  String fold(String state, LogEntry entry) => entry.author.value;
}

// Probe materializer that records whether the fold engine ever reached it —
// used to observe resetState's stream-existence guard from outside the
// materialization service (which has no other externally visible signal
// for "did a rebuild happen").
class _RecordingMaterializer extends StateMaterializer<int> {
  int initialCallCount = 0;

  @override
  (int, String?) initial({required bool isReset}) {
    initialCallCount++;
    return (0, null);
  }

  @override
  int fold(int state, LogEntry entry) => state + 1;
}

void main() {
  group('EventStream', () {
    late ChannelId channelId;
    late StreamId streamId;
    late NodeId localNode;
    late InMemoryChannelRepository channelRepo;
    late InMemoryEntryRepository entryRepo;
    late ChannelService channelService;
    late ChannelAggregate channel;

    setUp(() async {
      channelId = ChannelId('channel1');
      streamId = StreamId('stream1');
      localNode = NodeId('node1');
      channelRepo = InMemoryChannelRepository();
      entryRepo = InMemoryEntryRepository();
      channelService = ChannelService(
        localNode: localNode,
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        channelRepository: channelRepo,
        entryRepository: entryRepo,
        materializationService: MaterializationService(
          entryRepository: entryRepo,
        ),
      );

      // Create channel and stream
      channel = ChannelAggregate(id: channelId, localNode: localNode);
      channel.createStream(
        streamId,
        const KeepAllRetention(),
        occurredAt: DateTime.now(),
      );
      await channelRepo.save(channel);
    });

    test('constructor creates facade with id', () {
      final facade = EventStream(
        id: streamId,
        channelId: channelId,
        service: channelService,
      );

      expect(facade.id, equals(streamId));
    });

    test('append creates entry with payload', () async {
      final facade = EventStream(
        id: streamId,
        channelId: channelId,
        service: channelService,
      );

      final payload = Uint8List.fromList([1, 2, 3]);
      await facade.append(payload);

      // Verify entry was stored
      final entries = await channelService.getEntries(channelId, streamId);
      expect(entries.length, equals(1));
      expect(entries[0].author, equals(localNode));
      expect(entries[0].sequence, equals(1));
      expect(entries[0].payload, equals(payload));
    });

    test('getAll returns all entries in stream', () async {
      final facade = EventStream(
        id: streamId,
        channelId: channelId,
        service: channelService,
      );

      // Append multiple entries
      await facade.append(Uint8List.fromList([1]));
      await facade.append(Uint8List.fromList([2]));
      await facade.append(Uint8List.fromList([3]));

      // Get all entries
      final entries = await facade.getAll();
      expect(entries.length, equals(3));
      expect(entries[0].payload, equals(Uint8List.fromList([1])));
      expect(entries[1].payload, equals(Uint8List.fromList([2])));
      expect(entries[2].payload, equals(Uint8List.fromList([3])));
    });

    test(
      'registerMaterializer and getState computes materialized state',
      () async {
        final facade = EventStream(
          id: streamId,
          channelId: channelId,
          service: channelService,
        );

        // Register materializer
        await facade.registerMaterializer(CountMaterializer());

        // Append entries
        await facade.append(Uint8List.fromList([1]));
        await facade.append(Uint8List.fromList([2]));
        await facade.append(Uint8List.fromList([3]));

        // Get materialized state - should count all entries
        final count = await facade.getState<int>();
        expect(count, equals(3));
      },
    );

    test('getState returns null when no materializer registered', () async {
      final facade = EventStream(
        id: streamId,
        channelId: channelId,
        service: channelService,
      );

      // Append entries without registering materializer
      await facade.append(Uint8List.fromList([1]));
      await facade.append(Uint8List.fromList([2]));

      // Should return null when no materializer
      final count = await facade.getState<int>();
      expect(count, isNull);
    });

    test('materializer can compute sum of payload values', () async {
      final facade = EventStream(
        id: streamId,
        channelId: channelId,
        service: channelService,
      );

      // Register sum materializer
      await facade.registerMaterializer(SumMaterializer());

      // Append entries with numeric payloads
      await facade.append(Uint8List.fromList([10])); // Add 10
      await facade.append(Uint8List.fromList([20])); // Add 20
      await facade.append(Uint8List.fromList([5])); // Add 5

      // Get materialized state - should sum all values
      final sum = await facade.getState<int>();
      expect(sum, equals(35)); // 10 + 20 + 5
    });

    test('materializer can be replaced with different one', () async {
      final facade = EventStream(
        id: streamId,
        channelId: channelId,
        service: channelService,
      );

      // Register count materializer
      await facade.registerMaterializer(CountMaterializer());

      // Append entries
      await facade.append(Uint8List.fromList([10]));
      await facade.append(Uint8List.fromList([20]));

      // Should count entries (2)
      var result = await facade.getState<int>();
      expect(result, equals(2));

      // Replace with sum materializer
      await facade.registerMaterializer(SumMaterializer());

      // Should now sum values (30)
      result = await facade.getState<int>();
      expect(result, equals(30)); // 10 + 20
    });

    test('multiple materializers with different types coexist', () async {
      final facade = EventStream(
        id: streamId,
        channelId: channelId,
        service: channelService,
      );

      await facade.registerMaterializer(CountMaterializer());
      await facade.registerMaterializer(LastAuthorMaterializer());

      await facade.append(Uint8List.fromList([1]));
      await facade.append(Uint8List.fromList([2]));

      final count = await facade.getState<int>();
      final author = await facade.getState<String>();

      expect(count, equals(2));
      expect(author, equals('node1'));
    });

    group('stream existence checks', () {
      test('append throws StateError when stream does not exist', () async {
        // Create facade for non-existent stream
        final nonExistentStreamId = StreamId('nonexistent');
        final facade = EventStream(
          id: nonExistentStreamId,
          channelId: channelId,
          service: channelService,
        );

        // Appending to a stream that was never created is caller misuse:
        // silently dropping the payload would be permanent, invisible data
        // loss (audit COR3-3).
        await expectLater(
          facade.append(Uint8List.fromList([1, 2, 3])),
          throwsStateError,
        );

        // Verify no entries were created (stream doesn't exist)
        final entries = await facade.getAll();
        expect(entries, isEmpty);
      });

      test('getAll returns empty list when stream does not exist', () async {
        // Create facade for non-existent stream
        final nonExistentStreamId = StreamId('nonexistent');
        final facade = EventStream(
          id: nonExistentStreamId,
          channelId: channelId,
          service: channelService,
        );

        // getAll should return empty list, not throw
        final entries = await facade.getAll();
        expect(entries, isEmpty);
      });

      test('getState returns null when stream does not exist', () async {
        // Create facade for non-existent stream
        final nonExistentStreamId = StreamId('nonexistent');
        final facade = EventStream(
          id: nonExistentStreamId,
          channelId: channelId,
          service: channelService,
        );

        // Register materializer
        await facade.registerMaterializer(CountMaterializer());

        // getState should return null for non-existent stream
        final state = await facade.getState<int>();
        expect(state, isNull);
      });

      test(
        'registerMaterializer works even when stream does not exist',
        () async {
          // Create facade for non-existent stream
          final nonExistentStreamId = StreamId('nonexistent');
          final facade = EventStream(
            id: nonExistentStreamId,
            channelId: channelId,
            service: channelService,
          );

          // Should not throw
          await facade.registerMaterializer(CountMaterializer());

          // getState should return null
          final state = await facade.getState<int>();
          expect(state, isNull);
        },
      );

      test(
        'resetState is a no-op when stream does not exist (mirrors getState)',
        () async {
          // Create facade for non-existent stream
          final nonExistentStreamId = StreamId('nonexistent');
          final facade = EventStream(
            id: nonExistentStreamId,
            channelId: channelId,
            service: channelService,
          );

          // A materializer can be registered against a stream id that
          // doesn't exist in the channel yet (see the test above) — so
          // resetState must check existence itself rather than relying on
          // "nothing registered" to make it a no-op.
          final materializer = _RecordingMaterializer();
          await facade.registerMaterializer(materializer);

          await facade.resetState();

          // If resetState reached the materialization service, the full
          // rebuild path would have called initial(isReset: true) at least
          // once.
          expect(materializer.initialCallCount, equals(0));
        },
      );
    });

    group('retentionPolicy', () {
      late EventStream facade;

      setUp(() {
        facade = EventStream(
          id: streamId,
          channelId: channelId,
          service: channelService,
        );
      });

      test('returns the retention policy for the stream', () async {
        final policy = await facade.retentionPolicy;
        expect(policy, isNotNull);
      });

      test('returns TimeBasedRetention when set', () async {
        final timedStreamId = StreamId('timed');
        await channelService.createStream(
          channelId,
          timedStreamId,
          TimeBasedRetention(const Duration(seconds: 10)),
        );
        final timedFacade = EventStream(
          id: timedStreamId,
          channelId: channelId,
          service: channelService,
        );
        expect(await timedFacade.retentionPolicy, isA<TimeBasedRetention>());
      });
    });

    group('compact', () {
      late EventStream timedFacade;
      final timedStreamId = StreamId('timed');

      setUp(() async {
        await channelService.createStream(
          channelId,
          timedStreamId,
          TimeBasedRetention(const Duration(seconds: 5)),
        );
        timedFacade = EventStream(
          id: timedStreamId,
          channelId: channelId,
          service: channelService,
        );
      });

      test('removes entries older than retention window', () async {
        final oldEntry = LogEntry(
          author: localNode,
          sequence: 1,
          timestamp: Hlc(1000, 0),
          payload: Uint8List.fromList([1]),
        );
        final recentEntry = LogEntry(
          author: localNode,
          sequence: 2,
          timestamp: Hlc(DateTime.now().millisecondsSinceEpoch, 0),
          payload: Uint8List.fromList([2]),
        );
        await entryRepo.append(channelId, timedStreamId, oldEntry);
        await entryRepo.append(channelId, timedStreamId, recentEntry);

        final result = await timedFacade.compact();

        expect(result, isNotNull);
        expect(result!.entriesRemoved, equals(1));
        expect(result.entriesRetained, equals(1));

        final remaining = await timedFacade.getAll();
        expect(remaining.length, equals(1));
        expect(remaining.first.sequence, equals(2));
      });

      test('returns null when nothing to prune', () async {
        await timedFacade.append(Uint8List.fromList([1]));
        final result = await timedFacade.compact();
        expect(result, isNull);
      });

      test('returns null when stream has no entries', () async {
        final result = await timedFacade.compact();
        expect(result, isNull);
      });

      test('resets materializer state after compaction by default', () async {
        final materializer = CountMaterializer();
        await timedFacade.registerMaterializer(materializer);

        final oldEntry = LogEntry(
          author: localNode,
          sequence: 1,
          timestamp: Hlc(1000, 0),
          payload: Uint8List.fromList([1]),
        );
        final recentEntry = LogEntry(
          author: localNode,
          sequence: 2,
          timestamp: Hlc(DateTime.now().millisecondsSinceEpoch, 0),
          payload: Uint8List.fromList([2]),
        );
        await entryRepo.append(channelId, timedStreamId, oldEntry);
        await entryRepo.append(channelId, timedStreamId, recentEntry);

        // Fold entries so materializer state includes both
        await channelService.foldMergedEntries(channelId, timedStreamId, [
          oldEntry,
          recentEntry,
        ]);
        final beforeCount = await timedFacade.getState<int>();
        expect(beforeCount, equals(2));

        await timedFacade.compact();

        final afterCount = await timedFacade.getState<int>();
        expect(afterCount, equals(1));
      });

      test('preserves materializer state when resetState is false', () async {
        final materializer = CountMaterializer();
        await timedFacade.registerMaterializer(materializer);

        final oldEntry = LogEntry(
          author: localNode,
          sequence: 1,
          timestamp: Hlc(1000, 0),
          payload: Uint8List.fromList([1]),
        );
        final recentEntry = LogEntry(
          author: localNode,
          sequence: 2,
          timestamp: Hlc(DateTime.now().millisecondsSinceEpoch, 0),
          payload: Uint8List.fromList([2]),
        );
        await entryRepo.append(channelId, timedStreamId, oldEntry);
        await entryRepo.append(channelId, timedStreamId, recentEntry);

        await channelService.foldMergedEntries(channelId, timedStreamId, [
          oldEntry,
          recentEntry,
        ]);
        final beforeCount = await timedFacade.getState<int>();
        expect(beforeCount, equals(2));

        await timedFacade.compact(resetState: false);

        final afterCount = await timedFacade.getState<int>();
        expect(afterCount, equals(2));
      });
    });
  });
}
