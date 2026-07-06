import 'dart:typed_data';

import 'package:gossip/src/application/services/channel_service.dart';
import 'package:gossip/src/domain/errors/sync_error.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_local_node_repository.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
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

    test('appendEntry rejects an oversized payload with ArgumentError', () async {
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
    });

    test('appendEntry accepts a payload at exactly the limit', () async {
      // No stream exists, so the append is skipped via ErrorCallback —
      // but it must NOT throw: the payload itself is legal.
      await service.appendEntry(
        ChannelId('ch1'),
        StreamId('s1'),
        Uint8List(1024),
      );
      expect(errors, isNotEmpty); // missing-stream error, not a size error
    });
  });
}
