import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/domain/errors/sync_error.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_local_node_repository.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:gossip/src/protocol/gossip_engine.dart';
import 'package:gossip/src/sync/infrastructure/membership_peer_directory.dart';
import 'package:gossip/src/sync/infrastructure/sync_message_codec.dart';
import 'package:gossip/src/protocol/messages/digest_request.dart';
import 'package:gossip/src/protocol/messages/digest_response.dart';
import 'package:gossip/src/protocol/values/channel_digest.dart';
import 'package:test/test.dart';

import 'failing_delay_time_port.dart';
import 'gossip_engine_test_harness.dart';

void main() {
  group('GossipEngine scheduling', () {
    test('start begins periodic gossip rounds', () {
      final h = GossipEngineTestHarness();

      h.engine.start();
      expect(h.engine.isRunning, isTrue);

      h.engine.stop();
    });

    test('stop cancels gossip rounds', () {
      final h = GossipEngineTestHarness();

      h.engine.start();
      expect(h.engine.isRunning, isTrue);

      h.engine.stop();
      expect(h.engine.isRunning, isFalse);
    });

    test('start() twice is idempotent', () {
      final h = GossipEngineTestHarness();

      h.engine.start();
      expect(h.engine.isRunning, isTrue);
      expect(h.timePort.pendingDelayCount, equals(1));

      h.engine.start();
      expect(h.engine.isRunning, isTrue);
      expect(h.timePort.pendingDelayCount, equals(1));

      h.engine.stop();
    });

    test('stop() twice does not throw', () {
      final h = GossipEngineTestHarness();

      h.engine.start();
      h.engine.stop();
      expect(h.engine.isRunning, isFalse);

      h.engine.stop();
      expect(h.engine.isRunning, isFalse);
    });

    test('stop() before start() does not throw', () {
      final h = GossipEngineTestHarness();

      h.engine.stop();
      expect(h.engine.isRunning, isFalse);
    });

    test('startListening() twice does not leak subscriptions', () async {
      final h = GossipEngineTestHarness();
      final peer = h.addPeer('peer1');
      h.createChannel('ch1', streamIds: ['s1']);

      h.startListening();
      h.startListening();

      // Send a DigestRequest — should only be processed once
      final request = DigestRequest(
        sender: peer.id,
        digests: [ChannelDigest(channelId: ChannelId('ch1'), streams: [])],
      );
      await peer.port.send(h.localNode, h.codec.encode(request));
      await h.flush();

      // Peer should receive exactly 1 DigestResponse (not 2)
      final (messages, sub) = h.captureMessages(peer);

      final request2 = DigestRequest(
        sender: peer.id,
        digests: [ChannelDigest(channelId: ChannelId('ch1'), streams: [])],
      );
      await peer.port.send(h.localNode, h.codec.encode(request2));
      await h.flush();

      expect(messages.whereType<DigestResponse>().length, equals(1));

      await sub.cancel();
      h.stopListening();
    });

    test(
      'stop() then start() within one interval does not fork the round loop',
      () async {
        final h = GossipEngineTestHarness(
          gossipInterval: const Duration(milliseconds: 100),
        );

        h.engine.start(); // schedules callback #1
        h.engine.stop();
        h.engine.start(); // schedules callback #2; #1 must become stale

        // Both scheduled callbacks are in flight.
        expect(h.timePort.pendingDelayCount, equals(2));

        // Fire both. Only the live loop may run a round and reschedule;
        // the stale pre-stop callback must not spawn a second chain.
        // 130ms > the 100ms interval + its max +20% jitter, so the round
        // always fires (but not far enough to fire the reschedule too).
        await h.timePort.advance(const Duration(milliseconds: 130));
        await h.flush(3);

        expect(
          h.timePort.pendingDelayCount,
          equals(1),
          reason: 'exactly one gossip loop must survive a stop/start cycle',
        );

        h.engine.stop();
      },
    );

    test(
      'repeated stop/start cycles never accumulate extra round loops',
      () async {
        final h = GossipEngineTestHarness(
          gossipInterval: const Duration(milliseconds: 100),
        );

        for (var i = 0; i < 3; i++) {
          h.engine.start();
          h.engine.stop();
        }
        h.engine.start();

        // Let several intervals elapse; a single loop reschedules itself
        // exactly once per interval.
        for (var i = 0; i < 3; i++) {
          // 130ms > the 100ms interval + its max +20% jitter, so the round
        // always fires (but not far enough to fire the reschedule too).
        await h.timePort.advance(const Duration(milliseconds: 130));
          await h.flush(3);
          expect(
            h.timePort.pendingDelayCount,
            equals(1),
            reason: 'interval ${i + 1}: only one loop may be scheduled',
          );
        }

        h.engine.stop();
      },
    );

    test(
      'delay failure emits an error and stops the loop instead of dying '
      'silently',
      () async {
        final timePort = FailingDelayTimePort();
        final localNode = NodeId('local');
        final errors = <SyncError>[];
        final engine = GossipEngine(
          codec: SyncMessageCodec(),
          localNode: localNode,
          peerDirectory: MembershipPeerDirectory(
            PeerRegistry(localNode: localNode),
          ),
          entryRepository: InMemoryEntryRepository(),
          timePort: timePort,
          messagePort: InMemoryMessagePort(localNode, InMemoryMessageBus()),
          localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
          onError: errors.add,
          gossipInterval: const Duration(milliseconds: 100),
        );

        timePort.failNextDelay = true;
        engine.start();

        // Let the failed delay future propagate.
        await Future.delayed(Duration.zero);
        await Future.delayed(Duration.zero);

        expect(
          errors,
          isNotEmpty,
          reason: 'a scheduling failure must surface via ErrorCallback',
        );
        expect(
          engine.isRunning,
          isFalse,
          reason: 'a dead loop must not report itself as running',
        );
      },
    );
  });
}
