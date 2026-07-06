import 'dart:typed_data';

import 'package:gossip/src/application/services/channel_service.dart';
import 'package:gossip/src/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_channel_repository.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_local_node_repository.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:test/test.dart';

void main() {
  group('ChannelService concurrent appendEntry', () {
    test('interleaved appends never lose entries to sequence collisions',
        () async {
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
      await service.createStream(channelId, streamId, const KeepAllRetention());

      // Fire several appends WITHOUT awaiting between them. Each has
      // multiple awaits between reading latestSequence and appending, so
      // unserialized appends all read the same sequence and the duplicate
      // silently vanishes.
      final futures = [
        for (var i = 0; i < 5; i++)
          service.appendEntry(channelId, streamId, Uint8List.fromList([i])),
      ];
      await Future.wait(futures);

      final entries = await entryRepository.getAll(channelId, streamId);
      expect(
        entries.length,
        equals(5),
        reason: 'every appended payload must be stored — silent loss is the '
            'worst possible failure for a sync library',
      );
      expect(
        entries.map((e) => e.sequence).toSet(),
        equals({1, 2, 3, 4, 5}),
        reason: 'sequences must be allocated without collisions',
      );
    });
  });
}
