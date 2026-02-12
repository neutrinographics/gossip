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

import 'package:gossip/src/infrastructure/repositories/in_memory_local_node_repository.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_time_port.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';
import 'package:gossip/src/protocol/gossip_engine.dart';
import 'package:gossip/src/protocol/protocol_codec.dart';
import 'package:gossip/src/protocol/messages/digest_request.dart';
import 'package:gossip/src/protocol/messages/digest_response.dart';
import 'package:gossip/src/protocol/messages/delta_response.dart';
import 'package:gossip/src/protocol/values/channel_digest.dart';
import 'package:gossip/src/protocol/values/stream_digest.dart';

import 'gossip_engine_test_harness.dart';

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
      localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
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

    test('generateDigest creates digest for channel with no streams', () async {
      final localNode = NodeId('local');
      final registry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      final entryRepo = InMemoryEntryRepository();
      final engine = createEngine(localNode, registry, entryRepo);
      final channelId = ChannelId('channel-1');
      final channel = ChannelAggregate(id: channelId, localNode: localNode);

      final digest = await engine.generateDigest(channel);

      expect(digest.channelId, equals(channelId));
      expect(digest.streams, isEmpty);
    });

    test('generateDigest creates digest for channel with streams', () async {
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

      final digest = await engine.generateDigest(channel);

      expect(digest.channelId, equals(channelId));
      expect(digest.streams, hasLength(1));
      expect(digest.streams[0].streamId, equals(streamId));
    });

    test('generateDigest computes version vectors from entry store', () async {
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
      await entryRepo.append(
        channelId,
        streamId,
        LogEntry(
          author: author1,
          sequence: 1,
          timestamp: Hlc(1000, 0),
          payload: Uint8List.fromList([1]),
        ),
      );
      await entryRepo.append(
        channelId,
        streamId,
        LogEntry(
          author: author1,
          sequence: 2,
          timestamp: Hlc(2000, 0),
          payload: Uint8List.fromList([2]),
        ),
      );
      await entryRepo.append(
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

      final digest = await engine.generateDigest(channel);

      expect(digest.streams, hasLength(1));
      final streamDigest = digest.streams[0];
      expect(streamDigest.streamId, equals(streamId));
      expect(streamDigest.version[author1], equals(2));
      expect(streamDigest.version[author2], equals(1));
    });

    test('computeDelta returns entries peer is missing', () async {
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
      await entryRepo.append(channelId, streamId, entry1);
      await entryRepo.append(channelId, streamId, entry2);
      await entryRepo.append(channelId, streamId, entry3);

      final engine = createEngine(localNode, registry, entryRepo);

      // Peer has author1:1, author2:0 (missing author1:2 and author2:1)
      final peerVersion = VersionVector({author1: 1, author2: 0});
      final delta = await engine.computeDelta(channelId, streamId, peerVersion);

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
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
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
          localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
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

    test('handleDigestResponse emits error for unknown channel', () async {
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
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
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
      await engine.handleDigestResponse(response);

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
        // Provide explicit gossipInterval
        final engine = GossipEngine(
          localNode: localNode,
          peerRegistry: registry,
          entryRepository: entryRepo,
          timePort: timerPort,
          messagePort: messagePort,
          localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
          gossipInterval: Duration(milliseconds: 100),
          adaptiveTimingEnabled: true,
        );

        // Should use static interval even with adaptive timing enabled
        expect(
          engine.effectiveGossipInterval,
          equals(Duration(milliseconds: 100)),
        );
      });

      test('uses RTT-derived interval when no static interval provided', () {
        final localNode = NodeId('local');
        final peer = NodeId('peer');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        registry.addPeer(peer, occurredAt: DateTime.now());
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
          localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
          adaptiveTimingEnabled: true,
        );

        // No per-peer RTT yet, should use conservative default (1000ms)
        expect(
          engine.effectiveGossipInterval,
          equals(Duration(milliseconds: 1000)),
        );

        // Record a per-peer RTT sample of 200ms
        registry.recordPeerRtt(peer, Duration(milliseconds: 200));

        // After one sample, per-peer SRTT is 200ms
        // Gossip interval = minSRTT * 2 = 400ms
        final interval = engine.effectiveGossipInterval;
        expect(interval.inMilliseconds, greaterThanOrEqualTo(300));
        expect(interval.inMilliseconds, lessThanOrEqualTo(500));
      });

      test('clamps RTT-derived interval to minimum', () {
        final localNode = NodeId('local');
        final peer = NodeId('peer');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        registry.addPeer(peer, occurredAt: DateTime.now());
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
          localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
          adaptiveTimingEnabled: true,
        );

        // Record very low per-peer RTT samples to drive EWMA down
        for (var i = 0; i < 20; i++) {
          registry.recordPeerRtt(peer, Duration(milliseconds: 10));
        }

        // Should be clamped to minimum (100ms)
        expect(
          engine.effectiveGossipInterval,
          equals(Duration(milliseconds: 100)),
        );
      });

      test('clamps RTT-derived interval to maximum', () {
        final localNode = NodeId('local');
        final peer = NodeId('peer');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        registry.addPeer(peer, occurredAt: DateTime.now());
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
          localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
          adaptiveTimingEnabled: true,
        );

        // Record very high per-peer RTT samples
        for (var i = 0; i < 20; i++) {
          registry.recordPeerRtt(peer, Duration(seconds: 10));
        }

        // Should be clamped to maximum (5 seconds)
        expect(engine.effectiveGossipInterval, equals(Duration(seconds: 5)));
      });

      test('uses default static interval when adaptive timing is disabled', () {
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
          localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
          // adaptiveTimingEnabled defaults to false
        );

        // Should use default static interval (500ms)
        expect(
          engine.effectiveGossipInterval,
          equals(Duration(milliseconds: 500)),
        );
      });

      test(
        'computes interval from minimum per-peer SRTT when peers have RTT estimates',
        () {
          final localNode = NodeId('local');
          final fastPeer = NodeId('fast');
          final slowPeer = NodeId('slow');
          final registry = PeerRegistry(
            localNode: localNode,
            initialIncarnation: 0,
          );
          registry.addPeer(fastPeer, occurredAt: DateTime.now());
          registry.addPeer(slowPeer, occurredAt: DateTime.now());

          // Seed per-peer RTT: fast=100ms, slow=3000ms
          registry.recordPeerRtt(fastPeer, const Duration(milliseconds: 100));
          registry.recordPeerRtt(slowPeer, const Duration(milliseconds: 3000));

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
            localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
            adaptiveTimingEnabled: true,
          );

          // Interval should be based on the FAST peer (100ms * 2 = 200ms)
          // but clamped to minimum 100ms
          final interval = engine.effectiveGossipInterval;
          // Should be much less than what the slow peer would produce (6000ms)
          expect(interval.inMilliseconds, lessThan(1000));
        },
      );

      test(
        'falls back to conservative default when no peers have RTT estimates',
        () {
          final localNode = NodeId('local');
          final peer = NodeId('peer');
          final registry = PeerRegistry(
            localNode: localNode,
            initialIncarnation: 0,
          );
          registry.addPeer(peer, occurredAt: DateTime.now());
          // No RTT recorded for peer

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
            localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
            adaptiveTimingEnabled: true,
          );

          // Should use conservative default (1000ms)
          expect(
            engine.effectiveGossipInterval.inMilliseconds,
            greaterThanOrEqualTo(1000),
          );
        },
      );

      test('one slow peer does not drag gossip interval up', () {
        final localNode = NodeId('local');
        final fastPeer1 = NodeId('fast1');
        final fastPeer2 = NodeId('fast2');
        final slowPeer = NodeId('slow');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        registry.addPeer(fastPeer1, occurredAt: DateTime.now());
        registry.addPeer(fastPeer2, occurredAt: DateTime.now());
        registry.addPeer(slowPeer, occurredAt: DateTime.now());

        // Two fast peers + one very slow peer
        registry.recordPeerRtt(fastPeer1, const Duration(milliseconds: 150));
        registry.recordPeerRtt(fastPeer2, const Duration(milliseconds: 200));
        registry.recordPeerRtt(slowPeer, const Duration(milliseconds: 5000));

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
          localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
          adaptiveTimingEnabled: true,
        );

        // Interval should track the fastest peer (~150ms * 2 = 300ms)
        // NOT the slow peer (5000ms * 2 = 10000ms)
        final interval = engine.effectiveGossipInterval;
        expect(interval.inMilliseconds, lessThan(1000));
      });
    });

    group('backpressure', () {
      test('skips gossip round when transport is congested', () async {
        final localNode = NodeId('local');
        final peerId = NodeId('peer');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        registry.addPeer(peerId, occurredAt: DateTime.now());

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
          localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        );

        // Simulate per-peer congestion (above threshold of 3)
        messagePort.setSimulatedPendingCountForPeer(peerId, 10);

        // Set up a channel so the engine has something to sync
        final channelId = ChannelId('test-channel');
        final channel = ChannelAggregate(id: channelId, localNode: localNode);
        engine.startListening({channelId: channel});

        // Perform gossip round - should be skipped due to congestion
        await engine.performGossipRound();

        // Verify no messages were sent
        final metrics = registry.getMetrics(peerId);
        expect(metrics?.messagesSent ?? 0, equals(0));
      });

      test('performs gossip round when transport is not congested', () async {
        final localNode = NodeId('local');
        final peerId = NodeId('peer');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        registry.addPeer(peerId, occurredAt: DateTime.now());

        final entryRepo = InMemoryEntryRepository();
        final timerPort = InMemoryTimePort();
        final bus = InMemoryMessageBus();
        final messagePort = InMemoryMessagePort(localNode, bus);

        // Register peer port to receive messages
        final peerPort = InMemoryMessagePort(peerId, bus);

        final engine = GossipEngine(
          localNode: localNode,
          peerRegistry: registry,
          entryRepository: entryRepo,
          timePort: timerPort,
          messagePort: messagePort,
          localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        );

        // No congestion (below per-peer threshold of 3)
        messagePort.setSimulatedPendingCountForPeer(peerId, 2);

        // Set up a channel so the engine has something to sync
        final channelId = ChannelId('test-channel');
        final channel = ChannelAggregate(id: channelId, localNode: localNode);
        engine.startListening({channelId: channel});

        // Perform gossip round - should proceed
        await engine.performGossipRound();

        // Verify a message was sent
        final metrics = registry.getMetrics(peerId);
        expect(metrics?.messagesSent ?? 0, greaterThan(0));

        // Clean up
        await peerPort.close();
      });

      test('resumes gossip when congestion clears', () async {
        final localNode = NodeId('local');
        final peerId = NodeId('peer');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        registry.addPeer(peerId, occurredAt: DateTime.now());

        final entryRepo = InMemoryEntryRepository();
        final timerPort = InMemoryTimePort();
        final bus = InMemoryMessageBus();
        final messagePort = InMemoryMessagePort(localNode, bus);

        // Register peer port to receive messages
        final peerPort = InMemoryMessagePort(peerId, bus);

        final engine = GossipEngine(
          localNode: localNode,
          peerRegistry: registry,
          entryRepository: entryRepo,
          timePort: timerPort,
          messagePort: messagePort,
          localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        );

        // Set up a channel
        final channelId = ChannelId('test-channel');
        final channel = ChannelAggregate(id: channelId, localNode: localNode);
        engine.startListening({channelId: channel});

        // Start congested (per-peer)
        messagePort.setSimulatedPendingCountForPeer(peerId, 15);
        await engine.performGossipRound();

        // No messages sent while congested
        var metrics = registry.getMetrics(peerId);
        expect(metrics?.messagesSent ?? 0, equals(0));

        // Clear congestion
        messagePort.clearSimulatedPendingCounts();
        await engine.performGossipRound();

        // Message sent after congestion cleared
        metrics = registry.getMetrics(peerId);
        expect(metrics?.messagesSent ?? 0, greaterThan(0));

        // Clean up
        await peerPort.close();
      });

      test(
        'gossips with uncongested peer when other peer is congested',
        () async {
          final localNode = NodeId('local');
          final congestedPeerId = NodeId('congested-peer');
          final healthyPeerId = NodeId('healthy-peer');
          final registry = PeerRegistry(
            localNode: localNode,
            initialIncarnation: 0,
          );
          registry.addPeer(congestedPeerId, occurredAt: DateTime.now());
          registry.addPeer(healthyPeerId, occurredAt: DateTime.now());

          final entryRepo = InMemoryEntryRepository();
          final timerPort = InMemoryTimePort();
          final bus = InMemoryMessageBus();
          final messagePort = InMemoryMessagePort(localNode, bus);

          // Register peer ports to receive messages
          final congestedPort = InMemoryMessagePort(congestedPeerId, bus);
          final healthyPort = InMemoryMessagePort(healthyPeerId, bus);

          final engine = GossipEngine(
            localNode: localNode,
            peerRegistry: registry,
            entryRepository: entryRepo,
            timePort: timerPort,
            messagePort: messagePort,
            localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
          );

          // Set up a channel
          final channelId = ChannelId('test-channel');
          final channel = ChannelAggregate(id: channelId, localNode: localNode);
          engine.startListening({channelId: channel});

          // Congest one peer, leave the other clear
          messagePort.setSimulatedPendingCountForPeer(congestedPeerId, 10);
          messagePort.setSimulatedPendingCountForPeer(healthyPeerId, 0);

          // Run multiple gossip rounds to ensure the healthy peer gets selected
          for (var i = 0; i < 10; i++) {
            await engine.performGossipRound();
          }

          // Congested peer should have received no messages
          final congestedMetrics = registry.getMetrics(congestedPeerId);
          expect(congestedMetrics?.messagesSent ?? 0, equals(0));

          // Healthy peer should have received messages
          final healthyMetrics = registry.getMetrics(healthyPeerId);
          expect(healthyMetrics?.messagesSent ?? 0, greaterThan(0));

          // Clean up
          await congestedPort.close();
          await healthyPort.close();
        },
      );

      test('skips round only when all peers are congested', () async {
        final localNode = NodeId('local');
        final peer1 = NodeId('peer1');
        final peer2 = NodeId('peer2');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );
        registry.addPeer(peer1, occurredAt: DateTime.now());
        registry.addPeer(peer2, occurredAt: DateTime.now());

        final entryRepo = InMemoryEntryRepository();
        final timerPort = InMemoryTimePort();
        final bus = InMemoryMessageBus();
        final messagePort = InMemoryMessagePort(localNode, bus);

        final peerPort1 = InMemoryMessagePort(peer1, bus);
        final peerPort2 = InMemoryMessagePort(peer2, bus);

        final engine = GossipEngine(
          localNode: localNode,
          peerRegistry: registry,
          entryRepository: entryRepo,
          timePort: timerPort,
          messagePort: messagePort,
          localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        );

        // Set up a channel
        final channelId = ChannelId('test-channel');
        final channel = ChannelAggregate(id: channelId, localNode: localNode);
        engine.startListening({channelId: channel});

        // Congest ALL peers
        messagePort.setSimulatedPendingCountForPeer(peer1, 10);
        messagePort.setSimulatedPendingCountForPeer(peer2, 10);

        await engine.performGossipRound();

        // No messages sent to any peer
        final metrics1 = registry.getMetrics(peer1);
        final metrics2 = registry.getMetrics(peer2);
        expect(metrics1?.messagesSent ?? 0, equals(0));
        expect(metrics2?.messagesSent ?? 0, equals(0));

        // Clean up
        await peerPort1.close();
        await peerPort2.close();
      });
    });

    // -------------------------------------------------------------------------
    // Full protocol integration
    // -------------------------------------------------------------------------

    group('Full protocol integration', () {
      test('4-step sync delivers entries from peer to initiator', () async {
        // Set up two nodes sharing a channel
        final nodeA = NodeId('nodeA');
        final nodeB = NodeId('nodeB');
        final channelId = ChannelId('shared-channel');
        final streamId = StreamId('stream-1');
        final author = NodeId('author-1');

        final registryA = PeerRegistry(localNode: nodeA, initialIncarnation: 0);
        registryA.addPeer(nodeB, occurredAt: DateTime.now());

        final registryB = PeerRegistry(localNode: nodeB, initialIncarnation: 0);
        registryB.addPeer(nodeA, occurredAt: DateTime.now());

        final entryRepoA = InMemoryEntryRepository();
        final entryRepoB = InMemoryEntryRepository();

        // Node B has entries that Node A doesn't
        final entry1 = LogEntry(
          author: author,
          sequence: 1,
          timestamp: Hlc(1000, 0),
          payload: Uint8List.fromList([1]),
        );
        final entry2 = LogEntry(
          author: author,
          sequence: 2,
          timestamp: Hlc(2000, 0),
          payload: Uint8List.fromList([2]),
        );
        await entryRepoB.append(channelId, streamId, entry1);
        await entryRepoB.append(channelId, streamId, entry2);

        final timePortA = InMemoryTimePort();
        final timePortB = InMemoryTimePort();
        final bus = InMemoryMessageBus();
        final portA = InMemoryMessagePort(nodeA, bus);
        final portB = InMemoryMessagePort(nodeB, bus);

        final channelA = ChannelAggregate(id: channelId, localNode: nodeA);
        channelA.createStream(
          streamId,
          KeepAllRetention(),
          occurredAt: DateTime.now(),
        );

        final channelB = ChannelAggregate(id: channelId, localNode: nodeB);
        channelB.createStream(
          streamId,
          KeepAllRetention(),
          occurredAt: DateTime.now(),
        );

        final engineA = GossipEngine(
          localNode: nodeA,
          peerRegistry: registryA,
          entryRepository: entryRepoA,
          timePort: timePortA,
          messagePort: portA,
          localNodeRepository: InMemoryLocalNodeRepository(nodeId: nodeA),
        );

        final engineB = GossipEngine(
          localNode: nodeB,
          peerRegistry: registryB,
          entryRepository: entryRepoB,
          timePort: timePortB,
          messagePort: portB,
          localNodeRepository: InMemoryLocalNodeRepository(nodeId: nodeB),
        );

        // Both nodes start listening
        engineA.startListening({channelId: channelA});
        engineB.startListening({channelId: channelB});

        // Node A initiates gossip round → sends DigestRequest to B
        await engineA.performGossipRound();
        // Allow message processing (DigestRequest → DigestResponse → DeltaRequest → DeltaResponse)
        await Future.delayed(Duration.zero);
        await Future.delayed(Duration.zero);
        await Future.delayed(Duration.zero);
        await Future.delayed(Duration.zero);

        // Node A should now have the entries
        expect(await entryRepoA.entryCount(channelId, streamId), equals(2));
        final stored = await entryRepoA.getAll(channelId, streamId);
        expect(stored[0].sequence, equals(1));
        expect(stored[1].sequence, equals(2));

        engineA.stopListening();
        engineB.stopListening();
      });
    });

    // -------------------------------------------------------------------------
    // Edge cases
    // -------------------------------------------------------------------------

    group('Edge cases', () {
      test('performGossipRound with no peers returns immediately', () async {
        final h = GossipEngineTestHarness();
        h.createChannel('ch1', streamIds: ['s1']);

        // Should complete without error
        await h.engine.performGossipRound();
        expect(h.errors, isEmpty);
      });

      test('performGossipRound with no channels sends empty digests', () async {
        final h = GossipEngineTestHarness();
        final peer = h.addPeer('peer1');

        final (messages, sub) = h.captureMessages(peer);

        // No channels set — round should still complete
        await h.engine.performGossipRound();
        await h.flush();

        expect(messages, hasLength(1));
        expect(messages.first, isA<DigestRequest>());
        expect((messages.first as DigestRequest).digests, isEmpty);

        await sub.cancel();
      });

      test('onEntriesMerged callback fires after delta response', () async {
        final h = GossipEngineTestHarness();
        h.createChannel('ch1', streamIds: ['s1']);

        final entry = LogEntry(
          author: NodeId('remote'),
          sequence: 1,
          timestamp: Hlc(1000, 0),
          payload: Uint8List.fromList([1]),
        );

        final response = DeltaResponse(
          sender: NodeId('remote'),
          channelId: ChannelId('ch1'),
          streamId: StreamId('s1'),
          entries: [entry],
        );

        await h.engine.handleDeltaResponse(response);

        expect(h.mergedEntries, hasLength(1));
        expect(h.mergedEntries.first.channelId, equals(ChannelId('ch1')));
        expect(h.mergedEntries.first.streamId, equals(StreamId('s1')));
        expect(h.mergedEntries.first.entries, hasLength(1));
        expect(h.mergedEntries.first.entries.first.sequence, equals(1));
      });

      test(
        'handleDeltaResponse with empty entries clears pending but skips merge',
        () async {
          final h = GossipEngineTestHarness();
          h.createChannel('ch1', streamIds: ['s1']);

          final response = DeltaResponse(
            sender: NodeId('remote'),
            channelId: ChannelId('ch1'),
            streamId: StreamId('s1'),
            entries: [],
          );

          await h.engine.handleDeltaResponse(response);

          // No entries merged
          expect(
            await h.entryRepository.entryCount(
              ChannelId('ch1'),
              StreamId('s1'),
            ),
            equals(0),
          );
          // Callback not fired for empty entries
          expect(h.mergedEntries, isEmpty);
        },
      );
    });
  });
}
