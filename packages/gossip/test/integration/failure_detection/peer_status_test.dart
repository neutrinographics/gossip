import 'package:test/test.dart';
import 'package:gossip/src/domain/events/domain_event.dart';
import 'package:gossip/src/facade/coordinator_config.dart';

import '../../support/test_network.dart';

void main() {
  group('Peer Status', () {
    group('Peer failure detection', () {
      late TestNetwork network;

      setUp(() async {
        network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');
      });

      tearDown(() async {
        await network.dispose();
      });

      test('peers start as reachable', () async {
        expect(network['node1'].reachablePeers.length, equals(1));
        expect(network['node2'].reachablePeers.length, equals(1));
      });

      test('peer remains reachable when network is healthy', () async {
        await network.startAll();
        await network.runRounds(10);

        expect(network['node1'].reachablePeers.length, equals(1));
        expect(network['node2'].reachablePeers.length, equals(1));
      });

      test('peer becomes suspected after network partition', () async {
        await network.startAll();
        expect(network['node1'].reachablePeers.length, equals(1));

        network.partition('node2');
        // With RTT-adaptive timing (initial: 3s ping timeout, 9s probe interval),
        // each probe round takes ~15s (probeInterval + pingTimeout for direct
        // + pingTimeout for grace period). Need 5 failures for suspicionThreshold.
        // Run 80 rounds at 1s each = 80s, enough for 5+ complete probe rounds.
        await network.runRounds(80);

        final reachable = network['node1'].reachablePeers;
        expect(reachable.any((p) => p.id == network['node2'].id), isFalse);

        final status = network['node1'].peerStatus(network['node2'].id);
        expect(
          status,
          anyOf(equals(PeerStatus.suspected), equals(PeerStatus.unreachable)),
        );
      });

      test('partitioned peer has increased failed probe count', () async {
        await network.startAll();

        var peer = network['node1'].peers.firstWhere(
          (p) => p.id == network['node2'].id,
        );
        expect(peer.failedProbeCount, equals(0));

        network.partition('node2');
        // With RTT-adaptive timing (initial: 3s ping timeout, 9s probe interval),
        // each probe round takes ~15s. Run 30 rounds to ensure at least
        // 1-2 complete probe rounds with failures.
        await network.runRounds(30);

        peer = network['node1'].peers.firstWhere(
          (p) => p.id == network['node2'].id,
        );
        expect(peer.failedProbeCount, greaterThan(0));
      });
    });

    group('Failure detection recovery', () {
      late TestNetwork network;

      setUp(() async {
        network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');
      });

      tearDown(() async {
        await network.dispose();
      });

      test('peer recovers from suspected to reachable after heal', () async {
        await network.startAll();

        // Verify initially reachable
        expect(network['node1'].reachablePeers.length, equals(1));

        // Partition and wait for suspected status
        // With RTT-adaptive timing (initial: 3s ping timeout, 9s probe interval),
        // each probe round takes ~15s. Need 5 failures for suspicionThreshold.
        // Run 80 rounds = 80s for 5+ complete probe rounds.
        network.partition('node2');
        await network.runRounds(80);

        var status = network['node1'].peerStatus(network['node2'].id);
        expect(
          status,
          anyOf(equals(PeerStatus.suspected), equals(PeerStatus.unreachable)),
        );

        // Heal the network and wait for recovery
        // Run enough rounds for at least one successful probe round.
        network.heal('node2');
        await network.runRounds(30);

        // Peer should be reachable again
        status = network['node1'].peerStatus(network['node2'].id);
        expect(status, equals(PeerStatus.reachable));
        expect(network['node1'].reachablePeers.length, equals(1));
      });
    });

    group('Unreachable transition', () {
      late TestNetwork network;

      setUp(() async {
        // Use lower thresholds for faster test execution:
        // suspicionThreshold: 3 (reachable → suspected after 3 failures)
        // unreachableThreshold: 6 (suspected → unreachable after 6 total)
        network = await TestNetwork.create(
          ['node1', 'node2'],
          config: const CoordinatorConfig(
            suspicionThreshold: 3,
            unreachableThreshold: 6,
          ),
        );
        await network.connect('node1', 'node2');
      });

      tearDown(() async {
        await network.dispose();
      });

      test('peer becomes unreachable after prolonged partition', () async {
        await network.startAll();
        expect(network['node1'].reachablePeers.length, equals(1));

        network.partition('node2');
        // With adaptive timing and low thresholds, 80 rounds should be
        // more than enough for 6+ failed probes.
        await network.runRounds(80);

        final status = network['node1'].peerStatus(network['node2'].id);
        expect(status, equals(PeerStatus.unreachable));
      });

      test('unreachable peer recovers to reachable after heal', () async {
        await network.startAll();

        // Partition until unreachable
        network.partition('node2');
        await network.runRounds(80);

        expect(
          network['node1'].peerStatus(network['node2'].id),
          equals(PeerStatus.unreachable),
        );

        // Heal the network and re-add peers to simulate transport reconnection.
        // In production, Nearby Connections fires addPeer on reconnection.
        network.heal('node2');
        await network['node1'].coordinator.addPeer(network['node2'].id);
        await network['node2'].coordinator.addPeer(network['node1'].id);
        await network.runRounds(30);

        final status = network['node1'].peerStatus(network['node2'].id);
        expect(status, equals(PeerStatus.reachable));
        expect(network['node1'].reachablePeers.length, equals(1));
      });
    });

    group('Mutual unreachable recovery', () {
      late TestNetwork network;

      setUp(() async {
        // Low thresholds for fast test + unreachable probing every 3 rounds.
        network = await TestNetwork.create(
          ['node1', 'node2'],
          config: const CoordinatorConfig(
            suspicionThreshold: 3,
            unreachableThreshold: 6,
            unreachableProbeInterval: 3,
          ),
        );
        await network.connect('node1', 'node2');
      });

      tearDown(() async {
        await network.dispose();
      });

      test(
        'mutual unreachable deadlock recovers via periodic probing',
        () async {
          await network.startAll();

          // Both nodes see each other as reachable.
          expect(network['node1'].reachablePeers.length, equals(1));
          expect(network['node2'].reachablePeers.length, equals(1));

          // Partition both nodes simultaneously — simulates both apps
          // backgrounded, neither can send or receive.
          network.partition('node1');
          network.partition('node2');

          // Run enough rounds for both to reach unreachable (6 failed probes).
          // With RTT-adaptive timing, 80 rounds is more than enough.
          await network.runRounds(80);

          expect(
            network['node1'].peerStatus(network['node2'].id),
            equals(PeerStatus.unreachable),
          );
          expect(
            network['node2'].peerStatus(network['node1'].id),
            equals(PeerStatus.unreachable),
          );

          // Heal both — transport is reconnected, but neither side knows.
          // Without periodic unreachable probing, this deadlock is permanent.
          network.heal('node1');
          network.heal('node2');

          // Run rounds until the unreachable probe interval triggers.
          // With interval=3, a probe fires every 3rd round. 30 rounds should
          // give ~10 opportunities for recovery probes.
          await network.runRounds(30);

          // Both nodes should recover each other to reachable.
          expect(
            network['node1'].peerStatus(network['node2'].id),
            equals(PeerStatus.reachable),
          );
          expect(
            network['node2'].peerStatus(network['node1'].id),
            equals(PeerStatus.reachable),
          );
        },
      );
    });
  });
}
