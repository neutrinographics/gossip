import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
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

      expect(h.engine.effectiveGossipInterval,
          greaterThan(const Duration(seconds: 1)));
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
      expect(h.engine.effectiveGossipInterval,
          greaterThan(const Duration(seconds: 1)));

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
  });
}
