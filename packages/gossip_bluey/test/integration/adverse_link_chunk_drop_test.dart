import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/gossip_bluey.dart';

import '../fakes/fake_bluey_port.dart';
import '_adverse_link_harness.dart';
import '_coordinator_helpers.dart';

/// Scenario: a multi-chunk gossip message silently loses one chunk on the
/// wire (a write-without-response that was never delivered). The receiver's
/// byte stream is misaligned mid-frame; the stack must surface the
/// corruption (frame-decoder recovery metrics and/or a `messageCorrupted`
/// sync error) instead of staying silent, must never ingest a corrupt
/// entry, and a later anti-entropy round must still converge the data.
void main() {
  test(
    'a silently dropped chunk surfaces as corruption and sync still converges',
    () async {
      final network = FakeBlueyNetwork();
      final idA = NodeId('11111111-1111-1111-1111-111111111111');
      final idB = NodeId('22222222-2222-2222-2222-222222222222');
      final serviceUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');
      // Small chunks so every gossip message spans several writes.
      const chunkSize = 24;

      final a = await AdverseLinkNode.spawn(
        nodeId: idA,
        network: network,
        serviceUuid: serviceUuid,
        chunkSize: chunkSize,
      );
      final b = await AdverseLinkNode.spawn(
        nodeId: idB,
        network: network,
        serviceUuid: serviceUuid,
        chunkSize: chunkSize,
      );

      await a.start();
      await b.start();
      await waitFor(
        () async => a.isLinkedTo(idB) && b.isLinkedTo(idA),
        what: 'mesh link up',
      );

      final channelId = ChannelId('demo');
      final streamId = StreamId('messages');
      final streamA = await a.joinChannel(
        channelId: channelId,
        streamId: streamId,
        peers: [idB],
      );
      await b.joinChannel(
        channelId: channelId,
        streamId: streamId,
        peers: [idA],
      );
      await a.coordinator.start();
      await b.coordinator.start();

      // Arm a one-shot fault: silently drop the chunk FOLLOWING the next
      // full-sized header chunk A writes to B — i.e. a chunk from the
      // middle (or tail) of a multi-chunk frame. The sender sees success
      // (writes-without-response have no ACK), so the failure can only
      // surface on the receiving side.
      var armed = true;
      var dropNext = false;
      a.port.chunkDropInjector = (target, data) {
        if (!armed || target != idB) return false;
        if (dropNext) {
          armed = false;
          dropNext = false;
          return true;
        }
        // A full header chunk means more chunks of this frame follow.
        if (chunkStartsFrame(data) && data.length == chunkSize) {
          dropNext = true;
        }
        return false;
      };

      final payload = Uint8List.fromList(List.filled(100, 0x42));
      await streamA.append(payload);

      // The fault fired: the injector disarmed itself.
      await waitFor(() async => !armed, what: 'chunk drop to fire');

      // The failure surfaces on the receiver — either the frame decoder
      // reports a corruption recovery (bytes discarded while re-seeking
      // the magic) or the mis-assembled frame reaches the protocol codec
      // and is emitted as a messageCorrupted sync error. Silence is a bug.
      await waitFor(
        () async =>
            b.metrics.frameRecoveries > 0 ||
            b.syncErrors.any(
              (e) =>
                  e is PeerSyncError &&
                  e.type == SyncErrorType.messageCorrupted,
            ),
        what: 'corruption to surface on B',
      );

      // Despite the loss, a later gossip round converges the entry.
      await waitForEntryCount(b, channelId, streamId, 1);

      // The receiver never assembled a corrupt message into data: B holds
      // exactly the entry A appended, byte-for-byte.
      final entriesB = await b.entriesOf(channelId, streamId);
      expect(entriesB, hasLength(1));
      expect(entriesB.single.payload, equals(payload));
      expect(entriesB.single.author, equals(idA));

      await a.dispose();
      await b.dispose();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
