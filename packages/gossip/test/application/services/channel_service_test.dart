import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gossip/src/application/services/channel_service.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/log_entry_id.dart';
import 'package:gossip/src/domain/value_objects/version_vector.dart';
import 'package:gossip/src/domain/aggregates/channel_aggregate.dart';
import 'package:gossip/src/domain/interfaces/channel_repository.dart';
import 'package:gossip/src/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/domain/interfaces/entry_repository.dart';
import 'package:gossip/src/domain/errors/sync_error.dart';

// Fake repository for testing
class FakeChannelRepository implements ChannelRepository {
  final Map<ChannelId, ChannelAggregate> _channels = {};

  @override
  Future<ChannelAggregate?> findById(ChannelId id) async => _channels[id];

  @override
  Future<void> save(ChannelAggregate channel) async {
    _channels[channel.id] = channel;
  }

  @override
  Future<void> delete(ChannelId id) async {
    _channels.remove(id);
  }

  @override
  Future<List<ChannelId>> listIds() async => _channels.keys.toList();

  @override
  Future<bool> exists(ChannelId id) async => _channels.containsKey(id);

  @override
  Future<int> get count async => _channels.length;
}

// Fake entry store for testing
class FakeEntryRepository implements EntryRepository {
  final Map<ChannelId, Map<StreamId, List<LogEntry>>> _storage = {};

  List<LogEntry> _getAllSync(ChannelId channel, StreamId stream) {
    return _storage[channel]?[stream]?.toList() ?? [];
  }

  @override
  Future<void> append(
    ChannelId channel,
    StreamId stream,
    LogEntry entry,
  ) async {
    final channelMap = _storage.putIfAbsent(channel, () => {});
    final entries = channelMap.putIfAbsent(stream, () => []);
    entries.add(entry);
  }

  @override
  Future<void> appendAll(
    ChannelId channel,
    StreamId stream,
    List<LogEntry> entries,
  ) async {
    for (final entry in entries) {
      await append(channel, stream, entry);
    }
  }

  @override
  Future<List<LogEntry>> getAll(ChannelId channel, StreamId stream) async {
    return _getAllSync(channel, stream);
  }

  @override
  Future<List<LogEntry>> entriesSince(
    ChannelId channel,
    StreamId stream,
    VersionVector since,
  ) async {
    return [];
  }

  @override
  Future<List<LogEntry>> entriesForAuthorAfter(
    ChannelId channel,
    StreamId stream,
    NodeId author,
    int afterSequence,
  ) async {
    return [];
  }

  @override
  Future<int> latestSequence(
    ChannelId channel,
    StreamId stream,
    NodeId author,
  ) async {
    final entries = _getAllSync(channel, stream);
    final authorEntries = entries.where((e) => e.author == author);
    if (authorEntries.isEmpty) return 0;
    return authorEntries.map((e) => e.sequence).reduce((a, b) => a > b ? a : b);
  }

  @override
  Future<int> entryCount(ChannelId channel, StreamId stream) async {
    return _storage[channel]?[stream]?.length ?? 0;
  }

  @override
  Future<int> sizeBytes(ChannelId channel, StreamId stream) async {
    return 0;
  }

  @override
  Future<void> removeEntries(
    ChannelId channel,
    StreamId stream,
    List<LogEntryId> ids,
  ) async {}

  @override
  Future<void> clearStream(ChannelId channel, StreamId stream) async {
    _storage[channel]?.remove(stream);
  }

  @override
  Future<void> clearChannel(ChannelId channel) async {
    _storage.remove(channel);
  }

  @override
  Future<VersionVector> getVersionVector(
    ChannelId channel,
    StreamId stream,
  ) async {
    final entries = _getAllSync(channel, stream);
    if (entries.isEmpty) return VersionVector.empty;

    final versions = <NodeId, int>{};
    for (final entry in entries) {
      final current = versions[entry.author] ?? 0;
      if (entry.sequence > current) {
        versions[entry.author] = entry.sequence;
      }
    }
    return VersionVector(versions);
  }
}

