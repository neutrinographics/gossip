import 'dart:typed_data';

import 'package:gossip/src/sync/application/channel_service.dart';
import 'package:gossip/src/sync/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_channel_repository.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_entry_repository.dart';
import 'package:test/test.dart';

/// Part C item 8: `channel_service_append_race_test.dart` only interleaves
/// concurrent appends against each other, and
/// `channel_service_compaction_isolation_test.dart` only interleaves
/// compaction across DIFFERENT streams (isolating a throwing retention
/// policy) — neither exercises an append racing an in-flight compaction on
/// the SAME stream. `ChannelService.appendEntry` serializes appends to a
/// stream against each other via `_appendQueue`, but `compactStream` is NOT
/// part of that queue, so this is the one interleaving window the append
/// race test doesn't cover.
void main() {
  test('an append racing an in-flight compaction on the same stream: neither '
      'is lost, and sequence allocation stays monotonic', () async {
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
      const CountBasedRetention(2),
    );

    // Seed entries so compaction has something to prune.
    for (var i = 0; i < 3; i++) {
      await service.appendEntry(channelId, streamId, Uint8List.fromList([i]));
    }

    // Fire an append and a compaction WITHOUT awaiting between them.
    // compactStream isn't serialized against appendEntry's per-stream
    // queue, so this is the genuine interleaving window: both are
    // multi-await async functions racing on the same underlying storage
    // list.
    final appendFuture = service.appendEntry(
      channelId,
      streamId,
      Uint8List.fromList([99]),
    );
    final compactFuture = service.compactStream(channelId, streamId);

    await Future.wait([appendFuture, compactFuture]);

    final entries = await entryRepository.getAll(channelId, streamId);

    expect(
      entries.any(
        (e) => e.sequence == 4 && e.payload.length == 1 && e.payload[0] == 99,
      ),
      isTrue,
      reason:
          'the interleaved append must not be lost to a concurrent '
          'compaction, regardless of which one the scheduler runs first',
    );

    final sequences = entries.map((e) => e.sequence).toList()..sort();
    expect(
      sequences.toSet().length,
      equals(sequences.length),
      reason:
          'no duplicate/colliding sequence numbers — a compaction '
          'racing an append must never cause sequence reuse',
    );
    for (var i = 1; i < sequences.length; i++) {
      expect(
        sequences[i],
        greaterThan(sequences[i - 1]),
        reason: 'surviving sequences must stay strictly increasing',
      );
    }

    final latest = await entryRepository.latestSequence(
      channelId,
      streamId,
      localNode,
    );
    expect(
      latest,
      equals(4),
      reason:
          'the high-water mark must reflect the append even though '
          'compaction ran concurrently — it must never regress or skip',
    );
  });
}
