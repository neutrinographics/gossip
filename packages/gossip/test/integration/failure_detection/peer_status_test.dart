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
        await network.runRounds(5);

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
        await network.runRounds(5);

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
        network.partition('node2');
        await network.runRounds(5);

        var status = network['node1'].peerStatus(network['node2'].id);
        expect(
          status,
          anyOf(equals(PeerStatus.suspected), equals(PeerStatus.unreachable)),
        );

        // Heal the network
        network.heal('node2');
        await network.runRounds(10);

        // Peer should be reachable again
        status = network['node1'].peerStatus(network['node2'].id);
        expect(status, equals(PeerStatus.reachable));
        expect(network['node1'].reachablePeers.length, equals(1));
      });
    });
  });
}
