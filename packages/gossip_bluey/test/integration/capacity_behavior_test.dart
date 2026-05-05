import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/gossip_bluey.dart';

import '../fakes/fake_bluey_port.dart';

void main() {
  group('capacity behavior', () {
    final serviceUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');
    final aId = NodeId('11111111-1111-1111-1111-111111111111');
    final bId = NodeId('22222222-2222-2222-2222-222222222222');
    final cId = NodeId('33333333-3333-3333-3333-333333333333');
    final dId = NodeId('44444444-4444-4444-4444-444444444444');

    test(
      'maxConnections rejects extra incoming, targetConnections allows fewer initiations',
      () async {
        final network = FakeBlueyNetwork();
        final aPort = FakeBlueyPort(localNodeId: aId, network: network);
        final bPort = FakeBlueyPort(localNodeId: bId, network: network);
        final cPort = FakeBlueyPort(localNodeId: cId, network: network);
        final dPort = FakeBlueyPort(localNodeId: dId, network: network);

        final transportA = BlueyTransport.testing(
          localNodeId: aId,
          serviceUuid: serviceUuid,
          displayName: 'A',
          port: aPort,
          maxConnections: 2,
          targetConnections: 1,
        );

        // Other peers advertise so A can see them in discovery.
        await bPort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'B',
          localNodeId: bId,
        );
        await cPort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'C',
          localNodeId: cId,
        );
        await dPort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'D',
          localNodeId: dId,
        );
        await transportA.startAdvertising();
        await transportA.startDiscovery();

        final errors = <ConnectionError>[];
        final errSub = transportA.errors.listen(errors.add);

        // 1) Discovery round: A initiates only one connection (targetConnections=1).
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(transportA.connectedPeerCount, equals(1));

        // 2) C connects inbound — A is below maxConnections=2 so it's accepted.
        await cPort.connect(aId);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(transportA.connectedPeerCount, equals(2));

        // 3) D connects inbound — A is at maxConnections=2 so it's rejected.
        await dPort.connect(aId);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(transportA.connectedPeerCount, equals(2)); // still 2
        expect(errors.whereType<ConnectionLimitReachedError>(), isNotEmpty);

        // 4) Disconnect everyone. Discovery is long-lived now, so A's
        // scan will keep re-emitting candidates; once the registry
        // empties, _onCandidate reconnects up to targetConnections=1.
        // We can't reliably observe an intermediate count=0 because
        // the continuous-scan rebroadcast may reconnect within the
        // assertion window.
        await transportA.disconnectAll();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(transportA.connectedPeerCount, equals(1));

        await errSub.cancel();
        await transportA.dispose();
        await bPort.dispose();
        await cPort.dispose();
        await dPort.dispose();
      },
    );
  });
}
