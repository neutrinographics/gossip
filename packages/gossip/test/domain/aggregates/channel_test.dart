import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gossip/src/domain/aggregates/channel_aggregate.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/log_entry_id.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'package:gossip/src/domain/value_objects/version_vector.dart';
import 'package:gossip/src/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/domain/interfaces/state_materializer.dart';
import 'package:gossip/src/domain/interfaces/entry_repository.dart';
import 'package:gossip/src/domain/events/domain_event.dart';

// Test materializer that counts entries
class TestCountMaterializer implements StateMaterializer<int> {
  @override
  int initial() => 0;

  @override
  int fold(int state, LogEntry entry) => state + 1;
}

// Test materializer that sums first byte of payloads
class TestSumMaterializer implements StateMaterializer<int> {
  @override
  int initial() => 0;

  @override
  int fold(int state, LogEntry entry) {
    final value = entry.payload.isNotEmpty ? entry.payload[0] : 0;
    return state + value;
  }
}

// Fake EntryRepository for testing
class FakeEntryRepository implements EntryRepository {
  final Map<String, List<LogEntry>> _entries = {};

  String _key(ChannelId channel, StreamId stream) =>
      '${channel.value}:${stream.value}';

  @override
  Future<void> append(
    ChannelId channel,
    StreamId stream,
    LogEntry entry,
  ) async {
    final key = _key(channel, stream);
    _entries.putIfAbsent(key, () => []).add(entry);
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
    return _entries[_key(channel, stream)]?.toList() ?? [];
  }

  @override
  Future<List<LogEntry>> entriesSince(
    ChannelId channel,
    StreamId stream,
    VersionVector since,
  ) async => [];

  @override
  Future<List<LogEntry>> entriesForAuthorAfter(
    ChannelId channel,
    StreamId stream,
    NodeId author,
    int afterSequence,
  ) async => [];

  @override
  Future<int> latestSequence(
    ChannelId channel,
    StreamId stream,
    NodeId author,
  ) async => 0;

  @override
  Future<int> entryCount(ChannelId channel, StreamId stream) async =>
      (_entries[_key(channel, stream)]?.length ?? 0);

  @override
  Future<int> sizeBytes(ChannelId channel, StreamId stream) async => 0;

  @override
  Future<void> removeEntries(
    ChannelId channel,
    StreamId stream,
    List<LogEntryId> ids,
  ) async {}

  @override
  Future<void> clearStream(ChannelId channel, StreamId stream) async {
    _entries.remove(_key(channel, stream));
  }

  @override
  Future<void> clearChannel(ChannelId channel) async {
    _entries.removeWhere((key, _) => key.startsWith('${channel.value}:'));
  }

