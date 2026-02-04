import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/protocol/messages/digest_request.dart';
import 'package:gossip/src/protocol/messages/digest_response.dart';
import 'package:gossip/src/protocol/values/channel_digest.dart';
import 'package:test/test.dart';

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
  });
}
