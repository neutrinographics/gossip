import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'dart:typed_data';

import 'gossip_engine_test_harness.dart';

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
        'current interval', () async {
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
