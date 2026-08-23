import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/sync/domain/aggregates/channel_aggregate.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_channel_repository.dart';

void main() {
  group('InMemoryChannelRepository', () {
    test('save and findById stores and retrieves channel', () async {
      final repository = InMemoryChannelRepository();
      final localNode = NodeId('local');
      final channelId = ChannelId('channel-1');
      final channel = ChannelAggregate(id: channelId, localNode: localNode);

      await repository.save(channel);
      final retrieved = await repository.findById(channelId);

      expect(retrieved, isNotNull);
      expect(retrieved!.id, equals(channelId));
      expect(retrieved.hasMember(localNode), isTrue);
    });

    test('delete removes channel from repository', () async {
      final repository = InMemoryChannelRepository();
      final localNode = NodeId('local');
      final channelId = ChannelId('channel-1');
      final channel = ChannelAggregate(id: channelId, localNode: localNode);

      await repository.save(channel);
      expect(await repository.exists(channelId), isTrue);

      await repository.delete(channelId);

      expect(await repository.exists(channelId), isFalse);
      expect(await repository.findById(channelId), isNull);
    });

    test(
      'listIds returns all channel IDs and count returns correct number',
      () async {
        final repository = InMemoryChannelRepository();
        final localNode = NodeId('local');
        final channel1 = ChannelAggregate(
          id: ChannelId('channel-1'),
          localNode: localNode,
        );
        final channel2 = ChannelAggregate(
          id: ChannelId('channel-2'),
          localNode: localNode,
        );

        await repository.save(channel1);
        await repository.save(channel2);

        final ids = await repository.listIds();
        expect(ids, hasLength(2));
        expect(ids, contains(channel1.id));
        expect(ids, contains(channel2.id));
        expect(await repository.count, equals(2));
      },
    );

    test('clearAll removes all channels', () async {
      final repository = InMemoryChannelRepository();
      final localNode = NodeId('local');

      final channel1 = ChannelAggregate(
        id: ChannelId('ch1'),
        localNode: localNode,
      );
      final channel2 = ChannelAggregate(
        id: ChannelId('ch2'),
        localNode: localNode,
      );

      await repository.save(channel1);
      await repository.save(channel2);
      expect(await repository.count, equals(2));

      await repository.clearAll();

      expect(await repository.count, equals(0));
      expect(await repository.listIds(), isEmpty);
      expect(await repository.findById(channel1.id), isNull);
    });
  });
}
