import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/gossip_bluey.dart';

import '../fakes/fake_bluey_port.dart';

void main() {
  group('BlueyTransport', () {
    final localId = NodeId('11111111-1111-1111-1111-111111111111');
    final serviceUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');

    test('create rejects a non-UUID NodeId', () async {
      final repo = InMemoryLocalNodeRepository(nodeId: NodeId('not-a-uuid'));
      expect(
        () => BlueyTransport.create(
          localNodeRepository: repo,
          serviceUuid: serviceUuid,
          displayName: 'phone',
        ),
        throwsArgumentError,
      );
    });

    test('startAdvertising / stopAdvertising flip isAdvertising', () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      final transport = BlueyTransport.testing(
        localNodeId: localId,
        serviceUuid: serviceUuid,
        displayName: 'phone',
        port: port,
      );
      expect(transport.isAdvertising, isFalse);
      await transport.startAdvertising();
      expect(transport.isAdvertising, isTrue);
      await transport.stopAdvertising();
      expect(transport.isAdvertising, isFalse);
      await transport.dispose();
    });

    test('peerEvents fires PeerConnected/PeerDisconnected', () async {
      final remoteId = NodeId('22222222-2222-2222-2222-222222222222');
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      final remote = FakeBlueyPort(localNodeId: remoteId, network: network);
      final transport = BlueyTransport.testing(
        localNodeId: localId,
        serviceUuid: serviceUuid,
        displayName: 'phone',
        port: port,
      );
      await transport.startAdvertising();
      final events = <PeerEvent>[];
      final sub = transport.peerEvents.listen(events.add);

      await remote.connect(localId);
      await Future<void>.delayed(Duration.zero);
      await remote.disconnect(localId);
      await Future<void>.delayed(Duration.zero);

      expect(
        events.whereType<PeerConnected>().map((e) => e.nodeId),
        contains(remoteId),
      );
      expect(
        events.whereType<PeerDisconnected>().map((e) => e.nodeId),
        contains(remoteId),
      );

      await sub.cancel();
      await transport.dispose();
      await remote.dispose();
    });

    group('adapter-state surface', () {
      test('bluetoothAdapterState forwards the port value', () async {
        final network = FakeBlueyNetwork();
        final port = FakeBlueyPort(localNodeId: localId, network: network);
        final transport = BlueyTransport.testing(
          localNodeId: localId,
          serviceUuid: serviceUuid,
          displayName: 'phone',
          port: port,
        );

        port.setBluetoothAdapterStateForTest(BluetoothAdapterState.off);

        expect(
          transport.bluetoothAdapterState,
          equals(BluetoothAdapterState.off),
        );

        await transport.dispose();
      });

      test('bluetoothStateStream forwards the port stream', () async {
        final network = FakeBlueyNetwork();
        final port = FakeBlueyPort(localNodeId: localId, network: network);
        final transport = BlueyTransport.testing(
          localNodeId: localId,
          serviceUuid: serviceUuid,
          displayName: 'phone',
          port: port,
        );

        final received = <BluetoothAdapterState>[];
        final sub = transport.bluetoothStateStream.listen(received.add);

        port.setBluetoothAdapterStateForTest(BluetoothAdapterState.off);
        port.setBluetoothAdapterStateForTest(BluetoothAdapterState.on);
        await Future<void>.delayed(Duration.zero);

        expect(
          received,
          containsAll([BluetoothAdapterState.off, BluetoothAdapterState.on]),
        );

        await sub.cancel();
        await transport.dispose();
      });
    });
  });
}
