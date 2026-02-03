import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'package:gossip/src/domain/value_objects/version_vector.dart';
import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/domain/aggregates/channel_aggregate.dart';
import 'package:gossip/src/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/domain/errors/sync_error.dart';
import 'package:gossip/src/domain/services/rtt_tracker.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_time_port.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';
import 'package:gossip/src/protocol/gossip_engine.dart';
import 'package:gossip/src/protocol/protocol_codec.dart';
import 'package:gossip/src/protocol/messages/digest_request.dart';
import 'package:gossip/src/protocol/messages/digest_response.dart';
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

  group('GossipEngine', () {
    test('creates gossip engine with local node', () {
      final localNode = NodeId('local');
      final registry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );

      final entryRepo = InMemoryEntryRepository();
      final engine = createEngine(localNode, registry, entryRepo);

      expect(engine.localNode, equals(localNode));
    });

    test('selectRandomPeer returns null when no reachable peers', () {
      final localNode = NodeId('local');
      final registry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      final entryRepo = InMemoryEntryRepository();
      final engine = createEngine(localNode, registry, entryRepo);

      final peer = engine.selectRandomPeer();

      expect(peer, isNull);
    });

    test('selectRandomPeer returns a reachable peer', () {
      final localNode = NodeId('local');
      final registry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      final peerId = NodeId('peer-1');
      registry.addPeer(peerId, occurredAt: DateTime.now());

      final entryRepo = InMemoryEntryRepository();
      final engine = createEngine(localNode, registry, entryRepo);

      final peer = engine.selectRandomPeer();

      expect(peer, isNotNull);
      expect(peer!.id, equals(peerId));
    });

    test('generateDigest creates digest for channel with no streams', () {
      final localNode = NodeId('local');
      final registry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      final entryRepo = InMemoryEntryRepository();
      final engine = createEngine(localNode, registry, entryRepo);
      final channelId = ChannelId('channel-1');
      final channel = ChannelAggregate(id: channelId, localNode: localNode);

      final digest = engine.generateDigest(channel);

      expect(digest.channelId, equals(channelId));
      expect(digest.streams, isEmpty);
    });

    test('generateDigest creates digest for channel with streams', () {
      final localNode = NodeId('local');
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

      final digest = engine.generateDigest(channel);

      expect(digest.channelId, equals(channelId));
      expect(digest.streams, hasLength(1));
      expect(digest.streams[0].streamId, equals(streamId));
    });

    test('generateDigest computes version vectors from entry store', () {
      final localNode = NodeId('local');
      final author1 = NodeId('author-1');
      final author2 = NodeId('author-2');
      final registry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      final entryRepo = InMemoryEntryRepository();
      final channelId = ChannelId('channel-1');
      final streamId = StreamId('stream-1');

      // Add entries to store
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
      entryRepo.append(
        channelId,
        streamId,
        LogEntry(
          author: author1,
          sequence: 2,
          timestamp: Hlc(2000, 0),
          payload: Uint8List.fromList([2]),
        ),
      );
      entryRepo.append(
        channelId,
        streamId,
        LogEntry(
          author: author2,
          sequence: 1,
          timestamp: Hlc(1500, 0),
          payload: Uint8List.fromList([3]),
        ),
      );

      final channel = ChannelAggregate(id: channelId, localNode: localNode);
      channel.createStream(
        streamId,
        KeepAllRetention(),
        occurredAt: DateTime.now(),
      );
      final engine = createEngine(localNode, registry, entryRepo);

      final digest = engine.generateDigest(channel);

      expect(digest.streams, hasLength(1));
      final streamDigest = digest.streams[0];
      expect(streamDigest.streamId, equals(streamId));
      expect(streamDigest.version[author1], equals(2));
      expect(streamDigest.version[author2], equals(1));
    });

    test('computeDelta returns entries peer is missing', () {
      final localNode = NodeId('local');
      final author1 = NodeId('author-1');
      final author2 = NodeId('author-2');
      final registry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      final entryRepo = InMemoryEntryRepository();
      final channelId = ChannelId('channel-1');
      final streamId = StreamId('stream-1');

      // Add entries to store
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
      final entry3 = LogEntry(
        author: author2,
        sequence: 1,
        timestamp: Hlc(1500, 0),
        payload: Uint8List.fromList([3]),
      );
      entryRepo.append(channelId, streamId, entry1);
      entryRepo.append(channelId, streamId, entry2);
      entryRepo.append(channelId, streamId, entry3);

      final engine = createEngine(localNode, registry, entryRepo);

      // Peer has author1:1, author2:0 (missing author1:2 and author2:1)
      final peerVersion = VersionVector({author1: 1, author2: 0});
      final delta = engine.computeDelta(channelId, streamId, peerVersion);

      expect(delta, hasLength(2));
      expect(delta.any((e) => e.author == author1 && e.sequence == 2), isTrue);
      expect(delta.any((e) => e.author == author2 && e.sequence == 1), isTrue);
    });

    test('gossip round sends DigestRequest to random peer', () async {
      final localNode = NodeId('local');
      final peerNode = NodeId('peer1');
      final registry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );

      // Add a reachable peer
      registry.addPeer(peerNode, occurredAt: DateTime.now());

      final entryRepo = InMemoryEntryRepository();
      final timer = InMemoryTimePort();
      final bus = InMemoryMessageBus();
      final localPort = InMemoryMessagePort(localNode, bus);
      final peerPort = InMemoryMessagePort(peerNode, bus);

      final engine = GossipEngine(
        localNode: localNode,
        peerRegistry: registry,
        entryRepository: entryRepo,
        timePort: timer,
        messagePort: localPort,
      );

      // Create a channel with a stream
      final channelId = ChannelId('channel-1');
      final streamId = StreamId('stream-1');
      final channel = ChannelAggregate(id: channelId, localNode: localNode);
      channel.createStream(
        streamId,
        KeepAllRetention(),
        occurredAt: DateTime.now(),
      );

      // Set up channels for gossip
      engine.setChannels({channelId: channel});

      // Set up listener for DigestRequest from local to peer
      final digestRequestFuture = peerPort.incoming.first;

      // Trigger a gossip round
      engine.performGossipRound();

      // Verify DigestRequest was sent to peer
      final message = await digestRequestFuture.timeout(Duration(seconds: 1));
      final codec = ProtocolCodec();
      final request = codec.decode(message.bytes);

      expect(request, isA<DigestRequest>());
      final digestRequest = request as DigestRequest;
      expect(digestRequest.sender, equals(localNode));
      expect(digestRequest.digests, hasLength(1));
      expect(digestRequest.digests[0].channelId, equals(channelId));
    });

    test(
      'listens to incoming DigestRequest and sends DigestResponse',
      () async {
        final localNode = NodeId('local');
        final peerNode = NodeId('peer1');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        final entryRepo = InMemoryEntryRepository();
        final timer = InMemoryTimePort();
        final bus = InMemoryMessageBus();
        final localPort = InMemoryMessagePort(localNode, bus);
        final peerPort = InMemoryMessagePort(peerNode, bus);

        final engine = GossipEngine(
          localNode: localNode,
          peerRegistry: registry,
          entryRepository: entryRepo,
          timePort: timer,
          messagePort: localPort,
        );

        // Create a channel
        final channelId = ChannelId('channel-1');
        final streamId = StreamId('stream-1');
        final channel = ChannelAggregate(id: channelId, localNode: localNode);
        channel.createStream(
          streamId,
          KeepAllRetention(),
          occurredAt: DateTime.now(),
        );

        // Start listening
        engine.startListening({channelId: channel});

        // Peer sends DigestRequest
        final codec = ProtocolCodec();
        final digestRequest = DigestRequest(
          sender: peerNode,
          digests: [
            ChannelDigest(
              channelId: channelId,
              streams: [
                StreamDigest(streamId: streamId, version: VersionVector.empty),
              ],
            ),
          ],
        );
        final requestBytes = codec.encode(digestRequest);

        // Set up response listener before sending
        final responseFuture = peerPort.incoming.first;

        await peerPort.send(localNode, requestBytes);

        // Wait for response
        final responseMessage = await responseFuture.timeout(
          Duration(seconds: 1),
        );
        final response = codec.decode(responseMessage.bytes);

        expect(response, isA<DigestResponse>());

        // Clean up
        engine.stopListening();
      },
    );

    test('handleDigestResponse emits error for unknown channel', () {
      final localNode = NodeId('local');
      final peerRegistry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      final entryRepo = InMemoryEntryRepository();
      final port = InMemoryMessagePort(localNode, InMemoryMessageBus());
      final timerPort = InMemoryTimePort();

      // Track emitted errors
      final errors = <SyncError>[];
      final engine = GossipEngine(
        localNode: localNode,
        peerRegistry: peerRegistry,
        entryRepository: entryRepo,
        messagePort: port,
        timePort: timerPort,
        onError: errors.add,
      );

      // Create a digest response for an unknown channel
      final unknownChannelId = ChannelId('unknown-channel');
      final response = DigestResponse(
        sender: NodeId('peer'),
        digests: [ChannelDigest(channelId: unknownChannelId, streams: [])],
      );

      // Handle the response
      engine.handleDigestResponse(response);

      // Verify error was emitted
      expect(errors.length, equals(1));
      expect(errors.first, isA<ChannelSyncError>());
      final error = errors.first as ChannelSyncError;
      expect(error.channel, equals(unknownChannelId));
      expect(error.type, equals(SyncErrorType.protocolError));
      expect(error.message, contains('Received digest for unknown channel'));
    });

    group('effectiveGossipInterval', () {
      test('uses static interval when explicitly provided', () {
        final localNode = NodeId('local');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        final entryRepo = InMemoryEntryRepository();
        final timerPort = InMemoryTimePort();
        final messagePort = InMemoryMessagePort(
          localNode,
          InMemoryMessageBus(),
        );
        final rttTracker = RttTracker();

        // Provide explicit gossipInterval
        final engine = GossipEngine(
          localNode: localNode,
          peerRegistry: registry,
          entryRepository: entryRepo,
          timePort: timerPort,
          messagePort: messagePort,
          gossipInterval: Duration(milliseconds: 100),
          rttTracker: rttTracker,
        );

        // Should use static interval even with RTT tracker
        expect(
          engine.effectiveGossipInterval,
          equals(Duration(milliseconds: 100)),
        );
      });

      test('uses RTT-derived interval when no static interval provided', () {
        final localNode = NodeId('local');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        final entryRepo = InMemoryEntryRepository();
        final timerPort = InMemoryTimePort();
        final messagePort = InMemoryMessagePort(
          localNode,
          InMemoryMessageBus(),
        );
        final rttTracker = RttTracker();

        final engine = GossipEngine(
          localNode: localNode,
          peerRegistry: registry,
          entryRepository: entryRepo,
          timePort: timerPort,
          messagePort: messagePort,
          rttTracker: rttTracker,
        );

        // Initial RTT is 1 second, so interval should be 2 seconds
        expect(engine.effectiveGossipInterval, equals(Duration(seconds: 2)));

        // Record a sample with 200ms RTT
        rttTracker.recordSample(Duration(milliseconds: 200));

        // After one sample, EWMA smoothed RTT is ~200ms
        // Gossip interval = RTT * 2 = ~400ms
        final interval = engine.effectiveGossipInterval;
        expect(interval.inMilliseconds, greaterThanOrEqualTo(300));
        expect(interval.inMilliseconds, lessThanOrEqualTo(500));
      });

      test('clamps RTT-derived interval to minimum', () {
        final localNode = NodeId('local');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        final entryRepo = InMemoryEntryRepository();
        final timerPort = InMemoryTimePort();
        final messagePort = InMemoryMessagePort(
          localNode,
          InMemoryMessageBus(),
        );
        final rttTracker = RttTracker();

        final engine = GossipEngine(
          localNode: localNode,
          peerRegistry: registry,
          entryRepository: entryRepo,
          timePort: timerPort,
          messagePort: messagePort,
          rttTracker: rttTracker,
        );

        // Record very low RTT samples to drive EWMA down
        for (var i = 0; i < 20; i++) {
          rttTracker.recordSample(Duration(milliseconds: 10));
        }

        // Should be clamped to minimum (100ms)
        expect(
          engine.effectiveGossipInterval,
          equals(Duration(milliseconds: 100)),
        );
      });

      test('clamps RTT-derived interval to maximum', () {
        final localNode = NodeId('local');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        final entryRepo = InMemoryEntryRepository();
        final timerPort = InMemoryTimePort();
        final messagePort = InMemoryMessagePort(
          localNode,
          InMemoryMessageBus(),
        );
        final rttTracker = RttTracker();

        final engine = GossipEngine(
          localNode: localNode,
          peerRegistry: registry,
          entryRepository: entryRepo,
          timePort: timerPort,
          messagePort: messagePort,
          rttTracker: rttTracker,
        );

        // Record very high RTT samples
        for (var i = 0; i < 20; i++) {
          rttTracker.recordSample(Duration(seconds: 10));
        }

        // Should be clamped to maximum (5 seconds)
        expect(engine.effectiveGossipInterval, equals(Duration(seconds: 5)));
      });

      test('uses default static interval when no RTT tracker provided', () {
        final localNode = NodeId('local');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        final entryRepo = InMemoryEntryRepository();
        final timerPort = InMemoryTimePort();
        final messagePort = InMemoryMessagePort(
          localNode,
          InMemoryMessageBus(),
        );

        final engine = GossipEngine(
          localNode: localNode,
          peerRegistry: registry,
          entryRepository: entryRepo,
          timePort: timerPort,
          messagePort: messagePort,
          // No rttTracker provided
        );

        // Should use default static interval (500ms)
        expect(
          engine.effectiveGossipInterval,
          equals(Duration(milliseconds: 500)),
        );
      });
    });
  });
}