void main() {
  group('ChannelService', () {
    test(
      'createChannel creates new channel with local node as member',
      () async {
        final localNode = NodeId('local');
        final repository = FakeChannelRepository();
        final service = ChannelService(
          localNode: localNode,
          channelRepository: repository,
        );
        final channelId = ChannelId('channel-1');

        await service.createChannel(channelId);

        final channel = await repository.findById(channelId);
        expect(channel, isNotNull);
        expect(channel!.id, equals(channelId));
        expect(channel.hasMember(localNode), isTrue);
      },
    );

    test('addMember adds member to existing channel', () async {
      final localNode = NodeId('local');
      final repository = FakeChannelRepository();
      final service = ChannelService(
        localNode: localNode,
        channelRepository: repository,
      );
      final channelId = ChannelId('channel-1');
      final peerId = NodeId('peer-1');

      await service.createChannel(channelId);
      await service.addMember(channelId, peerId);

      final channel = await repository.findById(channelId);
      expect(channel!.hasMember(peerId), isTrue);
    });

    test('removeMember removes member from channel', () async {
      final localNode = NodeId('local');
      final repository = FakeChannelRepository();
      final service = ChannelService(
        localNode: localNode,
        channelRepository: repository,
      );
      final channelId = ChannelId('channel-1');
      final peerId = NodeId('peer-1');

      await service.createChannel(channelId);
      await service.addMember(channelId, peerId);
      await service.removeMember(channelId, peerId);

      final channel = await repository.findById(channelId);
      expect(channel!.hasMember(peerId), isFalse);
    });

    test('createStream creates stream in channel', () async {
      final localNode = NodeId('local');
      final repository = FakeChannelRepository();
      final service = ChannelService(
        localNode: localNode,
        channelRepository: repository,
      );
      final channelId = ChannelId('channel-1');
      final streamId = StreamId('stream-1');

      await service.createChannel(channelId);
      await service.createStream(channelId, streamId, KeepAllRetention());

      final channel = await repository.findById(channelId);
      expect(channel!.hasStream(streamId), isTrue);
    });

    test('appendEntry appends entry to store with correct sequence', () async {
      final localNode = NodeId('local');
      final channelRepo = FakeChannelRepository();
      final entryRepo = FakeEntryRepository();
      final service = ChannelService(
        localNode: localNode,
        channelRepository: channelRepo,
        entryRepository: entryRepo,
      );
      final channelId = ChannelId('channel-1');
      final streamId = StreamId('stream-1');
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
      final localNode = NodeId('local');
      final channelRepo = FakeChannelRepository();
      final entryRepo = FakeEntryRepository();
      final service = ChannelService(
        localNode: localNode,
        channelRepository: channelRepo,
        entryRepository: entryRepo,
      );
      final channelId = ChannelId('channel-1');
      final streamId = StreamId('stream-1');

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
        final localNode = NodeId('local');
        final repository = FakeChannelRepository();
        final service = ChannelService(
          localNode: localNode,
          channelRepository: repository,
        );
        final channelId = ChannelId('channel-1');

        await service.createChannel(channelId);
        expect(await repository.exists(channelId), isTrue);

        final removed = await service.removeChannel(channelId);

        expect(removed, isTrue);
        expect(await repository.exists(channelId), isFalse);
      });

      test('clears entries from entry store', () async {
        final localNode = NodeId('local');
        final channelRepo = FakeChannelRepository();
        final entryRepo = FakeEntryRepository();
        final service = ChannelService(
          localNode: localNode,
          channelRepository: channelRepo,
          entryRepository: entryRepo,
        );
        final channelId = ChannelId('channel-1');
        final streamId = StreamId('stream-1');

        await service.createChannel(channelId);
        await service.createStream(channelId, streamId, KeepAllRetention());
        await service.appendEntry(channelId, streamId, Uint8List.fromList([1]));
        await service.appendEntry(channelId, streamId, Uint8List.fromList([2]));

        expect(await entryRepo.getAll(channelId, streamId), hasLength(2));

        await service.removeChannel(channelId);

        expect(await entryRepo.getAll(channelId, streamId), isEmpty);
      });

      test('returns false for non-existent channel', () async {
        final localNode = NodeId('local');
        final repository = FakeChannelRepository();
        final service = ChannelService(
          localNode: localNode,
          channelRepository: repository,
        );
        final channelId = ChannelId('non-existent');

        final removed = await service.removeChannel(channelId);

        expect(removed, isFalse);
      });

      test('returns false when repository is null', () async {
        final localNode = NodeId('local');
        final service = ChannelService(
          localNode: localNode,
          channelRepository: null,
        );
        final channelId = ChannelId('channel-1');

        final removed = await service.removeChannel(channelId);

        expect(removed, isFalse);
      });
    });

    group('error handling for non-existent channels', () {
      test('addMember emits error for non-existent channel', () async {
        final localNode = NodeId('local');
        final repository = FakeChannelRepository();
        final errors = <SyncError>[];
        final service = ChannelService(
          localNode: localNode,
          channelRepository: repository,
          onError: errors.add,
        );

        await service.addMember(ChannelId('non-existent'), NodeId('peer1'));

        expect(errors, hasLength(1));
        expect(errors.first, isA<ChannelSyncError>());
        expect(
          (errors.first as ChannelSyncError).type,
          equals(SyncErrorType.storageFailure),
        );
      });

      test('removeMember emits error for non-existent channel', () async {
        final localNode = NodeId('local');
        final repository = FakeChannelRepository();
        final errors = <SyncError>[];
        final service = ChannelService(
          localNode: localNode,
          channelRepository: repository,
          onError: errors.add,
        );

        await service.removeMember(ChannelId('non-existent'), NodeId('peer1'));

        expect(errors, hasLength(1));
        expect(errors.first, isA<ChannelSyncError>());
      });

      test('createStream emits error for non-existent channel', () async {
        final localNode = NodeId('local');
        final repository = FakeChannelRepository();
        final errors = <SyncError>[];
        final service = ChannelService(
          localNode: localNode,
          channelRepository: repository,
          onError: errors.add,
        );

        await service.createStream(
          ChannelId('non-existent'),
          StreamId('stream1'),
          KeepAllRetention(),
        );

        expect(errors, hasLength(1));
        expect(errors.first, isA<ChannelSyncError>());
      });

      test('operations do not throw for non-existent channel', () async {
        final localNode = NodeId('local');
        final repository = FakeChannelRepository();
        final service = ChannelService(
          localNode: localNode,
          channelRepository: repository,
        );

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
