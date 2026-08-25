import 'dart:typed_data';

import 'package:gossip/src/membership/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/shared/domain/errors/sync_error.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_message_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_entry_repository.dart';
import 'package:gossip/src/sync/application/gossip_engine.dart';
import 'package:gossip/src/sync/infrastructure/membership_peer_directory.dart';
import 'package:gossip/src/sync/infrastructure/sync_message_codec.dart';
import 'package:gossip/src/sync/domain/messages/delta_response.dart';
import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:gossip/src/sync/domain/messages/digest_response.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';
import 'package:test/test.dart';

import '../../support/failing_delay_time_port.dart';
import '../../support/pump.dart';
import '../../support/scripted_delay_time_port.dart';
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

    test('delay failure emits an error and stops the loop instead of dying '
        'silently', () async {
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
      await pumpEventQueue();

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
    });

    test(
      'a live scheduling failure does not permanently wedge reactive push',
      () async {
        // Delay-call ordering on the shared `timePort` (see
        // ScriptedDelayTimePort's doc — it addresses calls by position
        // because this scenario needs an EARLIER call, the debounce, to
        // still be in flight when a LATER call, the round loop's, fails):
        //   call #1 — the round loop's delay, scheduled synchronously by
        //             engine.start(). Scripted to fail.
        //   call #2 — notifyLocalWrite's debounce delay for the first
        //             write. Real (delegates to `inner`), so it stays
        //             genuinely pending while call #1's failure resolves.
        //   call #3 — the round loop's delay from the post-heal restart's
        //             engine.start(). Real; never asserted on directly.
        //   call #4 — would be notifyLocalWrite's debounce for the second
        //             write, IF the flag it's gated on got reset by the
        //             live failure. The fix under test is what makes this
        //             call happen at all.
        final timePort = ScriptedDelayTimePort(failDelayCalls: {1});
        final localNode = NodeId('local');
        final peerId = NodeId('peer');
        final peerRegistry = PeerRegistry(localNode: localNode)
          ..addPeer(peerId, occurredAt: DateTime.now());
        final bus = InMemoryMessageBus();
        final peerPort = InMemoryMessagePort(peerId, bus);
        final codec = SyncMessageCodec();
        final errors = <SyncError>[];
        final channelId = ChannelId('ch1');
        final streamId = StreamId('s1');

        final engine = GossipEngine(
          codec: codec,
          localNode: localNode,
          peerDirectory: MembershipPeerDirectory(peerRegistry),
          entryRepository: InMemoryEntryRepository(),
          timePort: timePort,
          messagePort: InMemoryMessagePort(localNode, bus),
          localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
          onError: errors.add,
          gossipInterval: const Duration(milliseconds: 100),
        );

        final received = <dynamic>[];
        final sub = peerPort.incoming.listen(
          (msg) => received.add(codec.decode(msg.bytes)),
        );

        // call #1 (scripted to fail).
        engine.start();
        // call #2 (real debounce) — captures the pre-failure generation.
        engine.notifyLocalWrite(
          channelId,
          streamId,
          LogEntry(
            author: localNode,
            sequence: 1,
            timestamp: Hlc(1000, 0),
            payload: Uint8List.fromList([0x01]),
          ),
        );

        // Let call #1's scripted failure propagate through
        // GenerationScheduler's catchError into onSchedulingError's live
        // branch (isRunning reads false by the time that callback runs).
        await pumpEventQueue();

        expect(
          errors,
          isNotEmpty,
          reason:
              'the scripted scheduling failure must surface via '
              'ErrorCallback',
        );
        expect(
          engine.isRunning,
          isFalse,
          reason: 'a live scheduling failure stops the loop',
        );

        // Let call #2 reach its 150ms debounce deadline. With the wedge,
        // its captured generation is now stale (bumped by
        // onSchedulingError), so it takes the "stale run — do nothing"
        // early return without resetting `_pushFlushScheduled`.
        await timePort.advance(const Duration(milliseconds: 200));

        // Heal and restart: after observing the scheduling error (a
        // PeerSyncError, protocolError, 'Gossip round scheduling failed'),
        // the app calls stop() then start() to bring the round loop back
        // up. stop() is a no-op here (the scheduler already stopped
        // itself), start() issues call #3.
        engine.stop();
        engine.start();

        // A fresh local write after the restart. If `_pushFlushScheduled`
        // is still (wrongly) true, the `if (_pushFlushScheduled) return;`
        // guard bails before scheduling call #4, and this entry never
        // reaches the peer via reactive push.
        engine.notifyLocalWrite(
          channelId,
          streamId,
          LogEntry(
            author: localNode,
            sequence: 2,
            timestamp: Hlc(1001, 0),
            payload: Uint8List.fromList([0x02]),
          ),
        );

        // Past the 150ms debounce window (generous enough to also cover
        // the restarted round loop's own jittered delay — harmless here,
        // since the round's own gossip has no reachable-peer digest state
        // to disturb this assertion).
        await timePort.advance(const Duration(milliseconds: 250));
        await pumpUntil(
          () => received.whereType<DeltaResponse>().any(
            (r) => r.entries.any((e) => e.sequence == 2),
          ),
          describe: 'the post-restart local write reaching the peer',
        );

        expect(
          received.whereType<DeltaResponse>().any(
            (r) => r.entries.any((e) => e.sequence == 2),
          ),
          isTrue,
          reason:
              'a local write after a healed restart must still reach peers '
              'via reactive push — a live scheduling failure must not '
              'permanently wedge notifyLocalWrite',
        );

        await sub.cancel();
        engine.stop();
      },
    );

    test('a stale scheduling failure alongside a live loop does not wedge '
        'reactive push either', () async {
      // The sibling test above pins the LIVE case: a failure that stops
      // the loop (`_scheduler.isRunning == false` when onSchedulingError
      // runs) must bump `_pushGeneration`. GenerationScheduler also
      // invokes onSchedulingError for a STALE failure — one from a
      // generation a restart has already superseded — and that path is
      // the opposite: `_scheduler.isRunning` reads true (the restart's
      // own loop is genuinely live), so the fix must NOT bump. An
      // unconditional bump would invalidate the live loop's own
      // in-flight debounce for no reason, wedging a write that never
      // had anything go wrong with it.
      //
      // Delay-call ordering on the shared `timePort`:
      //   call #1 — the round loop's delay from the first engine.start().
      //             Scripted to fail. Its rejection is a Future.error
      //             completed synchronously inside delay(), but Dart
      //             never runs a Future's callbacks synchronously — so
      //             it stays unprocessed until the next microtask
      //             boundary, which is after calls #2 and #3 below.
      //   call #2 — the round loop's delay from the restart's
      //             engine.start(), issued synchronously right after
      //             stop(). Real; this is the "live loop" the stale
      //             call #1 must not disturb.
      //   call #3 — notifyLocalWrite's debounce for a write issued
      //             synchronously right after the restart, before call
      //             #1's rejection has had a chance to run. Real.
      // Only once all three calls are in flight does pumpEventQueue let
      // call #1's rejection process — by then generation 1 is stale and
      // the loop from call #2 is already the live one.
      final timePort = ScriptedDelayTimePort(failDelayCalls: {1});
      final localNode = NodeId('local');
      final peerId = NodeId('peer');
      final peerRegistry = PeerRegistry(localNode: localNode)
        ..addPeer(peerId, occurredAt: DateTime.now());
      final bus = InMemoryMessageBus();
      final peerPort = InMemoryMessagePort(peerId, bus);
      final codec = SyncMessageCodec();
      final errors = <SyncError>[];
      final channelId = ChannelId('ch1');
      final streamId = StreamId('s1');

      final engine = GossipEngine(
        codec: codec,
        localNode: localNode,
        peerDirectory: MembershipPeerDirectory(peerRegistry),
        entryRepository: InMemoryEntryRepository(),
        timePort: timePort,
        messagePort: InMemoryMessagePort(localNode, bus),
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        onError: errors.add,
        gossipInterval: const Duration(milliseconds: 100),
      );

      final received = <dynamic>[];
      final sub = peerPort.incoming.listen(
        (msg) => received.add(codec.decode(msg.bytes)),
      );

      // call #1 (scripted to fail, but not processed until a microtask
      // boundary — see the ordering note above).
      engine.start();
      // call #2 (real): stop()/start() synchronously, before call #1's
      // rejection is processed, so the restart's generation is already
      // current by the time it runs.
      engine.stop();
      engine.start();
      // call #3 (real debounce), also issued before call #1 resolves —
      // this write's captured push generation must survive the stale
      // failure below untouched.
      engine.notifyLocalWrite(
        channelId,
        streamId,
        LogEntry(
          author: localNode,
          sequence: 1,
          timestamp: Hlc(1000, 0),
          payload: Uint8List.fromList([0x01]),
        ),
      );

      // Let call #1's stale rejection process.
      await pumpEventQueue();

      expect(
        errors,
        isNotEmpty,
        reason:
            'GenerationScheduler reports onSchedulingError for a stale '
            'failure too, even though it does not act on it',
      );
      expect(
        engine.isRunning,
        isTrue,
        reason:
            'a stale scheduling failure must not stop the live loop the '
            'restart established',
      );

      // Past the 150ms debounce window (generous enough to also cover
      // the restarted round loop's own jittered delay, same as the
      // sibling test).
      await timePort.advance(const Duration(milliseconds: 250));
      await pumpUntil(
        () => received.whereType<DeltaResponse>().any(
          (r) => r.entries.any((e) => e.sequence == 1),
        ),
        describe: 'the write reaching the peer despite the stale failure',
      );

      expect(
        received.whereType<DeltaResponse>().any(
          (r) => r.entries.any((e) => e.sequence == 1),
        ),
        isTrue,
        reason:
            'a stale scheduling failure must not wedge reactive push for '
            'a write the live loop was never actually broken for',
      );

      await sub.cancel();
      engine.stop();
    });
  });
}