  @override
  Future<VersionVector> getVersionVector(
    ChannelId channel,
    StreamId stream,
  ) async => VersionVector.empty;
}

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

    test('registerMaterializer stores materializer for stream', () {
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

      // Register materializer
      channel.registerMaterializer(streamId, TestCountMaterializer());

      // No direct way to check registration, but getState will fail if not registered
      // This is tested in getState tests below
    });

    test('getState returns null when no materializer registered', () async {
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

      final entryRepo = FakeEntryRepository();

      final state = await channel.getState<int>(streamId, entryRepo);

      expect(state, isNull);
    });

    test('getState returns null when stream does not exist', () async {
      final channel = ChannelAggregate(
        id: ChannelId('channel-1'),
        localNode: NodeId('local'),
      );
      final streamId = StreamId('nonexistent');

      channel.registerMaterializer(streamId, TestCountMaterializer());
      final entryRepo = FakeEntryRepository();

      final state = await channel.getState<int>(streamId, entryRepo);

      expect(state, isNull);
    });

    test('getState returns initial state when no entries exist', () async {
      final channelId = ChannelId('channel-1');
      final channel = ChannelAggregate(
        id: channelId,
        localNode: NodeId('local'),
      );
      final streamId = StreamId('stream-1');
      channel.createStream(
        streamId,
        KeepAllRetention(),
        occurredAt: DateTime(2024, 1, 1),
      );

      channel.registerMaterializer(streamId, TestCountMaterializer());
      final entryRepo = FakeEntryRepository();

      final state = await channel.getState<int>(streamId, entryRepo);

      expect(state, equals(0)); // Initial state from materializer
    });

    test('getState folds entries with count materializer', () async {
      final channelId = ChannelId('channel-1');
      final channel = ChannelAggregate(
        id: channelId,
        localNode: NodeId('local'),
      );
      final streamId = StreamId('stream-1');
      final localNode = NodeId('local');
      channel.createStream(
        streamId,
        KeepAllRetention(),
        occurredAt: DateTime(2024, 1, 1),
      );

      // Add entries to repository
      final entryRepo = FakeEntryRepository();
      await entryRepo.append(
        channelId,
        streamId,
        LogEntry(
          author: localNode,
          sequence: 1,
          timestamp: Hlc.zero,
          payload: Uint8List.fromList([1]),
        ),
      );
      await entryRepo.append(
        channelId,
        streamId,
        LogEntry(
          author: localNode,
          sequence: 2,
          timestamp: Hlc.zero,
          payload: Uint8List.fromList([2]),
        ),
      );
      await entryRepo.append(
        channelId,
        streamId,
        LogEntry(
          author: localNode,
          sequence: 3,
          timestamp: Hlc.zero,
          payload: Uint8List.fromList([3]),
        ),
      );

      // Register materializer and get state
      channel.registerMaterializer(streamId, TestCountMaterializer());
      final state = await channel.getState<int>(streamId, entryRepo);

      expect(state, equals(3)); // Should count 3 entries
    });

    test('getState folds entries with sum materializer', () async {
      final channelId = ChannelId('channel-1');
      final channel = ChannelAggregate(
        id: channelId,
        localNode: NodeId('local'),
      );
      final streamId = StreamId('stream-1');
      final localNode = NodeId('local');
      channel.createStream(
        streamId,
        KeepAllRetention(),
        occurredAt: DateTime(2024, 1, 1),
      );

      // Add entries to repository
      final entryRepo = FakeEntryRepository();
      await entryRepo.append(
        channelId,
        streamId,
        LogEntry(
          author: localNode,
          sequence: 1,
          timestamp: Hlc.zero,
          payload: Uint8List.fromList([10]),
        ),
      );
      await entryRepo.append(
        channelId,
        streamId,
        LogEntry(
          author: localNode,
          sequence: 2,
          timestamp: Hlc.zero,
          payload: Uint8List.fromList([20]),
        ),
      );
      await entryRepo.append(
        channelId,
        streamId,
        LogEntry(
          author: localNode,
          sequence: 3,
          timestamp: Hlc.zero,
          payload: Uint8List.fromList([5]),
        ),
      );

      // Register sum materializer
      channel.registerMaterializer(streamId, TestSumMaterializer());
      final state = await channel.getState<int>(streamId, entryRepo);

      expect(state, equals(35)); // 10 + 20 + 5
    });

    test('registerMaterializer replaces previous materializer', () async {
      final channelId = ChannelId('channel-1');
      final channel = ChannelAggregate(
        id: channelId,
        localNode: NodeId('local'),
      );
      final streamId = StreamId('stream-1');
      final localNode = NodeId('local');
      channel.createStream(
        streamId,
        KeepAllRetention(),
        occurredAt: DateTime(2024, 1, 1),
      );

      // Add entries
      final entryRepo = FakeEntryRepository();
      await entryRepo.append(
        channelId,
        streamId,
        LogEntry(
          author: localNode,
          sequence: 1,
          timestamp: Hlc.zero,
          payload: Uint8List.fromList([10]),
        ),
      );
      await entryRepo.append(
        channelId,
        streamId,
        LogEntry(
          author: localNode,
          sequence: 2,
          timestamp: Hlc.zero,
          payload: Uint8List.fromList([20]),
        ),
      );

      // Register count materializer first
      channel.registerMaterializer(streamId, TestCountMaterializer());
      var state = await channel.getState<int>(streamId, entryRepo);
      expect(state, equals(2)); // Count: 2 entries

      // Replace with sum materializer
      channel.registerMaterializer(streamId, TestSumMaterializer());
      state = await channel.getState<int>(streamId, entryRepo);
      expect(state, equals(30)); // Sum: 10 + 20
    });

    test(
      'getState throws TypeError when type parameter does not match materializer',
      () async {
        final channelId = ChannelId('channel-1');
        final channel = ChannelAggregate(
          id: channelId,
          localNode: NodeId('local'),
        );
        final streamId = StreamId('stream-1');
        channel.createStream(
          streamId,
          KeepAllRetention(),
          occurredAt: DateTime(2024, 1, 1),
        );

        // Register int materializer
        channel.registerMaterializer(streamId, TestCountMaterializer());
        final entryRepo = FakeEntryRepository();

        // Try to get state as String (wrong type)
        expect(
          () => channel.getState<String>(streamId, entryRepo),
          throwsA(isA<TypeError>()),
        );
      },
    );
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

    test('supports normal operations after reconstitution', () async {
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

      // Can register materializer and get state
      channel.registerMaterializer(stream1, TestCountMaterializer());
      final entryRepo = FakeEntryRepository();
      final state = await channel.getState<int>(stream1, entryRepo);
      expect(state, equals(0));

      // Events from post-reconstitution operations are emitted
      expect(channel.uncommittedEvents, hasLength(2));
      expect(channel.uncommittedEvents[0], isA<MemberAdded>());
      expect(channel.uncommittedEvents[1], isA<StreamCreated>());
    });
  });
}
