import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/gossip_bluey.dart';
import 'package:gossip_bluey/src/protocol/control_frame_codec.dart';

import '../fakes/fake_bluey_port.dart';
import '_adverse_link_harness.dart';
import '_coordinator_helpers.dart';

/// End-to-end proof (COR3-21) of the GSP2 capacity-rejection protocol,
/// driven through the whole stack (real core [Coordinator] over
/// `BlueyMessagePort` over `ConnectionManager` over [FakeBlueyPort]):
///
///  1. a newcomer rejected at a full peer closes its OWN central link
///     (the rejecting peripheral cannot — see the fake's `disconnectRole`),
///     backs off instead of hot-looping at scan cadence, and finally
///     connects + syncs once a slot frees;
///  2. a GSP2 rejection frame arriving at a receiver that does not
///     dispatch it (a peripheral-role link — Task 5's role guard, which is
///     exactly how a legacy GSP1-only node behaves) is discarded
///     harmlessly and does not poison the following GSP1 data stream.
void main() {
  const serviceUuid = 'f0000000-0000-0000-0000-000000000000';
  final channelId = ChannelId('demo');
  final streamId = StreamId('messages');

  test(
      'a newcomer rejected at capacity closes its link, backs off, and '
      'syncs after a slot frees', () async {
    final network = FakeBlueyNetwork();
    final serviceUuidVo = ServiceUuid(serviceUuid);

    Future<AdverseLinkNode> spawn(String id, {int? maxConnections}) =>
        AdverseLinkNode.spawn(
          nodeId: NodeId(id),
          network: network,
          serviceUuid: serviceUuidVo,
          maxConnections: maxConnections,
        );

    // Hub capped at 1 connection; `first` fills the slot. NodeId values
    // are >= 8 chars because the harness derives a display name from
    // `nodeId.value.substring(0, 8)`.
    final hub = await spawn('hub-node', maxConnections: 1);
    final first = await spawn('peer-one');
    final newcomer = await spawn('peer-two');
    addTearDown(() async {
      await hub.dispose();
      await first.dispose();
      await newcomer.dispose();
    });

    // Gossip wiring: hub <-> newcomer are mutual peers/members. `first` is
    // NOT wired into the channel — it is purely a slot-filler, so it can
    // never leak the recovery entry to the newcomer out-of-band.
    final hubStream = await hub.joinChannel(
      channelId: channelId,
      streamId: streamId,
      peers: [newcomer.nodeId],
    );
    await newcomer.joinChannel(
      channelId: channelId,
      streamId: streamId,
      peers: [hub.nodeId],
    );
    await hub.coordinator.start();
    await newcomer.coordinator.start();

    // Hub advertises only (star peripheral). `first` fills the one slot via
    // a DIRECT connect and never discovers, so it cannot auto-reconnect and
    // re-steal the freed slot. The newcomer discovers + auto-connects so its
    // BACKED-OFF retry is what recovers once the slot frees.
    await hub.start(advertise: true, discover: false);

    await first.connectToPeer(hub.nodeId);
    await waitFor(
      () async => hub.port.physicalLinkCountTo(first.nodeId) == 1,
      timeout: const Duration(seconds: 5),
      what: "first fills the hub's only slot",
    );

    await newcomer.start(advertise: false, discover: true);

    // Newcomer dials the full hub — must end NOT connected, with its own
    // physical (central) link closed after the rejection frame. The
    // rejecting hub, being the peripheral, cannot close it; only the
    // GSP2 frame makes the newcomer close its own link.
    await newcomer.connectToPeer(hub.nodeId).then((_) {}, onError: (_) {});
    await waitFor(
      () async => newcomer.port.physicalLinkCountTo(hub.nodeId) == 0,
      timeout: const Duration(seconds: 5),
      what: 'rejected central must close its own link',
    );

    // Backoff: over the next second of continuous scanning (the fake
    // rebroadcasts candidates every 100ms — an unbacked-off policy would
    // attempt ~10 times), connect attempts to the hub must stay bounded.
    final attemptsBefore = newcomer.port.connectAndIdentifyCallCount;
    await Future<void>.delayed(const Duration(seconds: 1));
    final attemptsDuring =
        newcomer.port.connectAndIdentifyCallCount - attemptsBefore;
    expect(attemptsDuring, lessThanOrEqualTo(1),
        reason: 'exponential backoff must pace retries');

    // Free the slot; the newcomer's next backed-off retry must connect and
    // sync the entry written after the slot freed.
    await hub.disconnectFrom(first.nodeId);
    await hubStream.append(Uint8List.fromList([7, 7]));
    await waitForEntryCount(
      newcomer,
      channelId,
      streamId,
      1,
      timeout: const Duration(seconds: 15),
      what: 'after a slot frees, a backed-off retry must connect and sync',
    );
  });

  test(
      'a rejection frame sent to a receiver that does not understand GSP2 '
      'is skipped harmlessly and later data still decodes', () async {
    final network = FakeBlueyNetwork();
    final serviceUuidVo = ServiceUuid(serviceUuid);

    // node-aaa < node-zzz, so aaa is the central on the link it initiates.
    final a = await AdverseLinkNode.spawn(
      nodeId: NodeId('node-aaa'),
      network: network,
      serviceUuid: serviceUuidVo,
    );
    final b = await AdverseLinkNode.spawn(
      nodeId: NodeId('node-zzz'),
      network: network,
      serviceUuid: serviceUuidVo,
    );
    addTearDown(() async {
      await a.dispose();
      await b.dispose();
    });

    final aStream = await a.joinChannel(
      channelId: channelId,
      streamId: streamId,
      peers: [b.nodeId],
    );
    await b.joinChannel(
      channelId: channelId,
      streamId: streamId,
      peers: [a.nodeId],
    );
    await a.coordinator.start();
    await b.coordinator.start();

    await a.connectToPeer(b.nodeId);
    await waitFor(
      () async => b.port.physicalLinkCountTo(a.nodeId) == 1,
      timeout: const Duration(seconds: 5),
      what: 'a→b link established',
    );

    // b is the PERIPHERAL on this link (a initiated) — b's receive path
    // treats GSP2 as garbage by role guard, exactly like a legacy GSP1-only
    // node. Feed a GSP2 rejection frame into b's inbound path from a.
    b.port.emitPeerData(
      a.nodeId,
      ControlFrameCodec.encodeRejection(RejectionReason.capacity),
    );

    // The GSP2 residue must not poison the GSP1 stream: a real gossip entry
    // written afterward must still converge to b, and the link must survive.
    await aStream.append(Uint8List.fromList([4, 2]));
    await waitForEntryCount(
      b,
      channelId,
      streamId,
      1,
      timeout: const Duration(seconds: 10),
      what: 'GSP2 residue must not poison the GSP1 stream',
    );
    expect(b.port.physicalLinkCountTo(a.nodeId), 1,
        reason: 'link must survive the unknown frame');
  });
}
