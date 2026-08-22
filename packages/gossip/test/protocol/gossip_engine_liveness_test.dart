import 'package:gossip/src/membership/domain/events/membership_events.dart'
    show PeerStatus;
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/protocol/messages/digest_request.dart';
import 'package:gossip/src/protocol/values/channel_digest.dart';
import 'package:test/test.dart';

import 'gossip_engine_test_harness.dart';

void main() {
  group('GossipEngine feeds SWIM liveness (M2)', () {
    test(
      'receiving a gossip message from a suspected peer recovers it and '
      'resets its failed-probe count',
      () async {
        final h = GossipEngineTestHarness();
        final peer = h.addPeer('peer1');
        h.createChannel('ch1', streamIds: ['s1']);
        h.startListening();

        // Simulate SWIM having driven the peer toward failure (e.g. pings
        // starved behind gossip on BLE) even though the peer is alive.
        h.peerRegistry.incrementFailedProbeCount(peer.id);
        h.peerRegistry.incrementFailedProbeCount(peer.id);
        h.peerRegistry.updatePeerStatus(
          peer.id,
          PeerStatus.suspected,
          occurredAt: DateTime.now(),
        );
        expect(
          h.peerRegistry.getPeer(peer.id)!.status,
          equals(PeerStatus.suspected),
        );

        // The peer sends a gossip message — unambiguous proof of life.
        await peer.port.send(
          h.localNode,
          h.codec.encode(
            DigestRequest(
              sender: peer.id,
              digests: [ChannelDigest(channelId: ChannelId('ch1'), streams: [])],
            ),
          ),
        );
        await h.flush();

        final recovered = h.peerRegistry.getPeer(peer.id)!;
        expect(
          recovered.status,
          equals(PeerStatus.reachable),
          reason:
              'an actively-syncing peer must not stay suspected — gossip '
              'receipt is proof of life',
        );
        expect(recovered.failedProbeCount, equals(0));

        h.stopListening();
      },
    );

    test('a gossip message from an unknown peer is a harmless no-op', () async {
      final h = GossipEngineTestHarness();
      final peer = h.addPeer('peer1');
      h.createChannel('ch1', streamIds: ['s1']);
      h.startListening();

      // Not added to the registry — updatePeerContact must no-op, not throw.
      final ghost = h.addPeer('ghost');
      h.peerRegistry.removePeer(ghost.id, occurredAt: DateTime.now());

      await ghost.port.send(
        h.localNode,
        h.codec.encode(
          DigestRequest(
            sender: ghost.id,
            digests: [ChannelDigest(channelId: ChannelId('ch1'), streams: [])],
          ),
        ),
      );
      await h.flush();

      expect(h.peerRegistry.getPeer(ghost.id), isNull);
      // The known peer is untouched.
      expect(h.peerRegistry.getPeer(peer.id)!.status, PeerStatus.reachable);

      h.stopListening();
    });
  });
}
