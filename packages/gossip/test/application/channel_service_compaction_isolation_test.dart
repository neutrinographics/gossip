import 'dart:typed_data';

import 'package:gossip/src/application/services/channel_service.dart';
import 'package:gossip/src/domain/aggregates/channel_aggregate.dart';
import 'package:gossip/src/domain/errors/sync_error.dart';
import 'package:gossip/src/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_channel_repository.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_local_node_repository.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:test/test.dart';

/// A retention policy with a bug — the RetentionPolicy interface is public,
/// so a throwing implementation is an app bug the library must contain.
class _ThrowingRetention implements RetentionPolicy {
  @override
  List<LogEntry> compact(List<LogEntry> entries, Hlc now) =>
      throw StateError('buggy retention policy');

  @override
  bool get retainsAll => false;
}

void main() {
  test(
    'compactAll isolates a throwing stream: later streams still compact '
    'and the failure is reported (COR3-15)',
    () async {
      final localNode = NodeId('local');
      final channelId = ChannelId('ch1');
      final poison = StreamId('poison');
      final healthy = StreamId('healthy');
      final channelRepo = InMemoryChannelRepository();
      final entryRepo = InMemoryEntryRepository();
      final errors = <SyncError>[];

      final service = ChannelService(
        localNode: localNode,
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        channelRepository: channelRepo,
        entryRepository: entryRepo,
        onError: errors.add,
      );

      final channel = ChannelAggregate(id: channelId, localNode: localNode);
      // The poison stream is created first so it compacts first.
      channel.createStream(
        poison,
        _ThrowingRetention(),
        occurredAt: DateTime.now(),
      );
      channel.createStream(
        healthy,
        const CountBasedRetention(1),
        occurredAt: DateTime.now(),
      );
      await channelRepo.save(channel);

      for (final streamId in [poison, healthy]) {
        for (var seq = 1; seq <= 2; seq++) {
          await entryRepo.append(
            channelId,
            streamId,
            LogEntry(
              author: localNode,
              sequence: seq,
              timestamp: Hlc(1000 + seq, 0),
              payload: Uint8List.fromList([seq]),
            ),
          );
        }
      }

      // Without isolation the poison stream aborts the whole pass — every
      // 5 minutes, forever — and streams after it are never compacted.
      await service.compactAll();

      expect(
        await entryRepo.entryCount(channelId, healthy),
        equals(1),
        reason: 'the healthy stream must still be compacted',
      );
      expect(errors, isNotEmpty, reason: 'the failure must be reported');
    },
  );
}
