import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/gossip_bluey.dart';

import '../fakes/fake_bluey_port.dart';
import '_adverse_link_harness.dart';
import '_coordinator_helpers.dart';

/// Scenario: the peer disconnects and reconnects (a NEW link) while a
/// chunked message is still mid-transmission on the old link. The
/// per-chunk `identical(handle)` re-check must abort the stale message
/// ("connection replaced mid-message") instead of writing its remaining
/// chunks into the new link's byte stream, the new link must survive the
/// abort untouched, and sync must complete on it.
void main() {
  test('a reconnect during an in-flight chunked send aborts the stale '
      'message and sync completes on the new link', () async {
    final network = FakeBlueyNetwork();
    final idA = NodeId('11111111-1111-1111-1111-111111111111');
    final idB = NodeId('22222222-2222-2222-2222-222222222222');
    final serviceUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');
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

    // Baseline: the first link syncs.
    await streamA.append(Uint8List.fromList([1]));
    await waitForEntryCount(b, channelId, streamId, 1);

    // Arm a one-shot hold: when A starts a frame spanning at least 3
    // chunks, pause its SECOND chunk mid-flight so we can supersede
    // the link underneath the in-flight message.
    final chunkHeld = Completer<void>();
    final release = Completer<void>();
    var armed = true;
    var holdThisChunk = false;
    a.port.sendGate = (target, data) async {
      if (!armed || target != idB) return;
      if (holdThisChunk) {
        armed = false;
        holdThisChunk = false;
        chunkHeld.complete();
        await release.future;
        return;
      }
      if (chunkStartsFrame(data) && declaredFrameLength(data) > 2 * chunkSize) {
        holdThisChunk = true;
      }
    };

    // Trigger a multi-chunk transfer and wait until it is mid-flight.
    final payload2 = Uint8List.fromList(List.filled(120, 0x51));
    await streamA.append(payload2);
    await chunkHeld.future;

    // Supersession: B drops the link and auto-connect brings up a NEW
    // one while A's drain loop is still parked inside the old message.
    await b.port.disconnect(idA);
    await waitFor(
      () async => !a.isLinkedTo(idB),
      what: 'old link to drop on A',
    );
    await waitFor(
      () async => a.isLinkedTo(idB) && b.isLinkedTo(idA),
      what: 'new link to come up during the in-flight send',
      timeout: const Duration(seconds: 10),
    );

    // Release the held chunk. The per-chunk handle re-check must now
    // abort the stale message rather than stream the rest of its
    // chunks into the new link.
    release.complete();
    await waitFor(
      () async => a.connectionErrors.any(
        (e) =>
            e is SendFailedError &&
            e.nodeId == idB &&
            e.message.contains('replaced mid-message'),
      ),
      what: 'stale send to abort with "replaced mid-message"',
    );

    // The abort punished only the stale message — the new link is
    // innocent and stays registered.
    expect(a.isLinkedTo(idB), isTrue);
    expect(a.registry.connectionCount, equals(1));

    // Sync completes on the new link: the entry whose delta was
    // aborted mid-flight converges via a later round, byte-for-byte,
    // with no corrupt entry ever ingested.
    await waitForEntryCount(b, channelId, streamId, 2);
    final entriesB = await b.entriesOf(channelId, streamId);
    expect(entriesB, hasLength(2));
    expect(
      entriesB.map((e) => e.payload.toList()),
      anyElement(equals(payload2.toList())),
    );

    await a.dispose();
    await b.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));
}
