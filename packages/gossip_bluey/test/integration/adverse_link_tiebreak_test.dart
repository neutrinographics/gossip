import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/gossip_bluey.dart';

import '../fakes/fake_bluey_port.dart';
import '_adverse_link_harness.dart';
import '_coordinator_helpers.dart';

/// End-to-end proof (COR3-29) that a SIMULTANEOUS mutual connect between
/// one pair converges to EXACTLY ONE physical BLE link, driven through the
/// full stack: a real core [Coordinator] over `BlueyMessagePort` over
/// `ConnectionManager` over [FakeBlueyPort].
///
/// The fake models central- and peripheral-role links as independent sets,
/// so two opposite-direction connects between the same pair coexist as two
/// physical links (`physicalLinkCountTo == 2`) exactly as they would on real
/// hardware. The ConnectionManager tie-break (Task 3) must shed one of them.
void main() {
  const serviceUuid = 'f0000000-0000-0000-0000-000000000000';
  final channelId = ChannelId('demo');
  final streamId = StreamId('messages');

  // node-aaa < node-zzz lexicographically, so the tie-break direction is
  // unambiguous: the surviving link's central is node-aaa.
  final idA = NodeId('node-aaa');
  final idB = NodeId('node-zzz');

  Future<(AdverseLinkNode, AdverseLinkNode)> spawnPair() async {
    final network = FakeBlueyNetwork();
    final a = await AdverseLinkNode.spawn(
      nodeId: idA,
      network: network,
      serviceUuid: ServiceUuid(serviceUuid),
    );
    final b = await AdverseLinkNode.spawn(
      nodeId: idB,
      network: network,
      serviceUuid: ServiceUuid(serviceUuid),
    );
    return (a, b);
  }

  /// Sets up the shared channel + gossip peering on both nodes, starts
  /// gossip, and returns A's local stream handle for appends.
  Future<EventStream> startGossip(AdverseLinkNode a, AdverseLinkNode b) async {
    final streamA = await a.joinChannel(
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
    return streamA;
  }

  test(
      'simultaneous mutual connect converges to exactly one physical link, '
      'with the smaller NodeId as central, and gossip still syncs', () async {
    final (a, b) = await spawnPair();
    addTearDown(() async {
      await a.dispose();
      await b.dispose();
    });

    // Drive BOTH connects concurrently to force the mutual-connect race:
    // A ends holding a central AND a peripheral link to B, and vice versa.
    await Future.wait([
      a.connectToPeer(b.nodeId),
      b.connectToPeer(a.nodeId),
    ]);

    // Let the tie-break + physical role-close settle to exactly one link.
    await waitFor(
      () async =>
          a.port.physicalLinkCountTo(b.nodeId) == 1 &&
          b.port.physicalLinkCountTo(a.nodeId) == 1,
      timeout: const Duration(seconds: 5),
      what: 'pair converges to exactly ONE physical link',
    );

    // The surviving link's central is the smaller NodeId (node-aaa).
    expect(a.port.connectedAsCentral.contains(b.nodeId), isTrue,
        reason: 'node-aaa < node-zzz: aaa must be the central');
    expect(b.port.connectedAsCentral.contains(a.nodeId), isFalse,
        reason: 'node-zzz lost the tie-break; its central must be closed');

    // And the surviving link carries real gossip: write on A, read on B.
    final streamA = await startGossip(a, b);
    await streamA.append(Uint8List.fromList([1, 2, 3]));
    await waitForEntryCount(b, channelId, streamId, 1,
        timeout: const Duration(seconds: 10));
  });

  test(
      'mutual connect converges regardless of which link registers first on '
      'each side (staggered race)', () async {
    final (a, b) = await spawnPair();
    addTearDown(() async {
      await a.dispose();
      await b.dispose();
    });

    // Stagger: A initiates first, B initiates while A's connect is
    // resolving — exercises the arrival-order cases the unit tests cover in
    // isolation, through the whole stack.
    final first = a.connectToPeer(b.nodeId);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final second = b.connectToPeer(a.nodeId);
    await Future.wait([first, second]);

    await waitFor(
      () async =>
          a.port.physicalLinkCountTo(b.nodeId) == 1 &&
          b.port.physicalLinkCountTo(a.nodeId) == 1,
      timeout: const Duration(seconds: 5),
      what: 'staggered pair converges to exactly ONE physical link',
    );

    expect(a.port.connectedAsCentral.contains(b.nodeId), isTrue,
        reason: 'node-aaa < node-zzz: aaa must be the central');
    expect(b.port.connectedAsCentral.contains(a.nodeId), isFalse);

    final streamA = await startGossip(a, b);
    await streamA.append(Uint8List.fromList([9]));
    await waitForEntryCount(b, channelId, streamId, 1,
        timeout: const Duration(seconds: 10));
  });
}
