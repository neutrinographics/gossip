import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';

import '../../support/test_network.dart';

void main() {
  group('Channel Operations', () {
    group('Basic channel and stream operations', () {
      test('can create channel, add stream, and append entries', () async {
        final network = await TestNetwork.create(['local']);
        final channelId = ChannelId('my-channel');
        final streamId = StreamId('my-stream');

        await network['local'].createChannel(channelId);
        await network['local'].createStream(channelId, streamId);
        await network['local'].write(channelId, streamId, [1, 2, 3]);
        await network['local'].write(channelId, streamId, [4, 5, 6]);

        expect(
          await network['local'].entryCount(channelId, streamId),
          equals(2),
        );

        await network.dispose();
      });

      test('channel membership can be modified', () async {
        final network = await TestNetwork.create(['local', 'remote']);
        final channelId = ChannelId('membership-channel');

        await network['local'].createChannel(channelId);
        final channel = network['local'].coordinator.getChannel(channelId)!;

        // Initially only local node is member
        var members = await channel.members;
        expect(members.length, equals(1));

        // Add remote as member
        await channel.addMember(network['remote'].id);
        members = await channel.members;
        expect(members.length, equals(2));
        expect(members.contains(network['remote'].id), isTrue);

        // Remove remote
        await channel.removeMember(network['remote'].id);
        members = await channel.members;
        expect(members.length, equals(1));
        expect(members.contains(network['remote'].id), isFalse);

        await network.dispose();
      });
    });

    group('Channel membership and sync', () {
      test('entries only sync to channel members', () async {
        final network = await TestNetwork.create(['node1', 'node2', 'node3']);
        await network.connectAll();

        final channelId = ChannelId('members-only-channel');
        final streamId = StreamId('private');

        // node1 creates channel with only node2 as member (not node3)
        await network['node1'].createChannel(channelId);
        await network['node1'].createStream(channelId, streamId);
        await network['node1'].addMember(channelId, network['node2'].id);

        // node2 creates same channel and stream
        await network['node2'].createChannel(channelId);
        await network['node2'].createStream(channelId, streamId);
        await network['node2'].addMember(channelId, network['node1'].id);

        // node3 does NOT have this channel

        await network['node1'].write(channelId, streamId, [1, 2, 3]);

        await network.startAll();
        await network.runRounds(10);

        // node2 should have the entry
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(1),
        );

        // node3 doesn't have the channel at all
        expect(network['node3'].coordinator.getChannel(channelId), isNull);

        await network.dispose();
      });

      test('adding member allows sync of existing entries', () async {
        final network = await TestNetwork.create(['node1', 'node2', 'node3']);
        await network.connectAll();

        final channelId = ChannelId('late-member-channel');
        final streamId = StreamId('data');

        // node1 and node2 start with channel
        await network['node1'].createChannel(channelId);
        await network['node1'].createStream(channelId, streamId);
        await network['node1'].addMember(channelId, network['node2'].id);

        await network['node2'].createChannel(channelId);
        await network['node2'].createStream(channelId, streamId);
        await network['node2'].addMember(channelId, network['node1'].id);

        // Write entries before node3 joins
        await network['node1'].write(channelId, streamId, [1]);
        await network['node2'].write(channelId, streamId, [2]);

        await network.startAll();
        await network.runRounds(5);

        // Verify node1 and node2 have synced
        expect(
          await network['node1'].entryCount(channelId, streamId),
          equals(2),
        );
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(2),
        );

        // Now add node3 to the channel
        await network['node3'].createChannel(channelId);
        await network['node3'].createStream(channelId, streamId);
        await network['node3'].addMember(channelId, network['node1'].id);
        await network['node3'].addMember(channelId, network['node2'].id);

        // Add node3 to existing members' channels
        final channel1 = network['node1'].coordinator.getChannel(channelId)!;
        final channel2 = network['node2'].coordinator.getChannel(channelId)!;
        await channel1.addMember(network['node3'].id);
        await channel2.addMember(network['node3'].id);

        await network.runRounds(10);

        // node3 should now have both entries
        expect(
          await network['node3'].entryCount(channelId, streamId),
          equals(2),
        );

        await network.dispose();
      });

      test(
        'concurrent channel creation on multiple nodes syncs correctly',
        () async {
          final network = await TestNetwork.create(['node1', 'node2', 'node3']);
          await network.connectAll();

          final channelId = ChannelId('concurrent-creation-channel');
          final streamId = StreamId('events');

          // All nodes create the channel "simultaneously"
          await network['node1'].createChannel(channelId);
          await network['node2'].createChannel(channelId);
          await network['node3'].createChannel(channelId);

          // Create streams
          await network['node1'].createStream(channelId, streamId);
          await network['node2'].createStream(channelId, streamId);
          await network['node3'].createStream(channelId, streamId);

          // Add members
          await network['node1'].addMember(channelId, network['node2'].id);
          await network['node1'].addMember(channelId, network['node3'].id);
          await network['node2'].addMember(channelId, network['node1'].id);
          await network['node2'].addMember(channelId, network['node3'].id);
          await network['node3'].addMember(channelId, network['node1'].id);
          await network['node3'].addMember(channelId, network['node2'].id);

          // Each writes an entry
          await network['node1'].write(channelId, streamId, [1]);
          await network['node2'].write(channelId, streamId, [2]);
          await network['node3'].write(channelId, streamId, [3]);

          await network.startAll();
          await network.runRounds(15);

          // All should converge
          expect(await network.hasConverged(channelId, streamId), isTrue);
          expect(
            await network['node1'].entryCount(channelId, streamId),
            equals(3),
          );

          await network.dispose();
        },
      );

      test(
        'removed member with local channel still syncs (membership is local)',
        () async {
          // Note: Membership removal is a LOCAL operation. The gossip protocol
          // does not filter by membership - any node with a channel can sync.
          // This test verifies that removing a member from one node's view
          // doesn't prevent sync if the removed node still has the channel.
          final network = await TestNetwork.create(['node1', 'node2', 'node3']);
          await network.connectAll();

          final channelId = ChannelId('remove-member-channel');
          final streamId = StreamId('data');

          await network.setupChannel(channelId, streamId);
          await network.startAll();

          // Initial entries sync to all
          await network['node1'].write(channelId, streamId, [1]);
          await network.runRounds(10);

          expect(await network.hasConverged(channelId, streamId), isTrue);

          // Remove node3 from membership on node1 and node2
          // (node3 still has the channel locally)
          final channel1 = network['node1'].coordinator.getChannel(channelId)!;
          final channel2 = network['node2'].coordinator.getChannel(channelId)!;
          await channel1.removeMember(network['node3'].id);
          await channel2.removeMember(network['node3'].id);

          // Write new entries after node3 is "removed"
          await network['node1'].write(channelId, streamId, [2]);
          await network['node2'].write(channelId, streamId, [3]);
          await network.runRounds(15);

          // All nodes still converge because node3 still has the channel
          // and can request sync from node1/node2
          expect(await network.hasConverged(channelId, streamId), isTrue);
          expect(
            await network['node3'].entryCount(channelId, streamId),
            equals(3),
          );

          await network.dispose();
        },
      );
    });
  });
}
