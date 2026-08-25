import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:test/test.dart';

import '../support/coordinator_builder.dart';

void main() {
  group('Peer-to-Channel Index', () {
    test('channelsForPeer returns empty list for unknown peer', () async {
      final coordinator = await createTestCoordinator();

      final channels = await coordinator.channelsForPeer(NodeId('unknown'));

      expect(channels, isEmpty);
    });

    test(
      'channelsForPeer returns empty list for peer with no channel memberships',
      () async {
        final coordinator = await createTestCoordinator();

        await coordinator.addPeer(NodeId('peer1'));

        final channels = await coordinator.channelsForPeer(NodeId('peer1'));

        expect(channels, isEmpty);
      },
    );

    test('channelsForPeer returns channels where peer is a member', () async {
      final coordinator = await createTestCoordinator();

      final peerId = NodeId('peer1');
      final channelId = ChannelId('channel1');

      await coordinator.addPeer(peerId);
      final channel = await coordinator.createChannel(channelId);
      await channel.addMember(peerId);

      final channels = await coordinator.channelsForPeer(peerId);

      expect(channels, contains(channelId));
      expect(channels, hasLength(1));
    });

    test('channelsForPeer returns multiple channels for peer', () async {
      final coordinator = await createTestCoordinator();

      final peerId = NodeId('peer1');
      final channel1Id = ChannelId('channel1');
      final channel2Id = ChannelId('channel2');
      final channel3Id = ChannelId('channel3');

      await coordinator.addPeer(peerId);

      final channel1 = await coordinator.createChannel(channel1Id);
      final channel2 = await coordinator.createChannel(channel2Id);
      await coordinator.createChannel(channel3Id); // peer not added to this one

      await channel1.addMember(peerId);
      await channel2.addMember(peerId);

      final channels = await coordinator.channelsForPeer(peerId);

      expect(channels, containsAll([channel1Id, channel2Id]));
      expect(channels, isNot(contains(channel3Id)));
      expect(channels, hasLength(2));
    });

    test('channelsForPeer excludes channels after peer is removed', () async {
      final coordinator = await createTestCoordinator();

      final peerId = NodeId('peer1');
      final channelId = ChannelId('channel1');

      await coordinator.addPeer(peerId);
      final channel = await coordinator.createChannel(channelId);
      await channel.addMember(peerId);

      expect(await coordinator.channelsForPeer(peerId), contains(channelId));

      await channel.removeMember(peerId);

      expect(await coordinator.channelsForPeer(peerId), isEmpty);
    });

    test('channelsForPeer works for local node', () async {
      final coordinator = await createTestCoordinator();

      final channelId = ChannelId('channel1');
      await coordinator.createChannel(channelId);

      // Local node is automatically a member of channels it creates
      final channels = await coordinator.channelsForPeer(NodeId('local'));

      expect(channels, contains(channelId));
    });
  });
}
