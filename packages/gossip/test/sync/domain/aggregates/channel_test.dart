import 'package:test/test.dart';
import 'package:gossip/src/sync/domain/aggregates/channel_aggregate.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/sync/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/sync/domain/events/sync_events.dart';

void main() {
  group('Channel', () {
    test('can be constructed with id and localNode', () {
      final channelId = ChannelId('channel-1');
      final localNode = NodeId('local');

      final channel = ChannelAggregate(id: channelId, localNode: localNode);

      expect(channel.id, equals(channelId));
      expect(channel.localNode, equals(localNode));
    });

    test('local node is automatically a member', () {
      final localNode = NodeId('local');
      final channel = ChannelAggregate(
        id: ChannelId('channel-1'),
        localNode: localNode,
      );

      expect(channel.hasMember(localNode), isTrue);
    });

    test('addMember adds a member', () {
      final channel = ChannelAggregate(
        id: ChannelId('channel-1'),
        localNode: NodeId('local'),
      );
      final peerId = NodeId('peer-1');

      channel.addMember(peerId, occurredAt: DateTime(2024, 1, 1));

      expect(channel.hasMember(peerId), isTrue);
    });

    test('memberIds returns all members', () {
      final localNode = NodeId('local');
      final channel = ChannelAggregate(
        id: ChannelId('channel-1'),
        localNode: localNode,
      );
      final peer1 = NodeId('peer-1');
      final peer2 = NodeId('peer-2');
      channel.addMember(peer1, occurredAt: DateTime(2024, 1, 1));
      channel.addMember(peer2, occurredAt: DateTime(2024, 1, 1));

      final members = channel.memberIds;

      expect(members.length, equals(3));
      expect(members.contains(localNode), isTrue);
      expect(members.contains(peer1), isTrue);
      expect(members.contains(peer2), isTrue);
    });

    test('removeMember removes a member', () {
      final channel = ChannelAggregate(
        id: ChannelId('channel-1'),
        localNode: NodeId('local'),
      );
      final peerId = NodeId('peer-1');
      channel.addMember(peerId, occurredAt: DateTime(2024, 1, 1));

      channel.removeMember(peerId, occurredAt: DateTime(2024, 1, 2));

      expect(channel.hasMember(peerId), isFalse);
    });

    test('removeMember throws when removing local node', () {
      final localNode = NodeId('local');
      final channel = ChannelAggregate(
        id: ChannelId('channel-1'),
        localNode: localNode,
      );

      expect(
        () => channel.removeMember(localNode, occurredAt: DateTime(2024, 1, 1)),
        throwsA(isA<Exception>()),
      );
    });

    test('createStream creates a stream', () {
      final channel = ChannelAggregate(
        id: ChannelId('channel-1'),
        localNode: NodeId('local'),
      );
      final streamId = StreamId('stream-1');

      final created = channel.createStream(
        streamId,
        KeepAllRetention(),
        occurredAt: DateTime(2024, 1, 1),
      );

      expect(created, isTrue);
      expect(channel.hasStream(streamId), isTrue);
    });

    test('createStream returns false for duplicate stream', () {
      final channel = ChannelAggregate(
        id: ChannelId('channel-1'),
        localNode: NodeId('local'),
      );
      final streamId = StreamId('stream-1');
      channel.createStream(
        streamId,
        KeepAllRetention(),
        occurredAt: DateTime(2024, 1, 1),
      );

      final created = channel.createStream(
        streamId,
        KeepAllRetention(),
        occurredAt: DateTime(2024, 1, 2),
      );

      expect(created, isFalse);
    });

    test('streamIds returns list of stream IDs', () {
      final channel = ChannelAggregate(
        id: ChannelId('channel-1'),
        localNode: NodeId('local'),
      );
      final stream1 = StreamId('stream-1');
      final stream2 = StreamId('stream-2');
      channel.createStream(
        stream1,
        KeepAllRetention(),
        occurredAt: DateTime(2024, 1, 1),
      );
      channel.createStream(
        stream2,
        KeepAllRetention(),
        occurredAt: DateTime(2024, 1, 1),
      );

      final streams = channel.streamIds;

      expect(streams.length, equals(2));
      expect(streams.contains(stream1), isTrue);
      expect(streams.contains(stream2), isTrue);
    });

    test('streamCount returns number of streams', () {
      final channel = ChannelAggregate(
        id: ChannelId('channel-1'),
        localNode: NodeId('local'),
      );
      channel.createStream(
        StreamId('stream-1'),
        KeepAllRetention(),
        occurredAt: DateTime(2024, 1, 1),
      );
      channel.createStream(
        StreamId('stream-2'),
        KeepAllRetention(),
        occurredAt: DateTime(2024, 1, 1),
      );

      expect(channel.streamCount, equals(2));
    });

    test('constructor emits ChannelCreated event', () {
      final channelId = ChannelId('channel-1');
      final localNode = NodeId('local');
      final timestamp = DateTime(2024, 1, 1);

      final channel = ChannelAggregate(
        id: channelId,
        localNode: localNode,
        occurredAt: timestamp,
      );

      expect(channel.uncommittedEvents.length, equals(1));
      final event = channel.uncommittedEvents.first as ChannelCreated;
      expect(event.channelId, equals(channelId));
      expect(event.occurredAt, equals(timestamp));
    });

    test('addMember emits MemberAdded event', () {
      final channel = ChannelAggregate(
        id: ChannelId('channel-1'),
        localNode: NodeId('local'),
      );
      final peerId = NodeId('peer-1');

      channel.addMember(peerId, occurredAt: DateTime(2024, 1, 1));

      // Should have ChannelCreated + MemberAdded
      expect(channel.uncommittedEvents.length, equals(2));
      expect(channel.uncommittedEvents.last, isA<MemberAdded>());
    });

    test('createStream emits StreamCreated event', () {
      final channelId = ChannelId('channel-1');
      final channel = ChannelAggregate(
        id: channelId,
        localNode: NodeId('local'),
      );
      final streamId = StreamId('stream-1');
      final timestamp = DateTime(2024, 1, 1);

      channel.createStream(streamId, KeepAllRetention(), occurredAt: timestamp);

      // Should have ChannelCreated + StreamCreated
      expect(channel.uncommittedEvents.length, equals(2));
      final event = channel.uncommittedEvents.last as StreamCreated;
      expect(event.channelId, equals(channelId));
      expect(event.streamId, equals(streamId));
      expect(event.occurredAt, equals(timestamp));
    });
  });

  group('reconstitute', () {
    test('restores members and streams', () {
      final channelId = ChannelId('channel-1');
      final localNode = NodeId('local');
      final peer1 = NodeId('peer-1');
      final peer2 = NodeId('peer-2');
      final stream1 = StreamId('stream-1');
      final stream2 = StreamId('stream-2');

      final channel = ChannelAggregate.reconstitute(
        id: channelId,
        localNode: localNode,
        memberIds: {localNode, peer1, peer2},
        streams: {stream1: KeepAllRetention(), stream2: KeepAllRetention()},
      );

      expect(channel.id, equals(channelId));
      expect(channel.localNode, equals(localNode));
      expect(channel.hasMember(localNode), isTrue);
      expect(channel.hasMember(peer1), isTrue);
      expect(channel.hasMember(peer2), isTrue);
      expect(channel.hasStream(stream1), isTrue);
      expect(channel.hasStream(stream2), isTrue);
      expect(channel.streamCount, equals(2));
    });

    test('emits no domain events', () {
      final channel = ChannelAggregate.reconstitute(
        id: ChannelId('channel-1'),
        localNode: NodeId('local'),
        memberIds: {NodeId('local'), NodeId('peer-1')},
        streams: {StreamId('stream-1'): KeepAllRetention()},
      );

      expect(channel.uncommittedEvents, isEmpty);
    });

    test('does not auto-add localNode to members', () {
      final localNode = NodeId('local');
      final peer = NodeId('peer-1');

      // Deliberately omit localNode from memberIds
      final channel = ChannelAggregate.reconstitute(
        id: ChannelId('channel-1'),
        localNode: localNode,
        memberIds: {peer},
        streams: {},
      );

      // localNode should NOT be present since we didn't include it
      expect(channel.hasMember(localNode), isFalse);
      expect(channel.hasMember(peer), isTrue);
      expect(channel.memberIds.length, equals(1));
    });

    test('supports normal operations after reconstitution', () {
      final channelId = ChannelId('channel-1');
      final localNode = NodeId('local');
      final stream1 = StreamId('stream-1');

      final channel = ChannelAggregate.reconstitute(
        id: channelId,
        localNode: localNode,
        memberIds: {localNode},
        streams: {stream1: KeepAllRetention()},
      );

      // Can add members
      final newPeer = NodeId('new-peer');
      channel.addMember(newPeer, occurredAt: DateTime(2024, 1, 1));
      expect(channel.hasMember(newPeer), isTrue);

      // Can create new streams
      final stream2 = StreamId('stream-2');
      channel.createStream(
        stream2,
        KeepAllRetention(),
        occurredAt: DateTime(2024, 1, 1),
      );
      expect(channel.hasStream(stream2), isTrue);

      // Events from post-reconstitution operations are emitted
      expect(channel.uncommittedEvents, hasLength(2));
      expect(channel.uncommittedEvents[0], isA<MemberAdded>());
      expect(channel.uncommittedEvents[1], isA<StreamCreated>());
    });
  });
}
