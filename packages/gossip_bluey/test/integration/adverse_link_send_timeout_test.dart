import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/gossip_bluey.dart';

import '../fakes/fake_bluey_port.dart';
import '_adverse_link_harness.dart';
import '_coordinator_helpers.dart';

/// Scenario: one GATT write to a peer hangs forever (platform bug / dead
/// link the state watcher never noticed). The per-chunk send timeout
/// (ConnectionManager.sendTimeout) must fire, the send future must error
/// (surfacing as SendFailedError + a core PeerSyncError, never silence),
/// the peer's drain loop must move on instead of wedging, and once the
/// link recovers via auto-reconnect, sync must converge again.
void main() {
  test('a hung chunk write times out, unwedges the drain loop, and sync '
      'recovers after reconnect', () async {
    final network = FakeBlueyNetwork();
    final idA = NodeId('11111111-1111-1111-1111-111111111111');
    final idB = NodeId('22222222-2222-2222-2222-222222222222');
    final serviceUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');

    final a = await AdverseLinkNode.spawn(
      nodeId: idA,
      network: network,
      serviceUuid: serviceUuid,
      // Short per-chunk timeout so the test observes the unwedge fast;
      // production default is 30s.
      sendTimeout: const Duration(milliseconds: 400),
    );
    final b = await AdverseLinkNode.spawn(
      nodeId: idB,
      network: network,
      serviceUuid: serviceUuid,
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

    // Baseline: the healthy link syncs.
    await streamA.append(Uint8List.fromList([1, 2, 3]));
    await waitForEntryCount(b, channelId, streamId, 1);

    // Arm a one-shot hang: the next chunk A writes to B never
    // completes. Everything after it flows normally.
    final neverCompletes = Completer<void>();
    var armed = true;
    a.port.sendGate = (target, data) {
      if (armed && target == idB) {
        armed = false;
        return neverCompletes.future;
      }
      return Future<void>.value();
    };

    // The per-chunk timeout fires and surfaces as a SendFailedError
    // whose cause is the timeout — the send future error-completed
    // rather than hanging its awaiter (the gossip engine) forever.
    await waitFor(
      () async => a.connectionErrors.any(
        (e) =>
            e is SendFailedError &&
            e.nodeId == idB &&
            e.cause is TimeoutException,
      ),
      what: 'send timeout to surface as SendFailedError on A',
    );

    // The timed-out link is torn down and auto-connect re-establishes
    // it (per-NodeId reconnect goes through discovery again).
    await waitFor(
      () async => a.isLinkedTo(idB) && b.isLinkedTo(idA),
      what: 'link to recover after send-timeout teardown',
      timeout: const Duration(seconds: 10),
    );

    // Later messages to that peer still flow: the drain loop moved on
    // (a wedged loop would never write again) and sync converges on
    // the recovered link.
    final payload2 = Uint8List.fromList([4, 5, 6]);
    await streamA.append(payload2);
    await waitForEntryCount(b, channelId, streamId, 2);

    final entriesB = await b.entriesOf(channelId, streamId);
    expect(entriesB, hasLength(2));
    expect(
      entriesB.map((e) => e.payload.toList()),
      anyElement(equals([4, 5, 6])),
    );

    await a.dispose();
    await b.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));
}
