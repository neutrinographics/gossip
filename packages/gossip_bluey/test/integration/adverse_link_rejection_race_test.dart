import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/gossip_bluey.dart';

import '../fakes/fake_bluey_port.dart';
import '_adverse_link_harness.dart';
import '_coordinator_helpers.dart';

/// WIRE4-9: on real hardware the GSP2 capacity-rejection frame is sent the
/// moment the peripheral identifies the inbound central (first lifecycle
/// heartbeat) — which is BEFORE that central has finished service discovery
/// and subscribed to notifications. The frame lands in an unsubscribed
/// characteristic and is lost without error; the rejected central never
/// learns, keeps its link open, and every byte it gossips into the full
/// peer is silently discarded, forever.
///
/// This test models that race with the fake's `notificationSubscribeDelay`
/// and requires the fix: the rejection must be re-sent (bounded, paced)
/// while the rejected peer keeps writing, so one re-send lands after the
/// subscribe and the peer still closes its own link.
void main() {
  const serviceUuid = 'f0000000-0000-0000-0000-000000000000';
  final channelId = ChannelId('demo');
  final streamId = StreamId('messages');

  test(
      'a rejection frame lost to the subscribe race is re-sent; the '
      'rejected central still learns and closes its own link', () async {
    final network = FakeBlueyNetwork();
    final serviceUuidVo = ServiceUuid(serviceUuid);

    Future<AdverseLinkNode> spawn(String id, {int? maxConnections}) =>
        AdverseLinkNode.spawn(
          nodeId: NodeId(id),
          network: network,
          serviceUuid: serviceUuidVo,
          maxConnections: maxConnections,
        );

    final hub = await spawn('hub-node', maxConnections: 1);
    final first = await spawn('peer-one');
    final newcomer = await spawn('peer-two');
    addTearDown(() async {
      await hub.dispose();
      await first.dispose();
      await newcomer.dispose();
    });

    // The race: the newcomer's notification subscribe lands well after
    // the hub already sees (and rejects) the inbound link.
    newcomer.port.notificationSubscribeDelay =
        const Duration(milliseconds: 300);

    // Gossip wiring so the newcomer keeps WRITING into the full hub —
    // those writes are what must trigger the bounded re-send.
    await hub.joinChannel(
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

    await hub.start(advertise: true, discover: false);

    await first.connectToPeer(hub.nodeId);
    await waitFor(
      () async => hub.port.physicalLinkCountTo(first.nodeId) == 1,
      timeout: const Duration(seconds: 5),
      what: "first fills the hub's only slot",
    );

    // Deliberately NO discovery/auto-connect on the newcomer: a policy
    // retry would fire a fresh connect and with it a fresh rejection,
    // masking the single-shot race this test pins. One connection, one
    // (lost) rejection frame — the pure WIRE4-9 shape.
    await newcomer.connectToPeer(hub.nodeId).then((_) {}, onError: (_) {});

    // The rejected central must still end up closing its own link, even
    // though the initial frame was provably lost to the subscribe race.
    await waitFor(
      () async => newcomer.port.physicalLinkCountTo(hub.nodeId) == 0,
      timeout: const Duration(seconds: 10),
      what: 'a re-sent rejection must reach the central after it subscribes',
    );

    // Honesty guard: this test only means something if the FIRST frame
    // really was swallowed by the race.
    expect(hub.port.preSubscribeDrops[newcomer.nodeId], greaterThanOrEqualTo(1),
        reason: 'the initial rejection frame must have been lost '
            'pre-subscribe for this test to exercise WIRE4-9');
  });
}
