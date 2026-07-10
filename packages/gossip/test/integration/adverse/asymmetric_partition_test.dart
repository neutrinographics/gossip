import 'package:test/test.dart';
import 'package:gossip/src/domain/events/domain_event.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/facade/coordinator_config.dart';

import '../../support/test_network.dart';

/// Asymmetric (one-way) partition scenarios.
///
/// The link condition throughout is `partitionOneWay('nodeB', 'nodeA')`:
/// nodeA can send to nodeB, but everything nodeB sends to nodeA is lost.
/// nodeA is the "one-way-deaf" node — it never hears nodeB directly.
///
/// With a relay (nodeC bidirectionally connected to both sides), SWIM's
/// indirect probing (PingReq via nodeC) must keep both views reachable and
/// gossip must converge through the relay. Without a relay, the deaf node
/// has no intermediaries and must eventually suspect its peer.
void main() {
  group('Asymmetric Partition', () {
    group('With relay (nodeC connected to both sides)', () {
      late TestNetwork network;
      final channelId = ChannelId('asym-relay-channel');
      final streamId = StreamId('data');

      setUp(() async {
        network = await TestNetwork.create(['nodeA', 'nodeB', 'nodeC']);
        await network.connectAll();
        await network.setupChannel(channelId, streamId);
        await network.startAll();
      });

      tearDown(() async {
        await network.dispose();
      });

      test(
        'indirect probing through the relay keeps both views reachable',
        () async {
          // Healthy baseline: everyone reachable, RTT samples collected.
          await network.runRounds(5);
          expect(
            network['nodeA'].peerStatus(network['nodeB'].id),
            equals(PeerStatus.reachable),
          );
          expect(
            network['nodeB'].peerStatus(network['nodeA'].id),
            equals(PeerStatus.reachable),
          );

          // nodeA stops hearing nodeB directly.
          network.partitionOneWay('nodeB', 'nodeA');

          // Run long enough for many probe rounds. Every direct probe on
          // the A↔B pair now fails (nodeA's Pings reach nodeB but the Acks
          // are lost; nodeB's Pings never arrive), so each round falls back
          // to the indirect phase:
          //   nodeA → PingReq → nodeC → Ping → nodeB → Ack → nodeC → nodeA
          //   nodeB → PingReq → nodeC → Ping → nodeA → Ack → nodeC → nodeB
          // Both relay paths avoid the blocked direction, so no probe
          // failures accumulate on either side.
          await network.runRounds(60);

          expect(
            network['nodeA'].peerStatus(network['nodeB'].id),
            equals(PeerStatus.reachable),
            reason:
                'ping-req through nodeC must keep nodeB reachable '
                'from the deaf node',
          );
          expect(
            network['nodeB'].peerStatus(network['nodeA'].id),
            equals(PeerStatus.reachable),
            reason:
                'ping-req through nodeC must keep nodeA reachable even '
                'though nodeB cannot reach nodeA directly',
          );
          // The relay itself talks to both sides directly and stays healthy.
          expect(network['nodeC'].reachablePeers.length, equals(2));
        },
      );

      test(
        'state converges through the relay while the block is active',
        () async {
          // Baseline convergence before the partition.
          await network['nodeA'].write(channelId, streamId, [0xA0]);
          await network.runRounds(5);
          expect(await network.hasConverged(channelId, streamId), isTrue);

          network.partitionOneWay('nodeB', 'nodeA');

          // Both sides of the asymmetric link write during the block.
          await network['nodeA'].write(channelId, streamId, [0xA1]);
          await network['nodeB'].write(channelId, streamId, [0xB1]);

          // A direct A↔B gossip exchange can never complete (every response
          // nodeB → nodeA is lost), but nodeC is bidirectionally connected to
          // both sides: nodeA's entry flows A → C → B and nodeB's entry flows
          // B → C → A. Multi-hop needs more rounds than a direct exchange.
          await network.runRounds(25);

          expect(
            await network.hasConverged(channelId, streamId),
            isTrue,
            reason: 'entries must converge via the relay despite the block',
          );
          expect(
            await network['nodeA'].entryCount(channelId, streamId),
            equals(3),
          );
          expect(
            await network['nodeB'].entryCount(channelId, streamId),
            equals(3),
          );
          expect(
            await network['nodeC'].entryCount(channelId, streamId),
            equals(3),
          );

          // Healing the direction keeps the network converged for new writes.
          network.healOneWay('nodeB', 'nodeA');
          await network['nodeB'].write(channelId, streamId, [0xB2]);
          await network.runRounds(15);

          expect(await network.hasConverged(channelId, streamId), isTrue);
          expect(
            await network['nodeA'].entryCount(channelId, streamId),
            equals(4),
          );
        },
      );
    });

    group('Without a relay (deaf pair)', () {
      late TestNetwork network;

      setUp(() async {
        // Lower thresholds for faster status transitions, matching the
        // unreachable-transition tests in peer_status_test.dart.
        network = await TestNetwork.create(
          ['nodeA', 'nodeB'],
          config: const CoordinatorConfig(
            suspicionThreshold: 3,
            unreachableThreshold: 6,
          ),
        );
        await network.connect('nodeA', 'nodeB');
        await network.startAll();
      });

      tearDown(() async {
        await network.dispose();
      });

      test('one-way-deaf node eventually suspects its peer', () async {
        await network.runRounds(5);
        expect(
          network['nodeA'].peerStatus(network['nodeB'].id),
          equals(PeerStatus.reachable),
        );

        // nodeA becomes deaf to nodeB. nodeA's Pings still reach nodeB,
        // but every Ack back is lost — and with no third node there are no
        // intermediaries for an indirect ping, so each probe round records
        // a failure on nodeA.
        network.partitionOneWay('nodeB', 'nodeA');

        // With RTT-adaptive timing, 80 rounds gives ample probe rounds for
        // 6+ consecutive failures (same budget as peer_status_test.dart).
        await network.runRounds(80);

        final status = network['nodeA'].peerStatus(network['nodeB'].id);
        expect(
          status,
          anyOf(equals(PeerStatus.suspected), equals(PeerStatus.unreachable)),
          reason: 'the deaf node hears nothing back and must suspect its peer',
        );
        expect(
          network['nodeA'].reachablePeers.any(
            (p) => p.id == network['nodeB'].id,
          ),
          isFalse,
        );
        // nodeB's view is deliberately not asserted: it keeps receiving
        // nodeA's Pings (each one counts as contact and resets its failed
        // probe count), so its status oscillates with probe phase.
      });

      test('deaf node recovers its peer after the one-way heal', () async {
        network.partitionOneWay('nodeB', 'nodeA');
        await network.runRounds(80);

        expect(
          network['nodeA'].peerStatus(network['nodeB'].id),
          anyOf(equals(PeerStatus.suspected), equals(PeerStatus.unreachable)),
        );

        // Heal the blocked direction. Recovery needs no reconnection event:
        // suspected peers are still probed every round, and unreachable
        // peers are probed every unreachableProbeInterval rounds, so the
        // first Ack that gets through restores reachable status.
        network.healOneWay('nodeB', 'nodeA');
        await network.runRounds(50);

        expect(
          network['nodeA'].peerStatus(network['nodeB'].id),
          equals(PeerStatus.reachable),
        );
        expect(network['nodeA'].reachablePeers.length, equals(1));
      });
    });
  });
}
