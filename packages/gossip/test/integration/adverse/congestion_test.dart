import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/facade/coordinator_config.dart';

import '../../support/test_network.dart';

/// Mirrors `GossipEngine._perPeerCongestionThreshold`: peers with more than
/// this many pending sends are excluded from gossip peer selection, and the
/// round is skipped entirely when every reachable peer exceeds it.
const congestionThreshold = 3;

/// Fixed timing so congestion arithmetic is deterministic:
/// - `gossipInterval` matches `runRounds`' default 1000ms advance, so each
///   round advances the engine roughly one gossip round.
/// - `probeInterval` is pushed far beyond the test horizon so SWIM sends no
///   pings (which would inflate the held-message counts) and cannot
///   reclassify the peer while the link is saturated — these tests isolate
///   the congestion gate, not suspicion.
const config = CoordinatorConfig(
  gossipInterval: Duration(seconds: 1),
  probeInterval: Duration(hours: 1),
);

void main() {
  group('Sustained Congestion', () {
    late TestNetwork network;
    final channelId = ChannelId('congestion-channel');
    final streamId = StreamId('data');

    setUp(() async {
      network = await TestNetwork.create(['node1', 'node2'], config: config);
      await network.connect('node1', 'node2');
      await network.setupChannel(channelId, streamId);
      await network.startAll();
    });

    tearDown(() async {
      await network.dispose();
    });

    test('gossip rounds are skipped while real queued sends exceed the '
        'congestion threshold', () async {
      // Baseline: healthy link, both nodes converge.
      await network['node1'].write(channelId, streamId, [1]);
      await network.runRounds(5);
      expect(await network.hasConverged(channelId, streamId), isTrue);

      // Saturate the link: hold both directions so every digest request the
      // engine sends stays queued as a REAL pending send (no simulated
      // counts anywhere in this file).
      network.delayLink('node1', 'node2');
      network.delayLink('node2', 'node1');
      await network.runRounds(10);

      // The engine sends while pendingSendCount <= threshold and stops after
      // the send that crossed it, so exactly threshold + 1 digest requests
      // ever queue on the link.
      final saturated = network.inFlightCount('node1', 'node2');
      expect(
        saturated,
        equals(congestionThreshold + 1),
        reason:
            'sends are allowed at pending 0..$congestionThreshold, then the '
            'peer is congested and rounds skip',
      );

      // The backpressure signal is emergent: pendingSendCount IS the held
      // queue on the link.
      expect(
        network['node1'].messagePort.pendingSendCount(network['node2'].id),
        equals(saturated),
      );

      // Sustained congestion: many more rounds fire and every one of them is
      // skipped — the queue would grow by one digest per round otherwise.
      await network.runRounds(10);
      expect(
        network.inFlightCount('node1', 'node2'),
        equals(saturated),
        reason: 'a growing queue would mean rounds were NOT skipped',
      );

      // Both engines gate independently on their own outgoing queue.
      expect(
        network.inFlightCount('node2', 'node1'),
        equals(congestionThreshold + 1),
      );

      // Releasing the link drains the queue and anti-entropy resumes.
      network.undelayLink('node1', 'node2');
      network.undelayLink('node2', 'node1');
      await network.runRounds(10);
      expect(network.inFlightCount('node1', 'node2'), equals(0));
      expect(await network.hasConverged(channelId, streamId), isTrue);
    });

    test('draining the backlog reopens the congestion gate', () async {
      // Saturate both directions until the gate closes.
      network.delayLink('node1', 'node2');
      network.delayLink('node2', 'node1');
      await network.runRounds(10);
      expect(
        network.inFlightCount('node1', 'node2'),
        greaterThan(congestionThreshold),
      );

      // Deliver the backlog while keeping the link delayed. The queue —
      // and with it pendingSendCount — drops to zero immediately.
      network.releaseInFlight();
      expect(network.inFlightCount('node1', 'node2'), equals(0));
      expect(
        network['node1'].messagePort.pendingSendCount(network['node2'].id),
        equals(0),
      );

      // Gate reopens: with the queue drained the engine sends again, so the
      // still-delayed link starts accumulating fresh messages.
      await network.runRounds(4);
      expect(network.inFlightCount('node1', 'node2'), greaterThan(0));

      // ...until the emergent count crosses the threshold again and the gate
      // closes: the queue stabilises instead of growing round over round.
      await network.runRounds(10);
      final resaturated = network.inFlightCount('node1', 'node2');
      await network.runRounds(8);
      expect(network.inFlightCount('node1', 'node2'), equals(resaturated));

      // Settle the network before teardown.
      network.undelayLink('node1', 'node2');
      network.undelayLink('node2', 'node1');
      await network.runRounds(5);
      expect(network.inFlightCount('node1', 'node2'), equals(0));
    });

    test('writes made under sustained congestion converge once the link '
        'drains', () async {
      // Baseline convergence on a healthy link.
      await network['node1'].write(channelId, streamId, [1]);
      await network.runRounds(5);
      expect(await network.hasConverged(channelId, streamId), isTrue);

      network.delayLink('node1', 'node2');
      network.delayLink('node2', 'node1');

      // A write during congestion: the reactive push joins the held queue
      // and the entry cannot reach node2 while the link is saturated.
      await network['node1'].write(channelId, streamId, [2]);
      await network.runRounds(10);
      expect(await network['node2'].entryCount(channelId, streamId), equals(1));
      expect(
        network.inFlightCount('node1', 'node2'),
        equals(congestionThreshold + 1),
        reason:
            'one ungated reactive push plus gated digests until pending '
            'exceeds $congestionThreshold — a larger queue would mean the '
            'gate is not engaged',
      );

      // Once the link drains, anti-entropy delivers the congested write.
      network.undelayLink('node1', 'node2');
      network.undelayLink('node2', 'node1');
      await network.runRounds(15);

      expect(network.inFlightCount('node1', 'node2'), equals(0));
      expect(await network.hasConverged(channelId, streamId), isTrue);
      expect(await network['node2'].entryCount(channelId, streamId), equals(2));
    });
  });

  group('Per-peer congestion isolation', () {
    final channelId = ChannelId('congestion-channel');
    final streamId = StreamId('data');

    test('a congested link is skipped per-peer while gossip with healthy '
        'peers continues', () async {
      final network = await TestNetwork.create([
        'node1',
        'node2',
        'node3',
      ], config: config);
      await network.connectAll();
      await network.setupChannel(channelId, streamId);
      await network.startAll();
      try {
        // Only the node1 ↔ node2 link is slow.
        network.delayLink('node1', 'node2');
        network.delayLink('node2', 'node1');

        await network['node1'].write(channelId, streamId, [7]);
        await network.runRounds(12);

        // node1's queue toward node2 is bounded: one ungated reactive push
        // plus gated digests until the emergent count crosses the threshold.
        final held = network.inFlightCount('node1', 'node2');
        expect(
          held,
          equals(congestionThreshold + 1),
          reason:
              'push + digests queue until pending exceeds '
              '$congestionThreshold, then node2 is excluded from selection',
        );

        // The gate is per-peer, not global: rounds keep gossiping with node3,
        // so the entry reaches node3 directly and node2 via node3 — the mesh
        // converges even though the congested link never delivered anything.
        expect(await network.hasConverged(channelId, streamId), isTrue);
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(1),
        );

        // The congested link's queue stays flat while healthy gossip runs.
        await network.runRounds(8);
        expect(network.inFlightCount('node1', 'node2'), equals(held));

        // Releasing the slow link drains it without disturbing convergence.
        network.undelayLink('node1', 'node2');
        network.undelayLink('node2', 'node1');
        await network.runRounds(10);
        expect(network.inFlightCount('node1', 'node2'), equals(0));
        expect(await network.hasConverged(channelId, streamId), isTrue);
      } finally {
        await network.dispose();
      }
    });
  });
}
