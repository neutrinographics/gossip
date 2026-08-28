import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:test/test.dart';

import 'gossip_engine_test_harness.dart';

void main() {
  GossipEngineTestHarness makeHarness() =>
      GossipEngineTestHarness(gossipInterval: const Duration(seconds: 100));

  group('GossipEngine.syncWithPeer', () {
    test('sends a DigestRequest to the target immediately', () async {
      final h = makeHarness();
      final peer = h.addPeer('peer1');
      h.createChannel('ch1', streamIds: ['s1']);
      h.startListening();
      h.engine.start();
      final (messages, sub) = h.captureMessages(peer);

      await h.engine.syncWithPeer(peer.id);
      await h.flush();

      expect(
        messages.whereType<DigestRequest>().length,
        equals(1),
        reason:
            'a newly connected peer should be synced immediately, not after '
            'the random periodic round happens to select it',
      );

      await sub.cancel();
      h.engine.stop();
      h.stopListening();
    });

    test('is a no-op when the engine is not running', () async {
      final h = makeHarness();
      final peer = h.addPeer('peer1');
      h.createChannel('ch1', streamIds: ['s1']);
      h.startListening(); // not started

      final (messages, sub) = h.captureMessages(peer);

      await h.engine.syncWithPeer(peer.id);
      await h.flush();

      expect(messages.whereType<DigestRequest>(), isEmpty);

      await sub.cancel();
      h.stopListening();
    });
  });
}
