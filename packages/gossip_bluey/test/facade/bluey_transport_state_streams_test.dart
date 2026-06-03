import 'package:bluey/bluey.dart' as bluey;
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/gossip_bluey.dart';

import '../fakes/fake_bluey_port.dart';

void main() {
  group('BlueyTransport state streams', () {
    final localId = NodeId('11111111-1111-1111-1111-111111111111');
    final serviceUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');

    BlueyTransport makeTransport(FakeBlueyPort port) => BlueyTransport.testing(
      localNodeId: localId,
      serviceUuid: serviceUuid,
      displayName: 'phone',
      port: port,
    );

    test('advertisingState reads through to the port', () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      final transport = makeTransport(port);

      expect(transport.advertisingState, equals(bluey.AdvertisingState.idle));

      port.setAdvertisingStateForTest(bluey.AdvertisingState.advertising);
      expect(
        transport.advertisingState,
        equals(bluey.AdvertisingState.advertising),
      );

      await transport.dispose();
    });

    test('advertisingStateStream replays current value on subscribe', () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      port.setAdvertisingStateForTest(bluey.AdvertisingState.advertising);
      final transport = makeTransport(port);

      final first = await transport.advertisingStateStream.first;
      expect(first, equals(bluey.AdvertisingState.advertising));

      await transport.dispose();
    });

    test('advertisingStateStream emits transitions to subscribers', () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      final transport = makeTransport(port);

      final received = <bluey.AdvertisingState>[];
      final sub = transport.advertisingStateStream.listen(received.add);
      await Future<void>.delayed(Duration.zero);

      port.setAdvertisingStateForTest(bluey.AdvertisingState.starting);
      port.setAdvertisingStateForTest(bluey.AdvertisingState.advertising);
      port.setAdvertisingStateForTest(bluey.AdvertisingState.stopping);
      port.setAdvertisingStateForTest(bluey.AdvertisingState.idle);
      await Future<void>.delayed(Duration.zero);

      expect(received, [
        bluey.AdvertisingState.idle, // replay-current
        bluey.AdvertisingState.starting,
        bluey.AdvertisingState.advertising,
        bluey.AdvertisingState.stopping,
        bluey.AdvertisingState.idle,
      ]);

      await sub.cancel();
      await transport.dispose();
    });

    test('scanState reads through to the port', () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      final transport = makeTransport(port);

      expect(transport.scanState, equals(bluey.ScanState.stopped));

      port.setScanStateForTest(bluey.ScanState.scanning);
      expect(transport.scanState, equals(bluey.ScanState.scanning));

      await transport.dispose();
    });

    test('scanStateStream replays current value on subscribe', () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      port.setScanStateForTest(bluey.ScanState.scanning);
      final transport = makeTransport(port);

      final first = await transport.scanStateStream.first;
      expect(first, equals(bluey.ScanState.scanning));

      await transport.dispose();
    });

    test('scanStateStream emits transitions to subscribers', () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      final transport = makeTransport(port);

      final received = <bluey.ScanState>[];
      final sub = transport.scanStateStream.listen(received.add);
      await Future<void>.delayed(Duration.zero);

      port.setScanStateForTest(bluey.ScanState.starting);
      port.setScanStateForTest(bluey.ScanState.scanning);
      port.setScanStateForTest(bluey.ScanState.stopping);
      port.setScanStateForTest(bluey.ScanState.stopped);
      await Future<void>.delayed(Duration.zero);

      expect(received, [
        bluey.ScanState.stopped, // replay-current
        bluey.ScanState.starting,
        bluey.ScanState.scanning,
        bluey.ScanState.stopping,
        bluey.ScanState.stopped,
      ]);

      await sub.cancel();
      await transport.dispose();
    });

    test('multiple simultaneous subscribers each receive independent replay',
        () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      port.setAdvertisingStateForTest(bluey.AdvertisingState.advertising);
      final transport = makeTransport(port);

      final aReceived = <bluey.AdvertisingState>[];
      final subA = transport.advertisingStateStream.listen(aReceived.add);
      await Future<void>.delayed(Duration.zero);

      // Subscriber B comes later — should still see replay-current.
      final bReceived = <bluey.AdvertisingState>[];
      final subB = transport.advertisingStateStream.listen(bReceived.add);
      await Future<void>.delayed(Duration.zero);

      expect(aReceived.first, equals(bluey.AdvertisingState.advertising));
      expect(bReceived.first, equals(bluey.AdvertisingState.advertising));

      port.setAdvertisingStateForTest(bluey.AdvertisingState.stopping);
      await Future<void>.delayed(Duration.zero);

      expect(aReceived.last, equals(bluey.AdvertisingState.stopping));
      expect(bReceived.last, equals(bluey.AdvertisingState.stopping));

      await subA.cancel();
      await subB.cancel();
      await transport.dispose();
    });
  });
}
