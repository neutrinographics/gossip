import 'dart:typed_data';

import 'package:gossip/src/application/services/channel_service.dart';
import 'package:gossip/src/domain/aggregates/channel_aggregate.dart';
import 'package:gossip/src/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/domain/interfaces/state_materializer.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/facade/event_stream.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_channel_repository.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:test/test.dart';

// Test materializer that counts entries
class CountMaterializer implements StateMaterializer<int> {
  @override
  int initial() => 0;

  @override
  int fold(int state, LogEntry entry) => state + 1;
}

// Test materializer that sums payload values
class SumMaterializer implements StateMaterializer<int> {
  @override
  int initial() => 0;

  @override
  int fold(int state, LogEntry entry) {
    // Interpret first byte of payload as the value to add
    final value = entry.payload.isNotEmpty ? entry.payload[0] : 0;
    return state + value;
  }
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
        channelRepository: channelRepo,
        entryRepository: entryRepo,
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
        channelService: channelService,
      );

      expect(facade.id, equals(streamId));
    });

    test('append creates entry with payload', () async {
      final facade = EventStream(
        id: streamId,
        channelId: channelId,
        channelService: channelService,
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
        channelService: channelService,
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
          channelService: channelService,
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
        channelService: channelService,
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
        channelService: channelService,
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
        channelService: channelService,
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

    group('stream existence checks', () {
      test('append returns empty list when stream does not exist', () async {
        // Create facade for non-existent stream
        final nonExistentStreamId = StreamId('nonexistent');
        final facade = EventStream(
          id: nonExistentStreamId,
          channelId: channelId,
          channelService: channelService,
        );

        // append should not throw - should handle gracefully
        await facade.append(Uint8List.fromList([1, 2, 3]));

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
          channelService: channelService,
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
          channelService: channelService,
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
            channelService: channelService,
          );

          // Should not throw
          await facade.registerMaterializer(CountMaterializer());

          // getState should return null
          final state = await facade.getState<int>();
          expect(state, isNull);
        },
      );
    });
  });
}
