import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/gossip_bluey.dart';

import '../fakes/fake_bluey_port.dart';
import '_coordinator_helpers.dart';

void main() {
  test('two-node mesh converges on a shared channel', () async {
    final network = FakeBlueyNetwork();
    final idA = NodeId('11111111-1111-1111-1111-111111111111');
    final idB = NodeId('22222222-2222-2222-2222-222222222222');
    final serviceUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');

    final portA = FakeBlueyPort(localNodeId: idA, network: network);
    final portB = FakeBlueyPort(localNodeId: idB, network: network);

    final transportA = BlueyTransport.testing(
      localNodeId: idA,
      serviceUuid: serviceUuid,
      displayName: 'A',
      port: portA,
    );
    final transportB = BlueyTransport.testing(
      localNodeId: idB,
      serviceUuid: serviceUuid,
      displayName: 'B',
      port: portB,
    );

    final coordA = await spawnCoordinator(
      nodeId: idA,
      messagePort: transportA.messagePort,
    );
    final coordB = await spawnCoordinator(
      nodeId: idB,
      messagePort: transportB.messagePort,
    );

    // Mesh: both sides advertise + discover + auto-connect.
    transportA.setConnectionMode(ConnectionMode.auto);
    transportB.setConnectionMode(ConnectionMode.auto);
    await transportA.startAdvertising();
    await transportB.startAdvertising();
    await transportA.startDiscovery();
    await transportB.startDiscovery();

    // Trigger discovery on A (the lower NodeId, so it initiates).
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // Allow the connection event to propagate to both sides.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(transportA.connectedPeerCount, equals(1));
    expect(transportB.connectedPeerCount, equals(1));

    // Create a shared channel and stream on both nodes, with mutual membership.
    final channelId = ChannelId('demo');
    final streamId = StreamId('messages');

    final channelA = await coordA.createChannel(channelId);
    final channelB = await coordB.createChannel(channelId);
    final streamA = await channelA.getOrCreateStream(streamId);
    await channelB.getOrCreateStream(streamId);
    await channelA.addMember(idB);
    await channelB.addMember(idA);

    // Wire gossip-level peer membership.
    await coordA.addPeer(idB);
    await coordB.addPeer(idA);

    // Start gossip on both sides.
    await coordA.start();
    await coordB.start();

    // Append on A; expect convergence on B.
    final payload = Uint8List.fromList([1, 2, 3]);
    await streamA.append(payload);

    await waitFor(
      () async {
        final channel = coordB.getChannel(channelId);
        if (channel == null) return false;
        final stream = await channel.getOrCreateStream(streamId);
        final entries = (await stream.getAll()).cast<LogEntry>();
        return entries.length == 1;
      },
      what: 'entry to converge to B',
      timeout: const Duration(seconds: 10),
    );

    final streamB = await coordB
        .getChannel(channelId)!
        .getOrCreateStream(streamId);
    final entriesB = (await streamB.getAll()).cast<LogEntry>();
    expect(entriesB.first.payload, equals(payload));

    await coordA.dispose();
    await coordB.dispose();
    await transportA.dispose();
    await transportB.dispose();
  });
}
