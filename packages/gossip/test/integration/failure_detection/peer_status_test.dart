import 'package:test/test.dart';
import 'package:gossip/src/domain/events/domain_event.dart';

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
        // With BLE-friendly timing (3s probe interval, 2s ping timeout),
        // each probe round takes ~7s (probeInterval + pingTimeout for direct
        // + pingTimeout for grace period). Need 5 failures for suspicionThreshold.
        // Run 40 rounds at 1s each = 40s, enough for 5+ complete probe rounds.
        await network.runRounds(40);

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
        // With BLE-friendly timing (3s probe interval, 2s ping timeout),
        // each probe round takes ~5s. Run 15 rounds to ensure at least
        // 1-2 complete probe rounds with failures.
        await network.runRounds(15);

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
        // With BLE-friendly timing (3s probe interval, 2s ping timeout),
        // each probe round takes ~7s. Need 5 failures for suspicionThreshold.
        // Run 40 rounds = 40s for 5+ complete probe rounds.
        network.partition('node2');
        await network.runRounds(40);

        var status = network['node1'].peerStatus(network['node2'].id);
        expect(
          status,
          anyOf(equals(PeerStatus.suspected), equals(PeerStatus.unreachable)),
        );

        // Heal the network and wait for recovery
        // Run enough rounds for at least one successful probe round.
        network.heal('node2');
        await network.runRounds(15);

        // Peer should be reachable again
        status = network['node1'].peerStatus(network['node2'].id);
        expect(status, equals(PeerStatus.reachable));
        expect(network['node1'].reachablePeers.length, equals(1));
      });
    });
  });
}
