import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gossip/src/sync/application/channel_service.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/sync/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_channel_repository.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_entry_repository.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:gossip/src/shared/domain/errors/sync_error.dart';

void main() {
  group('ChannelService', () {
    late NodeId localNode;
    late InMemoryChannelRepository channelRepo;
    late InMemoryEntryRepository entryRepo;
    late List<SyncError> errors;
    late ChannelService service;
    final channelId = ChannelId('channel-1');
    final streamId = StreamId('stream-1');

    setUp(() {
      localNode = NodeId('local');
      channelRepo = InMemoryChannelRepository();
      entryRepo = InMemoryEntryRepository();
      errors = <SyncError>[];
      service = ChannelService(
        localNode: localNode,
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        channelRepository: channelRepo,
        entryRepository: entryRepo,
        onError: errors.add,
      );
    });

    test(
      'createChannel creates new channel with local node as member',
      () async {
        await service.createChannel(channelId);

        final channel = await channelRepo.findById(channelId);
        expect(channel, isNotNull);
        expect(channel!.id, equals(channelId));
        expect(channel.hasMember(localNode), isTrue);
      },
    );

    test('addMember adds member to existing channel', () async {
      final peerId = NodeId('peer-1');

      await service.createChannel(channelId);
      await service.addMember(channelId, peerId);

      final channel = await channelRepo.findById(channelId);
      expect(channel!.hasMember(peerId), isTrue);
    });

    test('removeMember removes member from channel', () async {
      final peerId = NodeId('peer-1');

      await service.createChannel(channelId);
      await service.addMember(channelId, peerId);
      await service.removeMember(channelId, peerId);

      final channel = await channelRepo.findById(channelId);
      expect(channel!.hasMember(peerId), isFalse);
    });

    test('createStream creates stream in channel', () async {
      await service.createChannel(channelId);
      await service.createStream(channelId, streamId, KeepAllRetention());

      final channel = await channelRepo.findById(channelId);
      expect(channel!.hasStream(streamId), isTrue);
    });

    test('appendEntry appends entry to store with correct sequence', () async {
      final payload = Uint8List.fromList([1, 2, 3]);

      await service.createChannel(channelId);
      await service.createStream(channelId, streamId, KeepAllRetention());
      await service.appendEntry(channelId, streamId, payload);

      final entries = await entryRepo.getAll(channelId, streamId);
      expect(entries, hasLength(1));
      expect(entries[0].author, equals(localNode));
      expect(entries[0].sequence, equals(1));
      expect(entries[0].payload, equals(payload));
    });

    test('getEntries retrieves all entries from store', () async {
      await service.createChannel(channelId);
      await service.createStream(channelId, streamId, KeepAllRetention());
      await service.appendEntry(channelId, streamId, Uint8List.fromList([1]));
      await service.appendEntry(channelId, streamId, Uint8List.fromList([2]));

      final entries = await service.getEntries(channelId, streamId);

      expect(entries, hasLength(2));
      expect(entries[0].sequence, equals(1));
      expect(entries[1].sequence, equals(2));
    });

    group('removeChannel', () {
      test('removes channel from repository', () async {
        await service.createChannel(channelId);
        expect(await channelRepo.exists(channelId), isTrue);

        final removed = await service.removeChannel(channelId);

        expect(removed, isTrue);
        expect(await channelRepo.exists(channelId), isFalse);
      });

      test('clears entries from entry store', () async {
        await service.createChannel(channelId);
        await service.createStream(channelId, streamId, KeepAllRetention());
        await service.appendEntry(channelId, streamId, Uint8List.fromList([1]));
        await service.appendEntry(channelId, streamId, Uint8List.fromList([2]));

        expect(await entryRepo.getAll(channelId, streamId), hasLength(2));

        await service.removeChannel(channelId);

        expect(await entryRepo.getAll(channelId, streamId), isEmpty);
      });

      test('returns false for non-existent channel', () async {
        final removed = await service.removeChannel(ChannelId('non-existent'));

        expect(removed, isFalse);
      });

      test('returns false when repository is null', () async {
        // Bespoke wiring: this test exercises the missing-repository
        // branch itself, so it deliberately does not use the hoisted
        // `service` (which always has a channelRepository).
        final bareService = ChannelService(
          localNode: localNode,
          localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
          channelRepository: null,
        );

        final removed = await bareService.removeChannel(channelId);

        expect(removed, isFalse);
      });
    });

    group('error handling for non-existent channels', () {
      test('addMember emits error for non-existent channel', () async {
        await service.addMember(ChannelId('non-existent'), NodeId('peer1'));

        expect(errors, hasLength(1));
        expect(errors.first, isA<ChannelSyncError>());
        expect(
          (errors.first as ChannelSyncError).type,
          equals(SyncErrorType.storageFailure),
        );
      });

      test('removeMember emits error for non-existent channel', () async {
        await service.removeMember(ChannelId('non-existent'), NodeId('peer1'));

        expect(errors, hasLength(1));
        expect(errors.first, isA<ChannelSyncError>());
      });

      test('createStream emits error for non-existent channel', () async {
        await service.createStream(
          ChannelId('non-existent'),
          StreamId('stream1'),
          KeepAllRetention(),
        );

        expect(errors, hasLength(1));
        expect(errors.first, isA<ChannelSyncError>());
      });

      test('operations do not throw for non-existent channel', () async {
        // These should not throw - they should fail gracefully
        await expectLater(
          service.addMember(ChannelId('non-existent'), NodeId('peer1')),
          completes,
        );
        await expectLater(
          service.removeMember(ChannelId('non-existent'), NodeId('peer1')),
          completes,
        );
        await expectLater(
          service.createStream(
            ChannelId('non-existent'),
            StreamId('stream1'),
            KeepAllRetention(),
          ),
          completes,
        );
      });
    });
  });
}
