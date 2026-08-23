import 'dart:typed_data';

import 'package:gossip/src/sync/application/channel_service.dart';
import 'package:gossip/src/sync/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/coordinator/event_stream.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_channel_repository.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_entry_repository.dart';
import 'package:test/test.dart';

void main() {
  group('EventStream.compact', () {
    test('reports the real version vectors, and compaction never regresses '
        'them', () async {
      final localNode = NodeId('local');
      final channelId = ChannelId('ch1');
      final streamId = StreamId('s1');
      final entryRepository = InMemoryEntryRepository();
      final service = ChannelService(
        localNode: localNode,
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        channelRepository: InMemoryChannelRepository(),
        entryRepository: entryRepository,
      );
      await service.createChannel(channelId);
      await service.createStream(
        channelId,
        streamId,
        const CountBasedRetention(1),
      );
      for (var i = 0; i < 3; i++) {
        await service.appendEntry(
          channelId,
          streamId,
          Uint8List.fromList([i]),
        );
      }

      final stream = EventStream(
        id: streamId,
        channelId: channelId,
        channelService: service,
      );
      final result = await stream.compact(resetState: false);

      expect(result, isNotNull);
      expect(result!.entriesRemoved, equals(2));
      final expectedVersion = VersionVector({localNode: 3});
      expect(
        result.oldBaseVersion,
        equals(expectedVersion),
        reason: 'callers must get real data, not fabricated empty vectors',
      );
      expect(
        result.newBaseVersion,
        equals(expectedVersion),
        reason: 'compaction must never change the advertised version',
      );

      // End-to-end H6 guard: sequence allocation continues past pruned
      // entries.
      await service.appendEntry(channelId, streamId, Uint8List.fromList([9]));
      final entries = await entryRepository.getAll(channelId, streamId);
      expect(entries.map((e) => e.sequence), contains(4));
    });
  });
}
