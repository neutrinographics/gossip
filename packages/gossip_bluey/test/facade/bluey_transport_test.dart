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

    test('radio-mode knobs reach the port on advertising and discovery '
        '(WIRE4-7)', () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      final transport = BlueyTransport.testing(
        localNodeId: localId,
        serviceUuid: serviceUuid,
        displayName: 'phone',
        port: port,
        scanMode: ScanMode.lowPower,
        advertiseMode: AdvertiseMode.balanced,
      );
      addTearDown(transport.dispose);

      await transport.startAdvertising();
      expect(port.lastAdvertiseMode, AdvertiseMode.balanced);

      await transport.startDiscovery();
      expect(port.lastScanMode, ScanMode.lowPower);
    });

    test(
      'startAdvertising / stopAdvertising drive advertisingState',
      () async {
        final network = FakeBlueyNetwork();
        final port = FakeBlueyPort(localNodeId: localId, network: network);
        final transport = BlueyTransport.testing(
          localNodeId: localId,
          serviceUuid: serviceUuid,
          displayName: 'phone',
          port: port,
        );
        expect(transport.advertisingState, AdvertisingState.idle);
        await transport.startAdvertising();
        expect(transport.advertisingState, AdvertisingState.advertising);
        await transport.stopAdvertising();
        expect(transport.advertisingState, AdvertisingState.idle);
        await transport.dispose();
      },
    );

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

      test(
        'adapter-off resets advertisingState and scanState',
        () async {
          final network = FakeBlueyNetwork();
          final port = FakeBlueyPort(localNodeId: localId, network: network);
          final transport = BlueyTransport.testing(
            localNodeId: localId,
            serviceUuid: serviceUuid,
            displayName: 'phone',
            port: port,
          );

          await transport.startAdvertising();
          await transport.startDiscovery();
          expect(
            transport.advertisingState,
            AdvertisingState.advertising,
          );
          expect(transport.scanState, ScanState.scanning);

          port.setBluetoothAdapterStateForTest(BluetoothAdapterState.off);
          await Future<void>.delayed(Duration.zero);

          expect(transport.advertisingState, AdvertisingState.idle);
          expect(transport.scanState, ScanState.stopped);

          await transport.dispose();
        },
      );

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
