import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/version_vector.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/domain/aggregates/channel_aggregate.dart';
import 'package:gossip/src/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_time_port.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';
import 'package:gossip/src/protocol/gossip_engine.dart';
import 'package:gossip/src/protocol/messages/digest_request.dart';
import 'package:gossip/src/protocol/messages/digest_response.dart';
import 'package:gossip/src/protocol/messages/delta_request.dart';
import 'package:gossip/src/protocol/messages/delta_response.dart';
import 'package:gossip/src/protocol/values/channel_digest.dart';
import 'package:gossip/src/protocol/values/stream_digest.dart';

void main() {
  GossipEngine createEngine(
    NodeId localNode,
    PeerRegistry registry,
    InMemoryEntryRepository entryRepo,
  ) {
    final timer = InMemoryTimePort();
    final bus = InMemoryMessageBus();
    final messagePort = InMemoryMessagePort(localNode, bus);
    return GossipEngine(
      localNode: localNode,
      peerRegistry: registry,
      entryRepository: entryRepo,
      timePort: timer,
      messagePort: messagePort,
    );
  }

  group('GossipEngine Message Handling', () {
    test('handleDigestRequest returns our digest for the channel', () {
      final localNode = NodeId('local');
      final peerNode = NodeId('peer-1');
      final registry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      final entryRepo = InMemoryEntryRepository();
      final engine = createEngine(localNode, registry, entryRepo);

      final channelId = ChannelId('channel-1');
      final streamId = StreamId('stream-1');
      final channel = ChannelAggregate(id: channelId, localNode: localNode);
      channel.createStream(
        streamId,
        KeepAllRetention(),
        occurredAt: DateTime.now(),
      );

      // Peer sends empty digest
      final peerDigest = ChannelDigest(channelId: channelId, streams: []);
      final request = DigestRequest(sender: peerNode, digests: [peerDigest]);

      final response = engine.handleDigestRequest(request, [channel]);

      expect(response.sender, equals(localNode));
      expect(response.digests, hasLength(1));
      expect(response.digests[0].channelId, equals(channelId));
      expect(response.digests[0].streams, hasLength(1));
    });

    test(
      'handleDigestResponse generates delta requests for missing entries',
      () {
        final localNode = NodeId('local');
        final peerNode = NodeId('peer-1');
        final author1 = NodeId('author-1');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        final entryRepo = InMemoryEntryRepository();
        final channelId = ChannelId('channel-1');
        final streamId = StreamId('stream-1');

        // We have one entry
        entryRepo.append(
          channelId,
          streamId,
          LogEntry(
            author: author1,
            sequence: 1,
            timestamp: Hlc(1000, 0),
            payload: Uint8List.fromList([1]),
          ),
        );

        final engine = createEngine(localNode, registry, entryRepo);

        // Set up channel
        final channel = ChannelAggregate(id: channelId, localNode: localNode);
        channel.createStream(
          streamId,
          KeepAllRetention(),
          occurredAt: DateTime.now(),
        );
        engine.setChannels({channelId: channel});

        // Peer has author1:2 (they have more than us - we have author1:1)
        final peerVersion = VersionVector({author1: 2});
        final peerDigest = StreamDigest(
          streamId: streamId,
          version: peerVersion,
        );
        final response = DigestResponse(
          sender: peerNode,
          digests: [
            ChannelDigest(channelId: channelId, streams: [peerDigest]),
          ],
        );

        final deltaRequests = engine.handleDigestResponse(response);

        expect(deltaRequests, hasLength(1));
        expect(deltaRequests[0].sender, equals(localNode));
        expect(deltaRequests[0].channelId, equals(channelId));
        expect(deltaRequests[0].streamId, equals(streamId));
        // Should request since OUR version (author1:1), not peer's
        expect(deltaRequests[0].since[author1], equals(1));
      },
    );

    test('handleDeltaRequest responds with missing entries', () {
      final localNode = NodeId('local');
      final peerNode = NodeId('peer-1');
      final author1 = NodeId('author-1');
      final registry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      final entryRepo = InMemoryEntryRepository();
      final channelId = ChannelId('channel-1');
      final streamId = StreamId('stream-1');

      // Add entries to our store
      final entry1 = LogEntry(
        author: author1,
        sequence: 1,
        timestamp: Hlc(1000, 0),
        payload: Uint8List.fromList([1]),
      );
      final entry2 = LogEntry(
        author: author1,
        sequence: 2,
        timestamp: Hlc(2000, 0),
        payload: Uint8List.fromList([2]),
      );
      entryRepo.append(channelId, streamId, entry1);
      entryRepo.append(channelId, streamId, entry2);

      final engine = createEngine(localNode, registry, entryRepo);

      // Peer requests entries since author1:0
      final peerVersion = VersionVector({author1: 0});
      final request = DeltaRequest(
        sender: peerNode,
        channelId: channelId,
        streamId: streamId,
        since: peerVersion,
      );

      final response = engine.handleDeltaRequest(request);

      expect(response.sender, equals(localNode));
      expect(response.channelId, equals(channelId));
      expect(response.streamId, equals(streamId));
      expect(response.entries, hasLength(2));
      expect(response.entries[0].sequence, equals(1));
      expect(response.entries[1].sequence, equals(2));
    });

    test('handleDeltaResponse merges received entries into store', () {
      final localNode = NodeId('local');
      final peerNode = NodeId('peer-1');
      final author1 = NodeId('author-1');
      final registry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      final entryRepo = InMemoryEntryRepository();
      final channelId = ChannelId('channel-1');
      final streamId = StreamId('stream-1');

      final engine = createEngine(localNode, registry, entryRepo);

      // Initially empty
      expect(entryRepo.entryCount(channelId, streamId), equals(0));

      // Receive entries from peer
      final entry1 = LogEntry(
        author: author1,
        sequence: 1,
        timestamp: Hlc(1000, 0),
        payload: Uint8List.fromList([1]),
      );
      final entry2 = LogEntry(
        author: author1,
        sequence: 2,
        timestamp: Hlc(2000, 0),
        payload: Uint8List.fromList([2]),
      );
      final response = DeltaResponse(
        sender: peerNode,
        channelId: channelId,
        streamId: streamId,
        entries: [entry1, entry2],
      );

      engine.handleDeltaResponse(response);

      // Entries should now be in our store
      expect(entryRepo.entryCount(channelId, streamId), equals(2));
      final stored = entryRepo.getAll(channelId, streamId);
      expect(stored[0].sequence, equals(1));
      expect(stored[1].sequence, equals(2));
    });

    test(
      'handleDigestResponse skips delta request when versions are equal',
      () {
        final localNode = NodeId('local');
        final peerNode = NodeId('peer-1');
        final author1 = NodeId('author-1');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        final entryRepo = InMemoryEntryRepository();
        final channelId = ChannelId('channel-1');
        final streamId = StreamId('stream-1');

        // We have entry with sequence 5
        entryRepo.append(
          channelId,
          streamId,
          LogEntry(
            author: author1,
            sequence: 5,
            timestamp: Hlc(5000, 0),
            payload: Uint8List.fromList([5]),
          ),
        );

        final engine = createEngine(localNode, registry, entryRepo);

        // Set up channel
        final channel = ChannelAggregate(id: channelId, localNode: localNode);
        channel.createStream(
          streamId,
          KeepAllRetention(),
          occurredAt: DateTime.now(),
        );
        engine.setChannels({channelId: channel});

        // Peer has the same version (author1:5)
        final peerVersion = VersionVector({author1: 5});
        final peerDigest = StreamDigest(
          streamId: streamId,
          version: peerVersion,
        );
        final response = DigestResponse(
          sender: peerNode,
          digests: [
            ChannelDigest(channelId: channelId, streams: [peerDigest]),
          ],
        );

        final deltaRequests = engine.handleDigestResponse(response);

        // Should NOT generate a delta request since we're already in sync
        expect(deltaRequests, isEmpty);
      },
    );

    test(
      'handleDigestResponse skips delta request when we are ahead of peer',
      () {
        final localNode = NodeId('local');
        final peerNode = NodeId('peer-1');
        final author1 = NodeId('author-1');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        final entryRepo = InMemoryEntryRepository();
        final channelId = ChannelId('channel-1');
        final streamId = StreamId('stream-1');

        // We have entries up to sequence 10
        for (var i = 1; i <= 10; i++) {
          entryRepo.append(
            channelId,
            streamId,
            LogEntry(
              author: author1,
              sequence: i,
              timestamp: Hlc(i * 1000, 0),
              payload: Uint8List.fromList([i]),
            ),
          );
        }

        final engine = createEngine(localNode, registry, entryRepo);

        // Set up channel
        final channel = ChannelAggregate(id: channelId, localNode: localNode);
        channel.createStream(
          streamId,
          KeepAllRetention(),
          occurredAt: DateTime.now(),
        );
        engine.setChannels({channelId: channel});

        // Peer only has up to sequence 5 (we're ahead)
        final peerVersion = VersionVector({author1: 5});
        final peerDigest = StreamDigest(
          streamId: streamId,
          version: peerVersion,
        );
        final response = DigestResponse(
          sender: peerNode,
          digests: [
            ChannelDigest(channelId: channelId, streams: [peerDigest]),
          ],
        );

        final deltaRequests = engine.handleDigestResponse(response);

        // Should NOT generate a delta request since we have everything peer has
        expect(deltaRequests, isEmpty);
      },
    );

    test(
      'handleDigestResponse generates delta request only for streams where peer is ahead',
      () {
        final localNode = NodeId('local');
        final peerNode = NodeId('peer-1');
        final author1 = NodeId('author-1');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        final entryRepo = InMemoryEntryRepository();
        final channelId = ChannelId('channel-1');
        final streamId1 = StreamId('stream-1');
        final streamId2 = StreamId('stream-2');

        // Stream 1: we have sequence 5, peer has 5 (in sync)
        entryRepo.append(
          channelId,
          streamId1,
          LogEntry(
            author: author1,
            sequence: 5,
            timestamp: Hlc(5000, 0),
            payload: Uint8List.fromList([5]),
          ),
        );

        // Stream 2: we have sequence 3, peer has 7 (peer ahead)
        entryRepo.append(
          channelId,
          streamId2,
          LogEntry(
            author: author1,
            sequence: 3,
            timestamp: Hlc(3000, 0),
            payload: Uint8List.fromList([3]),
          ),
        );

        final engine = createEngine(localNode, registry, entryRepo);

        // Set up channel with both streams
        final channel = ChannelAggregate(id: channelId, localNode: localNode);
        channel.createStream(
          streamId1,
          KeepAllRetention(),
          occurredAt: DateTime.now(),
        );
        channel.createStream(
          streamId2,
          KeepAllRetention(),
          occurredAt: DateTime.now(),
        );
        engine.setChannels({channelId: channel});

        // Peer digest: stream1 at 5 (in sync), stream2 at 7 (ahead)
        final peerDigest1 = StreamDigest(
          streamId: streamId1,
          version: VersionVector({author1: 5}),
        );
        final peerDigest2 = StreamDigest(
          streamId: streamId2,
          version: VersionVector({author1: 7}),
        );
        final response = DigestResponse(
          sender: peerNode,
          digests: [
            ChannelDigest(
              channelId: channelId,
              streams: [peerDigest1, peerDigest2],
            ),
          ],
        );

        final deltaRequests = engine.handleDigestResponse(response);

        // Should only generate delta request for stream2 where peer is ahead
        expect(deltaRequests, hasLength(1));
        expect(deltaRequests[0].streamId, equals(streamId2));
        expect(deltaRequests[0].since[author1], equals(3));
      },
    );

    test(
      'handleDigestResponse skips delta request when one is already pending for the same stream',
      () {
        final localNode = NodeId('local');
        final peerNode = NodeId('peer-1');
        final author1 = NodeId('author-1');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        final entryRepo = InMemoryEntryRepository();
        final channelId = ChannelId('channel-1');
        final streamId = StreamId('stream-1');

        // We have sequence 1, peer has 5 (peer ahead)
        entryRepo.append(
          channelId,
          streamId,
          LogEntry(
            author: author1,
            sequence: 1,
            timestamp: Hlc(1000, 0),
            payload: Uint8List.fromList([1]),
          ),
        );

        final engine = createEngine(localNode, registry, entryRepo);

        final channel = ChannelAggregate(id: channelId, localNode: localNode);
        channel.createStream(
          streamId,
          KeepAllRetention(),
          occurredAt: DateTime.now(),
        );
        engine.setChannels({channelId: channel});

        final peerDigest = StreamDigest(
          streamId: streamId,
          version: VersionVector({author1: 5}),
        );
        final response = DigestResponse(
          sender: peerNode,
          digests: [
            ChannelDigest(channelId: channelId, streams: [peerDigest]),
          ],
        );

        // First DigestResponse should generate a DeltaRequest
        final firstRequests = engine.handleDigestResponse(response);
        expect(firstRequests, hasLength(1));

        // Second DigestResponse (before DeltaResponse arrives) should NOT
        // generate another DeltaRequest for the same stream
        final secondRequests = engine.handleDigestResponse(response);
        expect(secondRequests, isEmpty);
      },
    );

    test(
      'handleDeltaResponse clears pending state allowing new delta requests',
      () {
        final localNode = NodeId('local');
        final peerNode = NodeId('peer-1');
        final author1 = NodeId('author-1');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        final entryRepo = InMemoryEntryRepository();
        final channelId = ChannelId('channel-1');
        final streamId = StreamId('stream-1');

        // We have sequence 1
        entryRepo.append(
          channelId,
          streamId,
          LogEntry(
            author: author1,
            sequence: 1,
            timestamp: Hlc(1000, 0),
            payload: Uint8List.fromList([1]),
          ),
        );

        final engine = createEngine(localNode, registry, entryRepo);

        final channel = ChannelAggregate(id: channelId, localNode: localNode);
        channel.createStream(
          streamId,
          KeepAllRetention(),
          occurredAt: DateTime.now(),
        );
        engine.setChannels({channelId: channel});

        // Peer has sequence 5
        final peerDigest = StreamDigest(
          streamId: streamId,
          version: VersionVector({author1: 5}),
        );
        final digestResponse = DigestResponse(
          sender: peerNode,
          digests: [
            ChannelDigest(channelId: channelId, streams: [peerDigest]),
          ],
        );

        // First request goes through
        final firstRequests = engine.handleDigestResponse(digestResponse);
        expect(firstRequests, hasLength(1));

        // Second request blocked (pending)
        final secondRequests = engine.handleDigestResponse(digestResponse);
        expect(secondRequests, isEmpty);

        // Receive DeltaResponse with entries 2-5
        final deltaResponse = DeltaResponse(
          sender: peerNode,
          channelId: channelId,
          streamId: streamId,
          entries: [
            LogEntry(
              author: author1,
              sequence: 2,
              timestamp: Hlc(2000, 0),
              payload: Uint8List.fromList([2]),
            ),
            LogEntry(
              author: author1,
              sequence: 3,
              timestamp: Hlc(3000, 0),
              payload: Uint8List.fromList([3]),
            ),
          ],
        );
        engine.handleDeltaResponse(deltaResponse);

        // Now we have sequence 3, peer still claims 5 - should allow new request
        final thirdRequests = engine.handleDigestResponse(digestResponse);
        expect(thirdRequests, hasLength(1));
        // Request should be since our current version (author1:3)
        expect(thirdRequests[0].since[author1], equals(3));
      },
    );

    test(
      'pending delta requests expire after timeout allowing new requests',
      () {
        final localNode = NodeId('local');
        final peerNode = NodeId('peer-1');
        final author1 = NodeId('author-1');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        final entryRepo = InMemoryEntryRepository();
        final channelId = ChannelId('channel-1');
        final streamId = StreamId('stream-1');

        entryRepo.append(
          channelId,
          streamId,
          LogEntry(
            author: author1,
            sequence: 1,
            timestamp: Hlc(1000, 0),
            payload: Uint8List.fromList([1]),
          ),
        );

        final timePort = InMemoryTimePort();
        final bus = InMemoryMessageBus();
        final messagePort = InMemoryMessagePort(localNode, bus);
        final engine = GossipEngine(
          localNode: localNode,
          peerRegistry: registry,
          entryRepository: entryRepo,
          timePort: timePort,
          messagePort: messagePort,
        );

        final channel = ChannelAggregate(id: channelId, localNode: localNode);
        channel.createStream(
          streamId,
          KeepAllRetention(),
          occurredAt: DateTime.now(),
        );
        engine.setChannels({channelId: channel});

        final peerDigest = StreamDigest(
          streamId: streamId,
          version: VersionVector({author1: 5}),
        );
        final response = DigestResponse(
          sender: peerNode,
          digests: [
            ChannelDigest(channelId: channelId, streams: [peerDigest]),
          ],
        );

        // First request goes through
        final firstRequests = engine.handleDigestResponse(response);
        expect(firstRequests, hasLength(1));

        // Second request blocked (pending)
        final secondRequests = engine.handleDigestResponse(response);
        expect(secondRequests, isEmpty);

        // Advance time past the timeout (default 5 seconds)
        timePort.advance(const Duration(seconds: 6));

        // Now the pending request should have expired, allowing a new one
        final thirdRequests = engine.handleDigestResponse(response);
        expect(thirdRequests, hasLength(1));
      },
    );

    test(
      'clearPendingRequestsForPeer removes pending requests when peer disconnects',
      () {
        final localNode = NodeId('local');
        final peerNode = NodeId('peer-1');
        final author1 = NodeId('author-1');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        final entryRepo = InMemoryEntryRepository();
        final channelId = ChannelId('channel-1');
        final streamId = StreamId('stream-1');

        entryRepo.append(
          channelId,
          streamId,
          LogEntry(
            author: author1,
            sequence: 1,
            timestamp: Hlc(1000, 0),
            payload: Uint8List.fromList([1]),
          ),
        );

        final timePort = InMemoryTimePort();
        final bus = InMemoryMessageBus();
        final messagePort = InMemoryMessagePort(localNode, bus);
        final engine = GossipEngine(
          localNode: localNode,
          peerRegistry: registry,
          entryRepository: entryRepo,
          timePort: timePort,
          messagePort: messagePort,
        );

        final channel = ChannelAggregate(id: channelId, localNode: localNode);
        channel.createStream(
          streamId,
          KeepAllRetention(),
          occurredAt: DateTime.now(),
        );
        engine.setChannels({channelId: channel});

        final peerDigest = StreamDigest(
          streamId: streamId,
          version: VersionVector({author1: 5}),
        );
        final response = DigestResponse(
          sender: peerNode,
          digests: [
            ChannelDigest(channelId: channelId, streams: [peerDigest]),
          ],
        );

        // First request goes through
        final firstRequests = engine.handleDigestResponse(response);
        expect(firstRequests, hasLength(1));

        // Second request blocked (pending)
        final secondRequests = engine.handleDigestResponse(response);
        expect(secondRequests, isEmpty);

        // Simulate peer disconnect - clear pending requests
        engine.clearPendingRequests();

        // Now should allow new request
        final thirdRequests = engine.handleDigestResponse(response);
        expect(thirdRequests, hasLength(1));
      },
    );
  });
}
