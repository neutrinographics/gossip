import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/sync/domain/aggregates/channel_aggregate.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_message_port.dart';
import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'dart:typed_data';

import 'gossip_engine_test_harness.dart';
import '../../support/floor_jitter_random.dart';
import '../../support/unjittered_random.dart';

/// Two-tier pacing (spec 2026-08-20): quiet rounds stretch the adaptive
/// interval toward the 30s ceiling; any news snaps it back to base.
void main() {
  group('GossipEngine quiescence pacing', () {
    test('consecutive no-news rounds grow the effective interval', () async {
      final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 500));
      // Base = median SRTT * 2 = 1s.
      expect(h.engine.effectiveGossipInterval, const Duration(seconds: 1));

      h.engine.start();
      await h.engine.performGossipRound(); // first round: news flag from start
      await h.engine.performGossipRound(); // quiet
      await h.engine.performGossipRound(); // quiet

      expect(
        h.engine.effectiveGossipInterval,
        greaterThan(const Duration(seconds: 1)),
      );
      h.engine.stop();
    });

    test('a local write snaps the interval back to base', () async {
      final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 500));
      h.engine.start();
      for (var i = 0; i < 6; i++) {
        await h.engine.performGossipRound();
      }
      expect(
        h.engine.effectiveGossipInterval,
        greaterThan(const Duration(seconds: 1)),
      );

      h.engine.notifyLocalWrite(
        ChannelId('ch'),
        StreamId('s'),
        LogEntry(
          author: h.localNode,
          sequence: 1,
          timestamp: Hlc(1, 0),
          payload: Uint8List.fromList([1]),
        ),
      );

      expect(h.engine.effectiveGossipInterval, const Duration(seconds: 1));
      h.engine.stop();
    });

    test('the paced interval clamps at the 30s ceiling', () async {
      final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(seconds: 2));
      h.engine.start();
      for (var i = 0; i < 30; i++) {
        await h.engine.performGossipRound();
      }
      expect(h.engine.effectiveGossipInterval, const Duration(seconds: 30));
      h.engine.stop();
    });

    test('a static gossipInterval bypasses the pacer entirely', () async {
      final h = GossipEngineTestHarness(
        gossipInterval: const Duration(seconds: 2),
      );
      h.addPeer('peer1');
      h.engine.start();
      for (var i = 0; i < 6; i++) {
        await h.engine.performGossipRound();
      }
      expect(h.engine.effectiveGossipInterval, const Duration(seconds: 2));
      h.engine.stop();
    });

    test('merged entries are news: the interval snaps back', () async {
      final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 500));
      final channelId = ChannelId('ch');
      final streamId = StreamId('s');
      await h.createChannelWithStream(channelId, streamId);
      h.engine.start();
      for (var i = 0; i < 6; i++) {
        await h.engine.performGossipRound();
      }
      expect(
        h.engine.effectiveGossipInterval,
        greaterThan(const Duration(seconds: 1)),
      );

      // A peer-authored entry arriving as an unsolicited push merges and
      // must reset the cadence.
      await h.deliverDeltaResponse(
        from: peer,
        channelId: channelId,
        streamId: streamId,
        entries: [
          LogEntry(
            author: peer.id,
            sequence: 1,
            timestamp: Hlc(1, 0),
            payload: Uint8List.fromList([7]),
          ),
        ],
      );

      expect(h.engine.effectiveGossipInterval, const Duration(seconds: 1));
      h.engine.stop();
    });

    test(
      'an inbound DeltaRequest is news (the peer is pulling from us)',
      () async {
        final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
        final peer = h.addPeer('peer1');
        h.peerRegistry.recordPeerRtt(
          peer.id,
          const Duration(milliseconds: 500),
        );
        final channelId = ChannelId('ch');
        final streamId = StreamId('s');
        await h.createChannelWithStream(channelId, streamId);
        h.engine.start();
        for (var i = 0; i < 6; i++) {
          await h.engine.performGossipRound();
        }
        expect(
          h.engine.effectiveGossipInterval,
          greaterThan(const Duration(seconds: 1)),
        );

        await h.deliverDeltaRequest(
          from: peer,
          channelId: channelId,
          streamId: streamId,
        );

        expect(h.engine.effectiveGossipInterval, const Duration(seconds: 1));
        h.engine.stop();
      },
    );

    test('syncWithPeer (join/reconnect) is news', () async {
      final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 500));
      h.engine.start();
      for (var i = 0; i < 6; i++) {
        await h.engine.performGossipRound();
      }
      await h.engine.syncWithPeer(peer.id);
      expect(h.engine.effectiveGossipInterval, const Duration(seconds: 1));
      h.engine.stop();
    });

    test('a created channel is news (kt GossipEngineTest)', () async {
      final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 500));
      h.engine.start();
      for (var i = 0; i < 6; i++) {
        await h.engine.performGossipRound();
      }
      expect(
        h.engine.effectiveGossipInterval,
        greaterThan(const Duration(seconds: 1)),
      );
      h.engine.notifyChannelCreated(ChannelId('fresh'));
      expect(h.engine.effectiveGossipInterval, const Duration(seconds: 1));
      h.engine.stop();
    });

    test('a created channel on a stopped engine is not news', () async {
      final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 500));
      h.engine.start();
      for (var i = 0; i < 6; i++) {
        await h.engine.performGossipRound();
      }
      h.engine.stop();
      final stretched = h.engine.effectiveGossipInterval;
      expect(stretched, greaterThan(const Duration(seconds: 1)));

      h.engine.notifyChannelCreated(ChannelId('fresh'));

      expect(h.engine.effectiveGossipInterval, stretched);
    });

    test('setChannels alone is not news', () async {
      final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 500));
      h.engine.start();
      for (var i = 0; i < 6; i++) {
        await h.engine.performGossipRound();
      }
      final stretched = h.engine.effectiveGossipInterval;
      expect(stretched, greaterThan(const Duration(seconds: 1)));

      h.engine.setChannels({
        ChannelId('extra'): ChannelAggregate(
          id: ChannelId('extra'),
          localNode: h.localNode,
        ),
      });

      expect(h.engine.effectiveGossipInterval, stretched);
      h.engine.stop();
    });

    test('peer removal (clearPendingRequestsForPeer) is news', () async {
      final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 500));
      h.engine.start();
      for (var i = 0; i < 6; i++) {
        await h.engine.performGossipRound();
      }
      h.engine.clearPendingRequestsForPeer(peer.id);
      expect(h.engine.effectiveGossipInterval, const Duration(seconds: 1));
      h.engine.stop();
    });
  });

  group('news wakes the round', () {
    test('a merge wakes the round instead of waiting out the interval armed '
        'before it', () async {
      final h = GossipEngineTestHarness(
        adaptiveTimingEnabled: true,
        random: UnjitteredRandom(),
      );
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 100));
      final channelId = ChannelId('ch');
      final streamId = StreamId('s');
      await h.createChannelWithStream(channelId, streamId);

      // Delivers the merge from a node that is NOT a gossip partner, so
      // the engine's next round has only [peer] to target — "another
      // peer" (the ruling's phrase) is true by construction, not by a
      // round-robin tiebreak this test would otherwise have to control.
      final mergeSource = GossipTestPeer(
        NodeId('merge-source'),
        InMemoryMessagePort(NodeId('merge-source'), h.bus),
      );

      h.engine.start();
      // Round 1 consumes start()'s own news flag — the pacer is not
      // stretched by it.
      await h.timePort.advance(h.engine.effectiveGossipInterval);
      await pumpEventQueue();

      // Several quiet rounds stretch the pacer well past the active
      // cadence — the "pacer stretched by several quiet rounds" the
      // ruling names.
      for (var i = 0; i < 4; i++) {
        await h.timePort.advance(h.engine.effectiveGossipInterval);
        await pumpEventQueue();
      }
      expect(
        h.engine.effectiveGossipInterval,
        greaterThan(const Duration(milliseconds: 200)),
        reason: 'setup must actually stretch the pacer before the merge',
      );

      final (messages, sub) = h.captureMessages(peer);

      await h.deliverDeltaResponse(
        from: mergeSource,
        channelId: channelId,
        streamId: streamId,
        entries: [
          LogEntry(
            author: mergeSource.id,
            sequence: 1,
            timestamp: Hlc(1, 0),
            payload: Uint8List.fromList([7]),
          ),
        ],
      );

      // Just short of the active interval (200ms): the merge must not
      // have produced a round yet — the woken wait is the active
      // interval, not instant.
      await h.timePort.advance(const Duration(milliseconds: 199));
      await pumpEventQueue();
      expect(messages.whereType<DigestRequest>(), isEmpty);

      // The remaining 1ms crosses the active interval.
      await h.timePort.advance(const Duration(milliseconds: 1));
      await pumpEventQueue();
      expect(
        messages.whereType<DigestRequest>(),
        isNotEmpty,
        reason:
            'the merge must wake the round: the next DigestRequest to '
            'another peer goes out within the active interval of the '
            'merge, not the stretched interval that was pending',
      );

      await sub.cancel();
      h.engine.stop();
    });

    test('a local write wakes the round instead of waiting out the interval '
        'armed before it', () async {
      final h = GossipEngineTestHarness(
        adaptiveTimingEnabled: true,
        random: UnjitteredRandom(),
      );
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 100));
      final channelId = ChannelId('ch');
      final streamId = StreamId('s');
      await h.createChannelWithStream(channelId, streamId);

      h.engine.start();
      await h.timePort.advance(h.engine.effectiveGossipInterval);
      await pumpEventQueue();
      for (var i = 0; i < 4; i++) {
        await h.timePort.advance(h.engine.effectiveGossipInterval);
        await pumpEventQueue();
      }
      expect(
        h.engine.effectiveGossipInterval,
        greaterThan(const Duration(milliseconds: 200)),
        reason: 'setup must actually stretch the pacer before the write',
      );

      final (messages, sub) = h.captureMessages(peer);

      h.engine.notifyLocalWrite(
        channelId,
        streamId,
        LogEntry(
          author: h.localNode,
          sequence: 1,
          timestamp: Hlc(1, 0),
          payload: Uint8List.fromList([1]),
        ),
      );

      await h.timePort.advance(const Duration(milliseconds: 199));
      await pumpEventQueue();
      expect(messages.whereType<DigestRequest>(), isEmpty);

      await h.timePort.advance(const Duration(milliseconds: 1));
      await pumpEventQueue();
      expect(
        messages.whereType<DigestRequest>(),
        isNotEmpty,
        reason:
            'the local write must wake the round: the next DigestRequest '
            'goes out within the active interval of the write, not the '
            'stretched interval that was pending',
      );

      await sub.cancel();
      h.engine.stop();
    });

    test(
      'a created channel wakes the round instead of waiting out the interval '
      'armed before it',
      () async {
        final h = GossipEngineTestHarness(
          adaptiveTimingEnabled: true,
          random: UnjitteredRandom(),
        );
        final peer = h.addPeer('peer1');
        h.peerRegistry.recordPeerRtt(
          peer.id,
          const Duration(milliseconds: 100),
        );
        final channelId = ChannelId('ch');
        final streamId = StreamId('s');
        await h.createChannelWithStream(channelId, streamId);

        h.engine.start();
        await h.timePort.advance(h.engine.effectiveGossipInterval);
        await pumpEventQueue();
        for (var i = 0; i < 4; i++) {
          await h.timePort.advance(h.engine.effectiveGossipInterval);
          await pumpEventQueue();
        }
        expect(
          h.engine.effectiveGossipInterval,
          greaterThan(const Duration(milliseconds: 200)),
          reason: 'setup must actually stretch the pacer before the write',
        );

        final (messages, sub) = h.captureMessages(peer);

        h.engine.notifyChannelCreated(ChannelId('fresh'));

        await h.timePort.advance(const Duration(milliseconds: 199));
        await pumpEventQueue();
        expect(messages.whereType<DigestRequest>(), isEmpty);

        await h.timePort.advance(const Duration(milliseconds: 1));
        await pumpEventQueue();
        expect(
          messages.whereType<DigestRequest>(),
          isNotEmpty,
          reason:
              'the local write must wake the round: the next DigestRequest '
              'goes out within the active interval of the write, not the '
              'stretched interval that was pending',
        );

        await sub.cancel();
        h.engine.stop();
      },
    );

    test(
      'at the active cadence a minute holds the rounds it always held',
      () async {
        // A non-jittering random and news on every cycle: the wake this
        // triggers each round must find the pending wait already no longer
        // than a fresh one and leave it alone — a busy room must not round
        // faster than its own cadence just because it keeps getting news.
        final h = GossipEngineTestHarness(
          adaptiveTimingEnabled: true,
          random: UnjitteredRandom(),
        );
        final peer = h.addPeer('peer1');
        h.peerRegistry.recordPeerRtt(
          peer.id,
          const Duration(milliseconds: 125),
        );
        final channelId = ChannelId('ch');
        final streamId = StreamId('s');
        await h.createChannelWithStream(channelId, streamId);
        expect(
          h.engine.effectiveGossipInterval,
          const Duration(milliseconds: 250),
        );

        final (messages, sub) = h.captureMessages(peer);
        h.engine.start();

        const interval = Duration(milliseconds: 250);
        const half = Duration(milliseconds: 125);
        const oneMinute = Duration(minutes: 1);
        final cycles = oneMinute.inMilliseconds ~/ interval.inMilliseconds;
        for (var i = 0; i < cycles; i++) {
          await h.timePort.advance(half);
          await pumpEventQueue();
          h.engine.notifyLocalWrite(
            channelId,
            streamId,
            LogEntry(
              author: h.localNode,
              sequence: i + 1,
              timestamp: Hlc(i + 1, 0),
              payload: Uint8List.fromList([1]),
            ),
          );
          await h.timePort.advance(half);
          await pumpEventQueue();
        }

        expect(
          messages.whereType<DigestRequest>().length,
          equals(cycles),
          reason:
              'news every cycle must not add rounds beyond the cadence: '
              'each wake finds a wait already no longer than the fresh one '
              'and leaves it alone — and equals (not just lessThanOrEqualTo) '
              'also catches the opposite regression: an unconditional '
              'wake-driven re-arm at the midpoint would push every round '
              'out to +375ms and yield fewer than $cycles',
        );

        await sub.cancel();
        h.engine.stop();
      },
    );
  });

  group('GossipEngine recency suppression', () {
    test('handling an inbound DigestRequest records the exchange', () async {
      final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
      final peer = h.addPeer('peer1');
      await h.deliverDigestRequest(from: peer); // empty digests are fine

      final recorded = h.peerRegistry.getPeer(peer.id)!.lastAntiEntropyMs;
      expect(
        recorded,
        isNotNull,
        reason: 'a reciprocated exchange must count as coverage',
      );
    });

    test('a round skips a peer whose exchange is fresher than the '
        'recency window', () async {
      final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 500));
      h.engine.start();

      // Mark the peer as exchanged-with "now".
      h.peerRegistry.updatePeerAntiEntropy(peer.id, h.timePort.nowMs);
      final (messages, sub) = h.captureMessages(peer);

      await h.engine.performGossipRound();
      await h.flush(3);

      expect(
        messages,
        isEmpty,
        reason: 'all candidates fresh: the round must send nothing',
      );
      await sub.cancel();
      h.engine.stop();
    });

    // Kotlin twin: gossip-kt `GossipEngineTest`, "a node's own round at the
    // jitter floor is never suppressed on a static interval".
    test("a node's own round at the jitter floor is never suppressed on a "
        'static interval', () async {
      final h = GossipEngineTestHarness(
        gossipInterval: const Duration(seconds: 1),
        random: FloorJitterRandom(),
      );
      final peer = h.addPeer('peer1');
      final (messages, sub) = h.captureMessages(peer);
      h.engine.start();

      await h.timePort.advance(const Duration(milliseconds: 800));
      await pumpEventQueue();
      expect(
        messages.whereType<DigestRequest>(),
        hasLength(1),
        reason: 'round 1 must send',
      );

      await h.timePort.advance(const Duration(milliseconds: 800));
      await pumpEventQueue();
      expect(
        messages.whereType<DigestRequest>(),
        hasLength(2),
        reason:
            "round 2, one floor-jittered wait after round 1, must not read "
            "round 1's exchange as fresh",
      );

      await sub.cancel();
      h.engine.stop();
    });

    // Kotlin twin: gossip-kt `GossipEngineTest`, "a node's own round at the
    // jitter floor is never suppressed across a quiet-round growth". One
    // peer: with two, round 2 would go to the never-exchanged one and the
    // test could not tell a suppressed round from a sent one.
    test("a node's own round at the jitter floor is never suppressed across "
        'a quiet-round growth', () async {
      final h = GossipEngineTestHarness(
        adaptiveTimingEnabled: true,
        random: FloorJitterRandom(),
      );
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 500));
      final (messages, sub) = h.captureMessages(peer);
      h.engine.start();

      await h.timePort.advance(const Duration(milliseconds: 800));
      await pumpEventQueue();
      expect(
        messages.whereType<DigestRequest>(),
        hasLength(1),
        reason: "round 1 (start's news) must send",
      );

      // Round 2 is quiet and grows the interval to 1.5 s, but it slept the
      // 1 s interval's floor, and that is the window it is judged by.
      await h.timePort.advance(const Duration(milliseconds: 800));
      await pumpEventQueue();
      expect(
        messages.whereType<DigestRequest>(),
        hasLength(2),
        reason: "round 2 must not suppress round 1's exchange",
      );

      await h.timePort.advance(const Duration(milliseconds: 1200));
      await pumpEventQueue();
      expect(
        messages.whereType<DigestRequest>(),
        hasLength(3),
        reason: "round 3 must not suppress round 2's exchange",
      );
      expect(
        h.engine.effectiveGossipInterval,
        const Duration(milliseconds: 2250),
        reason: 'two quiet rounds of growth',
      );

      await sub.cancel();
      h.engine.stop();
    });

    // Kotlin twin: gossip-kt `GossipEngineTest`, "a peer's initiative inside
    // the window still suppresses the round".
    test(
      "a peer's initiative inside the window still suppresses the round",
      () async {
        final h = GossipEngineTestHarness(
          gossipInterval: const Duration(seconds: 1),
        );
        final peer = h.addPeer('peer1');
        // Seeded timestamps must stay positive: a negative one would collide
        // with the never-exchanged sentinel.
        h.timePort.advanceTimeOnly(const Duration(seconds: 10));
        final nowMs = h.timePort.nowMs;
        final (messages, sub) = h.captureMessages(peer);

        h.peerRegistry.updatePeerAntiEntropy(peer.id, nowMs - 799);
        await h.engine.performGossipRound();
        await h.flush(3);
        expect(
          messages,
          isEmpty,
          reason: 'an exchange 799 ms ago is inside the 800 ms window',
        );

        h.peerRegistry.updatePeerAntiEntropy(peer.id, nowMs - 800);
        await h.engine.performGossipRound();
        await h.flush(3);
        expect(
          messages.whereType<DigestRequest>(),
          hasLength(1),
          reason: 'an exchange exactly one window ago is stale',
        );

        await sub.cancel();
      },
    );

    test('a stale peer is still gossiped with', () async {
      final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 500));
      h.engine.start();

      // Exchange recorded far in the past relative to the interval.
      h.peerRegistry.updatePeerAntiEntropy(peer.id, h.timePort.nowMs - 60000);
      final (messages, sub) = h.captureMessages(peer);

      await h.engine.performGossipRound();
      await h.flush(3);

      expect(messages, isNotEmpty);
      await sub.cancel();
      h.engine.stop();
    });
  });
}
