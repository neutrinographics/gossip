// Task 3 (bounded-contexts restructure): engines now take their context's
// codec by injection instead of constructing a composite codec covering both
// message families inline. This pins the resulting cross-context behavior: a
// frame from the OTHER context's message family decodes to null (per-context
// `MessageCodec` answers "not mine") and must be silently ignored — no thrown
// error, no reply sent, no state mutated. Before the split, the composite
// codec decoded every frame regardless of family and the engine's
// message-type dispatch simply had no matching branch; this test is the
// regression proof that the new null-check-and-return preserves that "ignore
// what isn't mine" behavior.
import 'package:gossip/src/membership/infrastructure/membership_message_codec.dart';
import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:gossip/src/membership/domain/messages/ping.dart';
import 'package:gossip/src/sync/infrastructure/sync_message_codec.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_version.dart';
import 'package:test/test.dart';

import '../../membership/application/failure_detector_test_harness.dart';
import 'gossip_engine_test_harness.dart';

void main() {
  group('GossipEngine ignores foreign-family (membership) frames', () {
    test(
      'a Ping frame delivered to the engine is ignored without error or reply',
      () async {
        final h = GossipEngineTestHarness();
        final peer = h.addPeer('someone');
        h.startListening();
        final (messages, sub) = h.captureMessages(peer);

        final ping = Ping(sender: peer.id, sequence: 1);
        final bytes = MembershipMessageCodec(
          wireVersion: WireVersion.v2,
        ).encode(ping);
        await peer.port.send(h.localNode, bytes);
        await h.flush(3);

        expect(
          h.errors,
          isEmpty,
          reason: 'a foreign-family frame is routine traffic, not an error',
        );
        expect(
          messages,
          isEmpty,
          reason: 'the engine must not reply to a message it does not own',
        );
        expect(h.mergedEntries, isEmpty);

        await sub.cancel();
        await h.dispose();
      },
    );
  });

  group('FailureDetector ignores foreign-family (sync) frames', () {
    test('a DigestRequest frame delivered to the detector is ignored without '
        'error or reply', () async {
      final h = FailureDetectorTestHarness();
      final peer = h.addSilentPeer('someone');
      h.startListening();
      final (messages, sub) = h.captureMessages(peer);

      final digestRequest = DigestRequest(sender: peer.id, digests: const []);
      // v1 (unprefixed): FailureDetector's codec (MembershipMessageCodec)
      // doesn't parse the v2 marker yet — that's separate receiver-side
      // work — so this probes its existing sibling-family detection with
      // the frame shape it already handles.
      final bytes = SyncMessageCodec(
        wireVersion: WireVersion.v1,
      ).encode(digestRequest);
      await peer.port.send(h.localNode, bytes);
      await h.flush(3);

      expect(
        h.errors,
        isEmpty,
        reason: 'a foreign-family frame is routine traffic, not an error',
      );
      expect(
        messages,
        isEmpty,
        reason: 'the detector must not reply to a message it does not own',
      );

      await sub.cancel();
      await h.dispose();
    });
  });
}
