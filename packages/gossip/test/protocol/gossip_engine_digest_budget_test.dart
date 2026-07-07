import 'dart:async';
import 'dart:typed_data';

import 'package:gossip/src/domain/aggregates/channel_aggregate.dart';
import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/domain/errors/sync_error.dart';
import 'package:gossip/src/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/version_vector.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_time_port.dart';
import 'package:gossip/src/infrastructure/ports/message_port.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_local_node_repository.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:gossip/src/protocol/gossip_engine.dart';
import 'package:gossip/src/protocol/messages/digest_request.dart';
import 'package:gossip/src/protocol/messages/digest_response.dart';
import 'package:gossip/src/protocol/values/channel_digest.dart';
import 'package:gossip/src/protocol/values/stream_digest.dart';
import 'package:test/test.dart';

import 'gossip_engine_test_harness.dart';

void main() {
  final channelId = ChannelId('ch1');

  /// Appends one entry per author to [streamId] so its version vector has
  /// [authorCount] entries.
  Future<void> seed(
    GossipEngineTestHarness h,
    String streamId,
    int authorCount,
  ) async {
    for (var a = 0; a < authorCount; a++) {
      await h.appendEntry(
        channelId,
        StreamId(streamId),
        LogEntry(
          author: NodeId('author-$a'),
          sequence: 1,
          timestamp: Hlc(1000 + a, 0),
          payload: Uint8List.fromList([a]),
        ),
      );
    }
  }

  /// Captures DigestRequests and their raw encoded sizes arriving at [peer].
  (List<DigestRequest>, List<int>, StreamSubscription<IncomingMessage>)
  captureDigestRequests(GossipEngineTestHarness h, GossipTestPeer peer) {
    final reqs = <DigestRequest>[];
    final sizes = <int>[];
    final sub = peer.port.incoming.listen((msg) {
      final decoded = h.codec.decode(msg.bytes);
      if (decoded is DigestRequest) {
        reqs.add(decoded);
        sizes.add(msg.bytes.length);
      }
    });
    return (reqs, sizes, sub);
  }

  int streamCountOf(DigestRequest req) =>
      req.digests.fold<int>(0, (s, cd) => s + cd.streams.length);

  group('DigestRequest budgeting (H4)', () {
    test('a within-budget digest is sent in full (common case unchanged)',
        () async {
      final h = GossipEngineTestHarness(
        gossipInterval: const Duration(seconds: 100),
      );
      final peer = h.addPeer('peer1');
      h.createChannel('ch1', streamIds: ['s0', 's1', 's2']);
      for (final s in ['s0', 's1', 's2']) {
        await seed(h, s, 2);
      }
      h.startListening();
      h.engine.start();
      final (reqs, sizes, sub) = captureDigestRequests(h, peer);

      await h.engine.performGossipRound();
      await h.flush(3);

      expect(streamCountOf(reqs.single), equals(3),
          reason: 'all streams fit — full digest, no pagination');

      await sub.cancel();
      h.engine.stop();
      h.stopListening();
    });

    test('an oversized digest is paginated to fit the transport budget',
        () async {
      final h = GossipEngineTestHarness(
        maxDeltaResponseBytes: 300,
        gossipInterval: const Duration(seconds: 100),
      );
      final peer = h.addPeer('peer1');
      final streams = [for (var i = 0; i < 10; i++) 's$i'];
      h.createChannel('ch1', streamIds: streams);
      for (final s in streams) {
        await seed(h, s, 3);
      }
      h.startListening();
      h.engine.start();
      final (reqs, sizes, sub) = captureDigestRequests(h, peer);

      await h.engine.performGossipRound();
      await h.flush(3);

      expect(sizes.single, lessThanOrEqualTo(300),
          reason: 'the digest must fit the transport budget');
      expect(streamCountOf(reqs.single), lessThan(10),
          reason: 'oversized digest is sent as a subset');
      expect(streamCountOf(reqs.single), greaterThan(0),
          reason: 'but never empty — progress is made every round');

      await sub.cancel();
      h.engine.stop();
      h.stopListening();
    });

    test('rotation covers every stream over successive rounds', () async {
      final h = GossipEngineTestHarness(
        maxDeltaResponseBytes: 300,
        gossipInterval: const Duration(seconds: 100),
      );
      final peer = h.addPeer('peer1');
      final streams = [for (var i = 0; i < 10; i++) 's$i'];
      h.createChannel('ch1', streamIds: streams);
      for (final s in streams) {
        await seed(h, s, 3);
      }
      h.startListening();
      h.engine.start();
      final (reqs, sizes, sub) = captureDigestRequests(h, peer);

      final covered = <String>{};
      for (var round = 0; round < 20 && covered.length < 10; round++) {
        await h.engine.performGossipRound();
        await h.flush(3);
        for (final req in reqs) {
          for (final cd in req.digests) {
            for (final sd in cd.streams) {
              covered.add(sd.streamId.value);
            }
          }
        }
        reqs.clear();
      }

      expect(covered, equals(streams.toSet()),
          reason: 'round-robin rotation must eventually advertise every '
              'stream, or the tail never syncs');
      expect(sizes, everyElement(lessThanOrEqualTo(300)));

      await sub.cancel();
      h.engine.stop();
      h.stopListening();
    });

    test('a single stream whose version vector alone exceeds the budget is '
        'skipped with a distinct error, without blocking other streams',
        () async {
      final errors = <SyncError>[];
      final h = GossipEngineTestHarness(
        maxDeltaResponseBytes: 250,
        gossipInterval: const Duration(seconds: 100),
      );
      // Route engine errors into our list.
      final peer = h.addPeer('peer1');
      h.errors.clear();
      h.createChannel('ch1', streamIds: ['big', 'small']);
      await seed(h, 'big', 60); // huge VV — alone exceeds 250 bytes
      await seed(h, 'small', 1); // fits
      h.startListening();
      h.engine.start();
      final (reqs, sizes, sub) = captureDigestRequests(h, peer);

      // Cover a couple of rounds so rotation reaches both streams.
      for (var i = 0; i < 4; i++) {
        await h.engine.performGossipRound();
        await h.flush(3);
      }
      errors.addAll(h.errors);

      final advertised = {
        for (final r in reqs)
          for (final cd in r.digests)
            for (final sd in cd.streams) sd.streamId.value,
      };
      expect(advertised, contains('small'),
          reason: 'the deliverable stream still syncs');
      expect(advertised, isNot(contains('big')),
          reason: 'the oversized stream is skipped, not silently retried');
      expect(errors, isNotEmpty,
          reason: 'an un-sendable stream digest must surface a distinct error');
      expect(sizes, everyElement(lessThanOrEqualTo(250)));

      await sub.cancel();
      h.engine.stop();
      h.stopListening();
    });
  });

  group('DigestResponse budgeting (H4)', () {
    test('handleDigestRequest budgets its response to the transport limit',
        () async {
      final h = GossipEngineTestHarness(
        maxDeltaResponseBytes: 300,
        gossipInterval: const Duration(seconds: 100),
      );
      final peer = h.addPeer('peer1');
      final streams = [for (var i = 0; i < 10; i++) 's$i'];
      h.createChannel('ch1', streamIds: streams);
      for (final s in streams) {
        await seed(h, s, 3);
      }
      h.startListening();
      h.engine.start();

      final responseSizes = <int>[];
      final sub = peer.port.incoming.listen((msg) {
        final decoded = h.codec.decode(msg.bytes);
        if (decoded is DigestResponse) responseSizes.add(msg.bytes.length);
      });

      // Peer asks for all 10 streams at once.
      await peer.port.send(
        h.localNode,
        h.codec.encode(
          DigestRequest(
            sender: peer.id,
            digests: [
              ChannelDigest(
                channelId: channelId,
                streams: [
                  for (final s in streams)
                    StreamDigest(
                      streamId: StreamId(s),
                      version: VersionVector.empty,
                    ),
                ],
              ),
            ],
          ),
        ),
      );
      await h.flush(3);

      expect(responseSizes, isNotEmpty);
      expect(responseSizes.single, lessThanOrEqualTo(300),
          reason: 'the response must also fit the budget, even when the '
              'request asked for more than fits');

      await sub.cancel();
      h.engine.stop();
      h.stopListening();
    });
  });

  group('Oversized-digest convergence end-to-end (H4)', () {
    test(
      'two nodes converge across every stream over rounds despite a digest '
      'too large to send in one message',
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
        final streams = [for (var i = 0; i < 10; i++) 's$i'];

        ChannelAggregate channel(NodeId node) {
          final c = ChannelAggregate(id: channelId, localNode: node);
          for (final s in streams) {
            c.createStream(StreamId(s), const KeepAllRetention(),
                occurredAt: DateTime.now());
          }
          return c;
        }

        final channelA = channel(nodeA);
        final channelB = channel(nodeB);

        // B has 3 authors' entries in every stream; A has none.
        for (final s in streams) {
          for (var a = 0; a < 3; a++) {
            await entryRepoB.append(
              channelId,
              StreamId(s),
              LogEntry(
                author: NodeId('author-$a'),
                sequence: 1,
                timestamp: Hlc(1000 + a, 0),
                payload: Uint8List.fromList([a]),
              ),
            );
          }
        }

        GossipEngine engine(
          NodeId node,
          PeerRegistry registry,
          InMemoryEntryRepository repo,
        ) =>
            GossipEngine(
              localNode: node,
              peerRegistry: registry,
              entryRepository: repo,
              timePort: InMemoryTimePort(),
              messagePort: InMemoryMessagePort(node, bus),
              localNodeRepository: InMemoryLocalNodeRepository(nodeId: node),
              maxDeltaResponseBytes: 300, // forces digest pagination
            );

        final engineA = engine(nodeA, registryA, entryRepoA);
        final engineB = engine(nodeB, registryB, entryRepoB);
        engineA.startListening({channelId: channelA});
        engineB.startListening({channelId: channelB});
        engineA.start();
        engineB.start();

        Future<int> totalA() async {
          var total = 0;
          for (final s in streams) {
            total += await entryRepoA.entryCount(channelId, StreamId(s));
          }
          return total;
        }

        for (var round = 0; round < 40 && await totalA() < 30; round++) {
          await engineA.performGossipRound();
          for (var p = 0; p < 12; p++) {
            await Future<void>.delayed(Duration.zero);
          }
        }

        for (final s in streams) {
          expect(
            await entryRepoA.entryCount(channelId, StreamId(s)),
            equals(3),
            reason: 'stream $s must fully sync — rotation covers every stream',
          );
        }

        engineA.stop();
        engineB.stop();
        engineA.stopListening();
        engineB.stopListening();
      },
    );
  });
}
