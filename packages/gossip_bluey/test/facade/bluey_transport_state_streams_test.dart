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

      expect(transport.advertisingState, equals(AdvertisingState.idle));

      port.setAdvertisingStateForTest(AdvertisingState.advertising);
      expect(
        transport.advertisingState,
        equals(AdvertisingState.advertising),
      );

      await transport.dispose();
    });

    test('advertisingStateStream replays current value on subscribe', () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      port.setAdvertisingStateForTest(AdvertisingState.advertising);
      final transport = makeTransport(port);

      final first = await transport.advertisingStateStream.first;
      expect(first, equals(AdvertisingState.advertising));

      await transport.dispose();
    });

    test('advertisingStateStream emits transitions to subscribers', () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      final transport = makeTransport(port);

      final received = <AdvertisingState>[];
      final sub = transport.advertisingStateStream.listen(received.add);
      await Future<void>.delayed(Duration.zero);

      port.setAdvertisingStateForTest(AdvertisingState.starting);
      port.setAdvertisingStateForTest(AdvertisingState.advertising);
      port.setAdvertisingStateForTest(AdvertisingState.stopping);
      port.setAdvertisingStateForTest(AdvertisingState.idle);
      await Future<void>.delayed(Duration.zero);

      expect(received, [
        AdvertisingState.idle, // replay-current
        AdvertisingState.starting,
        AdvertisingState.advertising,
        AdvertisingState.stopping,
        AdvertisingState.idle,
      ]);

      await sub.cancel();
      await transport.dispose();
    });

    test('scanState reads through to the port', () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      final transport = makeTransport(port);

      expect(transport.scanState, equals(ScanState.stopped));

      port.setScanStateForTest(ScanState.scanning);
      expect(transport.scanState, equals(ScanState.scanning));

      await transport.dispose();
    });

    test('scanStateStream replays current value on subscribe', () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      port.setScanStateForTest(ScanState.scanning);
      final transport = makeTransport(port);

      final first = await transport.scanStateStream.first;
      expect(first, equals(ScanState.scanning));

      await transport.dispose();
    });

    test('scanStateStream emits transitions to subscribers', () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      final transport = makeTransport(port);

      final received = <ScanState>[];
      final sub = transport.scanStateStream.listen(received.add);
      await Future<void>.delayed(Duration.zero);

      port.setScanStateForTest(ScanState.starting);
      port.setScanStateForTest(ScanState.scanning);
      port.setScanStateForTest(ScanState.stopping);
      port.setScanStateForTest(ScanState.stopped);
      await Future<void>.delayed(Duration.zero);

      expect(received, [
        ScanState.stopped, // replay-current
        ScanState.starting,
        ScanState.scanning,
        ScanState.stopping,
        ScanState.stopped,
      ]);

      await sub.cancel();
      await transport.dispose();
    });

    test(
      'advertising: each subscriber sees the current value at its own '
      'subscribe time',
      () async {
        final network = FakeBlueyNetwork();
        final port = FakeBlueyPort(localNodeId: localId, network: network);
        port.setAdvertisingStateForTest(AdvertisingState.advertising);
        final transport = makeTransport(port);

        // Subscriber A subscribes while state is `advertising`.
        final aReceived = <AdvertisingState>[];
        final subA = transport.advertisingStateStream.listen(aReceived.add);
        await Future<void>.delayed(Duration.zero);

        // Transition state.
        port.setAdvertisingStateForTest(AdvertisingState.stopping);
        await Future<void>.delayed(Duration.zero);

        // Subscriber B subscribes AFTER the transition — should replay
        // the current value (`stopping`), not the historical first
        // emission A saw. A shared replay impl would (incorrectly) hand
        // B `advertising` as its first emission.
        final bReceived = <AdvertisingState>[];
        final subB = transport.advertisingStateStream.listen(bReceived.add);
        await Future<void>.delayed(Duration.zero);

        expect(aReceived.first, equals(AdvertisingState.advertising));
        expect(bReceived.first, equals(AdvertisingState.stopping));
        // Confirm A saw the transition as its SECOND emission (not its
        // first), i.e. replay then live stream.
        expect(aReceived, [
          AdvertisingState.advertising,
          AdvertisingState.stopping,
        ]);

        await subA.cancel();
        await subB.cancel();
        await transport.dispose();
      },
    );

    test(
      'scan: each subscriber sees the current value at its own subscribe '
      'time',
      () async {
        final network = FakeBlueyNetwork();
        final port = FakeBlueyPort(localNodeId: localId, network: network);
        port.setScanStateForTest(ScanState.scanning);
        final transport = makeTransport(port);

        // Subscriber A subscribes while state is `scanning`.
        final aReceived = <ScanState>[];
        final subA = transport.scanStateStream.listen(aReceived.add);
        await Future<void>.delayed(Duration.zero);

        // Transition state.
        port.setScanStateForTest(ScanState.stopping);
        await Future<void>.delayed(Duration.zero);

        // Subscriber B subscribes AFTER the transition — should replay
        // the current value (`stopping`), not what A saw first.
        final bReceived = <ScanState>[];
        final subB = transport.scanStateStream.listen(bReceived.add);
        await Future<void>.delayed(Duration.zero);

        expect(aReceived.first, equals(ScanState.scanning));
        expect(bReceived.first, equals(ScanState.stopping));
        expect(aReceived, [
          ScanState.scanning,
          ScanState.stopping,
        ]);

        await subA.cancel();
        await subB.cancel();
        await transport.dispose();
      },
    );
  });
}
