import 'dart:typed_data';

import 'package:gossip/src/shared/domain/events/domain_event.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/sync/application/channel_service.dart';
import 'package:gossip/src/sync/domain/events/sync_events.dart';
import 'package:gossip/src/sync/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_channel_repository.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_entry_repository.dart';
import 'package:test/test.dart';

void main() {
  group('ChannelService compaction observability', () {
    test('compacting a stream that removes entries emits exactly one '
        'StreamCompacted carrying the real result', () async {
      final localNode = NodeId('local');
      final channelId = ChannelId('ch1');
      final streamId = StreamId('s1');
      final events = <DomainEvent>[];

      final service = ChannelService(
        localNode: localNode,
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        channelRepository: InMemoryChannelRepository(),
        entryRepository: InMemoryEntryRepository(),
        onEvent: events.add,
      );
      await service.createChannel(channelId);
      await service.createStream(
        channelId,
        streamId,
        const CountBasedRetention(1),
      );
      for (var i = 0; i < 3; i++) {
        await service.appendEntry(channelId, streamId, Uint8List.fromList([i]));
      }
      events.clear();

      final result = await service.compactStream(channelId, streamId);

      expect(result, isNotNull);
      final compactionEvents = events.whereType<StreamCompacted>().toList();
      expect(
        compactionEvents,
        hasLength(1),
        reason: 'exactly one StreamCompacted per compacted stream',
      );
      final event = compactionEvents.single;
      expect(event.channelId, equals(channelId));
      expect(event.streamId, equals(streamId));
      expect(
        event.result,
        same(result),
        reason:
            'the event must carry the real result compactStream '
            'returns to its caller, not a re-derived copy',
      );
    });

    test('a no-op compaction (nothing removed) emits nothing', () async {
      final localNode = NodeId('local');
      final channelId = ChannelId('ch1');
      final streamId = StreamId('s1');
      final events = <DomainEvent>[];

      final service = ChannelService(
        localNode: localNode,
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        channelRepository: InMemoryChannelRepository(),
        entryRepository: InMemoryEntryRepository(),
        onEvent: events.add,
      );
      await service.createChannel(channelId);
      // Retention generous enough that nothing is ever pruned.
      await service.createStream(
        channelId,
        streamId,
        const CountBasedRetention(10),
      );
      for (var i = 0; i < 3; i++) {
        await service.appendEntry(channelId, streamId, Uint8List.fromList([i]));
      }
      events.clear();

      final result = await service.compactStream(channelId, streamId);

      expect(
        result,
        isNull,
        reason:
            'nothing needs pruning to report — compactStream '
            'itself already returns null for a no-op pass',
      );
      expect(
        events.whereType<StreamCompacted>(),
        isEmpty,
        reason: 'a no-op compaction must not be observable as an event',
      );
    });
  });
}
