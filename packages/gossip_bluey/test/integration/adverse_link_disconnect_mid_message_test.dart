import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/gossip_bluey.dart';

import '../fakes/fake_bluey_port.dart';
import '_adverse_link_harness.dart';
import '_coordinator_helpers.dart';

/// Scenario: the link drops partway through a chunked transfer. The
/// sender must abort the rest of the message (surfacing a
/// SendFailedError, never writing stale chunks), the receiver's partial
/// frame must die with the link's decoder (no misalignment carried into
/// the reconnected link), and anti-entropy must converge the lost entry
/// once auto-connect re-establishes the link.
void main() {
  test('a disconnect mid-chunked-message tears down cleanly and sync '
      'converges after reconnect', () async {
    final network = FakeBlueyNetwork();
    final idA = NodeId('11111111-1111-1111-1111-111111111111');
    final idB = NodeId('22222222-2222-2222-2222-222222222222');
    final serviceUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');
    // Small chunks so the delta carrying the appended entry spans
    // several writes.
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
    await b.joinChannel(channelId: channelId, streamId: streamId, peers: [idA]);
    await a.coordinator.start();
    await b.coordinator.start();

    // Arm a one-shot fault: when A starts writing a frame that spans
    // at least 3 chunks, drop the link just before chunk 2 goes out.
    // B is left holding a partial frame; A is left mid-message.
    var armed = true;
    var disconnectBeforeThisChunk = false;
    a.port.sendGate = (target, data) async {
      if (!armed || target != idB) return;
      if (disconnectBeforeThisChunk) {
        armed = false;
        disconnectBeforeThisChunk = false;
        await a.port.disconnect(idB);
        return;
      }
      if (chunkStartsFrame(data) && declaredFrameLength(data) > 2 * chunkSize) {
        disconnectBeforeThisChunk = true;
      }
    };

    // Trigger a multi-chunk transfer (entry payload + gossip envelope
    // is far larger than one 24-byte chunk).
    final payload = Uint8List.fromList(List.filled(100, 0x37));
    await streamA.append(payload);

    await waitFor(() async => !armed, what: 'mid-message disconnect');

    // The aborted send surfaces on A — the message's remaining chunks
    // were never written and its future error-completed.
    await waitFor(
      () async => a.connectionErrors.any(
        (e) => e is SendFailedError && e.nodeId == idB,
      ),
      what: 'aborted mid-message send to surface on A',
    );

    // Auto-connect re-establishes the link.
    await waitFor(
      () async => a.isLinkedTo(idB) && b.isLinkedTo(idA),
      what: 'link to recover after mid-message disconnect',
      timeout: const Duration(seconds: 10),
    );

    // The entry lost mid-transfer converges on the fresh link.
    await waitForEntryCount(b, channelId, streamId, 1);
    final entriesB = await b.entriesOf(channelId, streamId);
    expect(entriesB, hasLength(1));
    expect(entriesB.single.payload, equals(payload));

    // No partial-frame corruption leaked across the reconnect: B's
    // decoder was discarded with the dead link and the fresh one never
    // had to re-align (zero recovery events), nor did a mangled frame
    // ever reach B's protocol codec.
    expect(b.metrics.frameRecoveries, equals(0));
    expect(
      b.syncErrors.whereType<PeerSyncError>().where(
        (e) => e.type == SyncErrorType.messageCorrupted,
      ),
      isEmpty,
    );

    await a.dispose();
    await b.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));
}
