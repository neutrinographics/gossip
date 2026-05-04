import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/gossip_bluey.dart';

import '../fakes/fake_bluey_port.dart';
import '_coordinator_helpers.dart';

void main() {
  test('three-node star: spokes converge through hub', () async {
    final network = FakeBlueyNetwork();
    final hubId = NodeId('99999999-9999-9999-9999-999999999999');
    final spokeAId = NodeId('11111111-1111-1111-1111-111111111111');
    final spokeBId = NodeId('22222222-2222-2222-2222-222222222222');
    final serviceUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');

    final hubPort = FakeBlueyPort(localNodeId: hubId, network: network);
    final aPort = FakeBlueyPort(localNodeId: spokeAId, network: network);
    final bPort = FakeBlueyPort(localNodeId: spokeBId, network: network);

    // Hub advertises only.
    final hub = BlueyTransport.testing(
      localNodeId: hubId,
      serviceUuid: serviceUuid,
      displayName: 'Hub',
      port: hubPort,
      maxConnections: 7,
    );
    // Spokes discover only, pinned to hub.
    final spokeA = BlueyTransport.testing(
      localNodeId: spokeAId,
      serviceUuid: serviceUuid,
      displayName: 'Spoke-A',
      port: aPort,
      maxConnections: 1,
      targetConnections: 1,
    );
    final spokeB = BlueyTransport.testing(
      localNodeId: spokeBId,
      serviceUuid: serviceUuid,
      displayName: 'Spoke-B',
      port: bPort,
      maxConnections: 1,
      targetConnections: 1,
    );

    final hubCoord = await spawnCoordinator(
      nodeId: hubId,
      messagePort: hub.messagePort,
    );
    final aCoord = await spawnCoordinator(
      nodeId: spokeAId,
      messagePort: spokeA.messagePort,
    );
    final bCoord = await spawnCoordinator(
      nodeId: spokeBId,
      messagePort: spokeB.messagePort,
    );

    // Start all coordinators (gossip rounds tick).
    await hubCoord.start();
    await aCoord.start();
    await bCoord.start();

    await hub.startAdvertising();
    // Note: spokes do NOT call startAdvertising.
    await spokeA.startDiscovery(filter: (id) => id == hubId);
    await spokeB.startDiscovery(filter: (id) => id == hubId);

    await spokeA.serviceForTest.runDiscoveryRoundForTest();
    await spokeB.serviceForTest.runDiscoveryRoundForTest();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(hub.connectedPeerCount, equals(2));
    expect(spokeA.connectedPeerCount, equals(1));
    expect(spokeB.connectedPeerCount, equals(1));

    // Gossip-level peer wiring: spokes only know hub; hub knows both.
    await aCoord.addPeer(hubId);
    await bCoord.addPeer(hubId);
    await hubCoord.addPeer(spokeAId);
    await hubCoord.addPeer(spokeBId);

    // Create a shared channel on all three.
    final channelId = ChannelId('star');
    final streamId = StreamId('msg');
    final hubChannel = await hubCoord.createChannel(channelId);
    final aChannel = await aCoord.createChannel(channelId);
    final bChannel = await bCoord.createChannel(channelId);

    // Channel-level membership: spokes add hub; hub adds both spokes.
    await aChannel.addMember(hubId);
    await bChannel.addMember(hubId);
    await hubChannel.addMember(spokeAId);
    await hubChannel.addMember(spokeBId);

    final aStream = await aChannel.getOrCreateStream(streamId);
    final bStream = await bChannel.getOrCreateStream(streamId);
    await hubChannel.getOrCreateStream(streamId);

    final payload = Uint8List.fromList([42, 43, 44]);
    await aStream.append(payload);

    await waitFor(
      () async {
        final entries = (await bStream.getAll()).cast<LogEntry>();
        return entries.length == 1;
      },
      what: 'entry from A to converge to B via hub',
      timeout: const Duration(seconds: 8),
    );

    final entriesOnB = (await bStream.getAll()).cast<LogEntry>();
    expect(entriesOnB.first.payload, equals(payload));

    await hub.dispose();
    await spokeA.dispose();
    await spokeB.dispose();
    await hubCoord.dispose();
    await aCoord.dispose();
    await bCoord.dispose();
  });
}
