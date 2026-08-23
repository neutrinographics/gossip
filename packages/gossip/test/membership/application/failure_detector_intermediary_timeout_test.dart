import 'package:gossip/src/membership/domain/messages/ack.dart';
import 'package:gossip/src/membership/domain/messages/ping.dart';
import 'package:test/test.dart';

import 'failure_detector_test_harness.dart';

/// M6: an intermediary probing a target on a requester's behalf must use an
/// adaptive per-target timeout, not a fixed 500ms. On BLE a target's RTT can
/// exceed 500ms, so the fixed timeout made the intermediary abandon the relay
/// before the target answered — wasting the whole indirect phase.
void main() {
  group('FailureDetector intermediary probe timeout (M6)', () {
    test('a slow target that answers after 500ms is still relayed (adaptive '
        'intermediary timeout, not a fixed 500ms)', () async {
      // Adaptive timing (no static pingTimeout).
      final h = FailureDetectorTestHarness();
      final requester = h.addPeer('requester');
      final target = h.addPeer('target');

      // Seed the intermediary's RTT estimate for the target so its adaptive
      // ping timeout is ~900ms (300ms + 4*150ms), comfortably past 600ms.
      h.peerRegistry.recordPeerRtt(
        target.id,
        const Duration(milliseconds: 300),
      );

      h.startListening();

      // The target answers the intermediary's Ping 600ms later — past the
      // old fixed 500ms, but within the adaptive timeout.
      target.port.incoming.listen((msg) {
        final decoded = h.codec.decode(msg.bytes);
        if (decoded is Ping) {
          h.timePort.delay(const Duration(milliseconds: 600)).then((_) {
            target.port.send(
              h.localNode,
              h.codec.encode(
                Ack(sender: target.id, sequence: decoded.sequence),
              ),
            );
          });
        }
      });

      // Capture the forwarded Ack the intermediary should send back.
      final forwarded = <Ack>[];
      final reqSub = requester.port.incoming.listen((msg) {
        final decoded = h.codec.decode(msg.bytes);
        if (decoded is Ack) forwarded.add(decoded);
      });

      // Requester asks the local node to probe the target on its behalf.
      await h.sendPingReq(requester, target, sequence: 42);

      // Advance to 600ms: the target's Ack fires; the adaptive ~900ms
      // timeout has NOT. The old fixed 500ms would already have expired.
      await h.timePort.advance(const Duration(milliseconds: 600));
      await h.flush(3);

      expect(
        forwarded.map((a) => a.sequence),
        contains(42),
        reason:
            'the intermediary must wait its adaptive per-target timeout and '
            'relay the late Ack, not give up at a fixed 500ms',
      );

      await reqSub.cancel();
      h.stopListening();
    });
  });
}
