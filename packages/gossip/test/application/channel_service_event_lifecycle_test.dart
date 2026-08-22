import 'package:gossip/src/application/services/channel_service.dart';
import 'package:gossip/src/shared/domain/events/domain_event.dart';
import 'package:gossip/src/sync/domain/events/sync_events.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_channel_repository.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:test/test.dart';

void main() {
  group('ChannelService event lifecycle', () {
    late NodeId localNode;
    late List<DomainEvent> emitted;
    late InMemoryChannelRepository repository;
    late ChannelService service;
    final channelId = ChannelId('ch1');

    setUp(() {
      localNode = NodeId('local');
      emitted = <DomainEvent>[];
      repository = InMemoryChannelRepository();
      service = ChannelService(
        localNode: localNode,
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        channelRepository: repository,
        onEvent: emitted.add,
      );
    });

    test('events are emitted exactly once, never replayed', () async {
      await service.createChannel(channelId);
      expect(emitted.whereType<ChannelCreated>().length, equals(1));

      emitted.clear();
      await service.addMember(channelId, NodeId('peer1'));
      expect(
        emitted.whereType<ChannelCreated>(),
        isEmpty,
        reason: 'ChannelCreated must not be replayed on later mutations',
      );
      expect(emitted.whereType<MemberAdded>().length, equals(1));

      emitted.clear();
      await service.addMember(channelId, NodeId('peer2'));
      expect(
        emitted.whereType<MemberAdded>().length,
        equals(1),
        reason: 'only the NEW member event may be emitted',
      );
      expect(
        (emitted.whereType<MemberAdded>().single).memberId,
        equals(NodeId('peer2')),
      );
    });

    test('re-adding an existing member emits nothing', () async {
      await service.createChannel(channelId);
      await service.addMember(channelId, NodeId('peer1'));

      emitted.clear();
      await service.addMember(channelId, NodeId('peer1'));
      expect(emitted, isEmpty);
    });

    test('removeMember emits MemberRemoved exactly once', () async {
      await service.createChannel(channelId);
      await service.addMember(channelId, NodeId('peer1'));

      emitted.clear();
      await service.removeMember(channelId, NodeId('peer1'));
      final removed = emitted.whereType<MemberRemoved>().toList();
      expect(
        removed.length,
        equals(1),
        reason: 'the documented MemberRemoved event must actually be emitted',
      );
      expect(removed.single.memberId, equals(NodeId('peer1')));

      emitted.clear();
      await service.removeMember(channelId, NodeId('peer1'));
      expect(
        emitted.whereType<MemberRemoved>(),
        isEmpty,
        reason: 'removing an absent member is a no-op',
      );
    });

    test('aggregates do not accumulate uncommitted events', () async {
      await service.createChannel(channelId);
      await service.addMember(channelId, NodeId('peer1'));
      await service.addMember(channelId, NodeId('peer2'));

      final channel = await repository.findById(channelId);
      expect(
        channel!.uncommittedEvents,
        isEmpty,
        reason: 'emitted events must be drained, not retained forever',
      );
    });
  });
}
