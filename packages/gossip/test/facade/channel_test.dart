import 'package:gossip/src/application/services/channel_service.dart';
import 'package:gossip/src/domain/aggregates/channel_aggregate.dart';
import 'package:gossip/src/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/facade/channel.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_channel_repository.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_local_node_repository.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:test/test.dart';

void main() {
  group('Channel', () {
    late ChannelId channelId;
    late NodeId localNode;
    late NodeId peer1;
    late InMemoryChannelRepository channelRepo;
    late InMemoryEntryRepository entryRepo;
    late ChannelService channelService;
    late ChannelAggregate channel;

    setUp(() async {
      channelId = ChannelId('channel1');
      localNode = NodeId('local');
      peer1 = NodeId('peer1');
      channelRepo = InMemoryChannelRepository();
      entryRepo = InMemoryEntryRepository();
      channelService = ChannelService(
        localNode: localNode,
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        channelRepository: channelRepo,
        entryRepository: entryRepo,
      );

      // Create channel
      channel = ChannelAggregate(id: channelId, localNode: localNode);
      await channelRepo.save(channel);
    });

    test('constructor creates facade with id', () {
      final facade = Channel(id: channelId, channelService: channelService);

      expect(facade.id, equals(channelId));
    });

    test('members includes local node by default', () async {
      final facade = Channel(id: channelId, channelService: channelService);

      final members = await facade.members;
      expect(members, contains(localNode));
      expect(members.length, equals(1));
    });

    test('addMember adds member to channel', () async {
      final facade = Channel(id: channelId, channelService: channelService);

      await facade.addMember(peer1);

      final members = await facade.members;
      expect(members, contains(peer1));
    });

    test('removeMember removes member from channel', () async {
      final facade = Channel(id: channelId, channelService: channelService);

      await facade.addMember(peer1);
      await facade.removeMember(peer1);

      final members = await facade.members;
      expect(members, isNot(contains(peer1)));
    });

    test('streamIds returns empty list initially', () async {
      final facade = Channel(id: channelId, channelService: channelService);

      final streamIds = await facade.streamIds;
      expect(streamIds, isEmpty);
    });

    test('getOrCreateStream creates and returns stream facade', () async {
      final facade = Channel(id: channelId, channelService: channelService);

      final streamId = StreamId('stream1');
      final streamFacade = await facade.getOrCreateStream(
        streamId,
        retention: const KeepAllRetention(),
      );

      expect(streamFacade.id, equals(streamId));

      // Verify stream was created
      final streamIds = await facade.streamIds;
      expect(streamIds, contains(streamId));
    });

    test('getStream returns facade even for non-existent stream', () async {
      final facade = Channel(id: channelId, channelService: channelService);

      // getStream always returns a facade (operations fail if stream doesn't exist)
      final streamFacade = facade.getStream(StreamId('nonexistent'));
      expect(streamFacade, isNotNull);
      expect(streamFacade.id, equals(StreamId('nonexistent')));
    });

    test('getStream returns facade for existing stream', () async {
      final facade = Channel(id: channelId, channelService: channelService);

      final streamId = StreamId('stream1');
      await facade.getOrCreateStream(
        streamId,
        retention: const KeepAllRetention(),
      );

      final streamFacade = facade.getStream(streamId);
      expect(streamFacade, isNotNull);
      expect(streamFacade.id, equals(streamId));
    });
  });
}
