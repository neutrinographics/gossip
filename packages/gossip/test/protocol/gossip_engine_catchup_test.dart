import 'dart:typed_data';

import 'package:gossip/src/domain/aggregates/channel_aggregate.dart';
import 'package:gossip/src/membership/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_message_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:gossip/src/protocol/gossip_engine.dart';
import 'package:gossip/src/sync/infrastructure/membership_peer_directory.dart';
import 'package:gossip/src/sync/infrastructure/sync_message_codec.dart';
import 'package:gossip/src/protocol/messages/delta_request.dart';
import 'package:gossip/src/protocol/messages/delta_response.dart';
import 'package:test/test.dart';

import 'gossip_engine_test_harness.dart';

void main() {
  final channelId = ChannelId('ch1');
  final streamId = StreamId('s1');
  final authorA = NodeId('author-a');

  LogEntry entryOf(int seq, int tsMs, {int payloadBytes = 10}) => LogEntry(
    author: authorA,
    sequence: seq,
    timestamp: Hlc(tsMs, 0),
    payload: Uint8List.fromList(List.filled(payloadBytes, 0x42)),
  );

  group('DeltaResponse hasMore — sender (G4)', () {
    test('a budget-truncated response sets hasMore=true', () async {
      final h = GossipEngineTestHarness(maxDeltaResponseBytes: 30 * 1024);
      h.createChannel('ch1', streamIds: ['s1']);
      for (var i = 1; i <= 20; i++) {
        await h.appendEntry(channelId, streamId, entryOf(i, 1000 + i,
            payloadBytes: 4 * 1024));
      }

      final resp = await h.engine.handleDeltaRequest(
        DeltaRequest(
          sender: NodeId('peer1'),
          channelId: channelId,
          streamId: streamId,
          since: VersionVector.empty,
        ),
      );

      expect(resp.hasMore, isTrue);
      expect(resp.entries.length, lessThan(20));
    });

    test('a response that fits sets hasMore=false', () async {
      final h = GossipEngineTestHarness(maxDeltaResponseBytes: 30 * 1024);
      h.createChannel('ch1', streamIds: ['s1']);
      await h.appendEntry(channelId, streamId, entryOf(1, 1001));

      final resp = await h.engine.handleDeltaRequest(
        DeltaRequest(
          sender: NodeId('peer1'),
          channelId: channelId,
          streamId: streamId,
          since: VersionVector.empty,
        ),
      );

      expect(resp.hasMore, isFalse);
      expect(resp.entries.length, equals(1));
    });
  });

  group('DeltaResponse continuation — receiver (G4)', () {
    test(
      'a truncated response returns a continuation DeltaRequest with the '
      'advanced version vector',
      () async {
        final h = GossipEngineTestHarness();
        h.createChannel('ch1', streamIds: ['s1']);

        final continuation = await h.engine.handleDeltaResponse(
          DeltaResponse(
            sender: NodeId('peer1'),
            channelId: channelId,
            streamId: streamId,
            entries: [entryOf(1, 1001), entryOf(2, 1002)],
            hasMore: true,
          ),
        );

        expect(continuation, isNotNull);
        expect(continuation!.channelId, equals(channelId));
        expect(continuation.streamId, equals(streamId));
        expect(
          continuation.since[authorA],
          equals(2),
          reason: 'continuation must request entries after the applied prefix',
        );
      },
    );

    test('a non-truncated response returns no continuation', () async {
      final h = GossipEngineTestHarness();
      h.createChannel('ch1', streamIds: ['s1']);

      final continuation = await h.engine.handleDeltaResponse(
        DeltaResponse(
          sender: NodeId('peer1'),
          channelId: channelId,
          streamId: streamId,
          entries: [entryOf(1, 1001)],
          hasMore: false,
        ),
      );

      expect(continuation, isNull);
    });

    test(
      'a truncated response that applies nothing new returns no continuation '
      '(no infinite loop)',
      () async {
        final h = GossipEngineTestHarness();
        h.createChannel('ch1', streamIds: ['s1']);
        await h.appendEntry(channelId, streamId, entryOf(1, 1001));

        final continuation = await h.engine.handleDeltaResponse(
          DeltaResponse(
            sender: NodeId('peer1'),
            channelId: channelId,
            streamId: streamId,
            entries: [entryOf(1, 1001)], // duplicate — no progress
            hasMore: true,
          ),
        );

        expect(continuation, isNull);
      },
    );
  });

  group('DeltaResponse continuation dispatch (G4)', () {
    test(
      'receiving a truncated DeltaResponse immediately sends a continuation '
      'DeltaRequest to the same peer',
      () async {
        final h = GossipEngineTestHarness(
          gossipInterval: const Duration(seconds: 100),
        );
        final peer = h.addPeer('peer1');
        h.createChannel('ch1', streamIds: ['s1']);
        h.startListening();
        h.engine.start();
        final (messages, sub) = h.captureMessages(peer);

        await peer.port.send(
          h.localNode,
          h.codec.encode(
            DeltaResponse(
              sender: peer.id,
              channelId: channelId,
              streamId: streamId,
              entries: [entryOf(1, 1001), entryOf(2, 1002)],
              hasMore: true,
            ),
          ),
        );
        await h.flush(3);

        final reqs = messages.whereType<DeltaRequest>().toList();
        expect(
          reqs.length,
          equals(1),
          reason:
              'a truncated page must trigger an immediate continuation rather '
              'than waiting for the periodic round to re-select the peer',
        );
        expect(reqs.single.since[authorA], equals(2));

        await sub.cancel();
        h.engine.stop();
        h.stopListening();
      },
    );
  });

  group('DeltaResponse continuation end-to-end (G4)', () {
    test(
      'a multi-page backlog fully drains via continuation from a single '
      'round, with no periodic-round advance and no infinite loop',
      () async {
        final nodeA = NodeId('nodeA');
        final nodeB = NodeId('nodeB');
        final registryA = PeerRegistry(localNode: nodeA)
          ..addPeer(nodeB, occurredAt: DateTime.now());
        final registryB = PeerRegistry(localNode: nodeB)
          ..addPeer(nodeA, occurredAt: DateTime.now());
        final entryRepoA = InMemoryEntryRepository();
        final entryRepoB = InMemoryEntryRepository();
        final bus = InMemoryMessageBus();

        final channelA = ChannelAggregate(id: channelId, localNode: nodeA)
          ..createStream(streamId, const KeepAllRetention(),
              occurredAt: DateTime.now());
        final channelB = ChannelAggregate(id: channelId, localNode: nodeB)
          ..createStream(streamId, const KeepAllRetention(),
              occurredAt: DateTime.now());

        // B holds a 20-entry backlog of 4KB entries — many 30KB pages.
        for (var i = 1; i <= 20; i++) {
          await entryRepoB.append(
            channelId,
            streamId,
            entryOf(i, 1000 + i, payloadBytes: 4 * 1024),
          );
        }

        GossipEngine engine(
          NodeId node,
          PeerRegistry registry,
          InMemoryEntryRepository repo,
        ) =>
            GossipEngine(
              codec: SyncMessageCodec(),
              localNode: node,
              peerDirectory: MembershipPeerDirectory(registry),
              entryRepository: repo,
              timePort: InMemoryTimePort(),
              messagePort: InMemoryMessagePort(node, bus),
              localNodeRepository: InMemoryLocalNodeRepository(nodeId: node),
              maxDeltaResponseBytes: 30 * 1024,
            );

        final engineA = engine(nodeA, registryA, entryRepoA);
        final engineB = engine(nodeB, registryB, entryRepoB);
        engineA.startListening({channelId: channelA});
        engineB.startListening({channelId: channelB});
        engineA.start();
        engineB.start();

        // A single round kicks it off; continuations drain the rest through
        // the microtask cascade — no timer advance.
        await engineA.performGossipRound();
        for (var i = 0;
            i < 100 &&
                await entryRepoA.entryCount(channelId, streamId) < 20;
            i++) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(
          await entryRepoA.entryCount(channelId, streamId),
          equals(20),
          reason:
              'the whole backlog should drain via continuation from one '
              'round, not one page per periodic round',
        );

        engineA.stop();
        engineB.stop();
        engineA.stopListening();
        engineB.stopListening();
      },
    );
  });
}
