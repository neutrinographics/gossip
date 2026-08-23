import 'dart:typed_data';

import 'package:gossip/src/sync/application/channel_service.dart';
import 'package:gossip/src/sync/domain/aggregates/channel_aggregate.dart';
import 'package:gossip/src/shared/domain/errors/sync_error.dart';
import 'package:gossip/src/sync/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_channel_repository.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_entry_repository.dart';
import 'package:test/test.dart';

void main() {
  group('ChannelService payload size limit', () {
    late NodeId localNode;
    late InMemoryEntryRepository entryRepository;
    late List<SyncError> errors;
    late ChannelService service;

    setUp(() {
      localNode = NodeId('local');
      entryRepository = InMemoryEntryRepository();
      errors = <SyncError>[];
      service = ChannelService(
        localNode: localNode,
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        entryRepository: entryRepository,
        maxPayloadBytes: 1024,
        onError: errors.add,
      );
    });

    test(
      'appendEntry rejects an oversized payload with ArgumentError',
      () async {
        await expectLater(
          () => service.appendEntry(
            ChannelId('ch1'),
            StreamId('s1'),
            Uint8List(1025),
          ),
          throwsArgumentError,
        );

        expect(
          await entryRepository.entryCount(ChannelId('ch1'), StreamId('s1')),
          equals(0),
          reason: 'a rejected payload must not be stored',
        );
      },
    );

    test('appendEntry accepts a payload at exactly the limit', () async {
      final channelRepo = InMemoryChannelRepository();
      final channel = ChannelAggregate(
        id: ChannelId('ch1'),
        localNode: localNode,
      );
      channel.createStream(
        StreamId('s1'),
        const KeepAllRetention(),
        occurredAt: DateTime.now(),
      );
      await channelRepo.save(channel);
      final serviceWithStream = ChannelService(
        localNode: localNode,
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        channelRepository: channelRepo,
        entryRepository: entryRepository,
        maxPayloadBytes: 1024,
        onError: errors.add,
      );

      await serviceWithStream.appendEntry(
        ChannelId('ch1'),
        StreamId('s1'),
        Uint8List(1024),
      );

      expect(
        await entryRepository.entryCount(ChannelId('ch1'), StreamId('s1')),
        equals(1),
        reason: 'an at-limit payload is legal and must be stored',
      );
      expect(errors, isEmpty);
    });

    test('appendEntry to a nonexistent stream throws StateError', () async {
      await expectLater(
        service.appendEntry(ChannelId('ch1'), StreamId('s1'), Uint8List(8)),
        throwsStateError,
      );
    });
  });
}
