import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart' show NodeId;
import 'package:gossip_bluey/src/domain/interfaces/bluey_port.dart';

import 'fake_bluey_port.dart';

/// GATT fidelity: a peripheral's notification only reaches a central that
/// has subscribed to it. On real hardware the subscribe lands measurably
/// after the peripheral already considers the link up (the central is
/// still mid service discovery) — the window in which WIRE4-9's rejection
/// frame is lost. The fake must be able to model that window.
void main() {
  final centralId = NodeId('central-node');
  final peripheralId = NodeId('peripheral-node');

  late FakeBlueyNetwork network;
  late FakeBlueyPort central;
  late FakeBlueyPort peripheral;

  setUp(() {
    network = FakeBlueyNetwork();
    central = FakeBlueyPort(localNodeId: centralId, network: network);
    peripheral = FakeBlueyPort(localNodeId: peripheralId, network: network);
  });

  tearDown(() async {
    await central.dispose();
    await peripheral.dispose();
  });

  Uint8List bytes(List<int> b) => Uint8List.fromList(b);

  test(
      'a notification sent before the central has subscribed is silently '
      'lost: the sender sees success, the central receives nothing', () async {
    central.notificationSubscribeDelay = const Duration(milliseconds: 50);

    final delivered = <PortPeerData>[];
    central.events.listen((e) {
      if (e is PortPeerData) delivered.add(e);
    });

    await central.connect(peripheralId);

    // The peripheral notifies inside the pre-subscribe window. Real GATT:
    // notifyTo an unsubscribed client is not an error — the sender must
    // NOT throw.
    await peripheral.sendData(centralId, bytes([1, 2, 3]));
    await Future<void>.delayed(Duration.zero);

    expect(delivered, isEmpty,
        reason: 'notification into an unsubscribed characteristic must be '
            'lost, not delivered');
    expect(peripheral.preSubscribeDrops[centralId], 1,
        reason: 'the loss must be observable to tests');
  });

  test('after the subscribe delay elapses, notifications are delivered',
      () async {
    central.notificationSubscribeDelay = const Duration(milliseconds: 20);

    final delivered = <PortPeerData>[];
    central.events.listen((e) {
      if (e is PortPeerData) delivered.add(e);
    });

    await central.connect(peripheralId);
    await Future<void>.delayed(const Duration(milliseconds: 40));

    await peripheral.sendData(centralId, bytes([4, 5, 6]));
    await Future<void>.delayed(Duration.zero);

    expect(delivered, hasLength(1));
    expect(delivered.single.data, bytes([4, 5, 6]));
  });

  test('with no configured delay, subscription is immediate (default '
      'behavior of every existing test is preserved)', () async {
    final delivered = <PortPeerData>[];
    central.events.listen((e) {
      if (e is PortPeerData) delivered.add(e);
    });

    await central.connect(peripheralId);
    await peripheral.sendData(centralId, bytes([7]));
    await Future<void>.delayed(Duration.zero);

    expect(delivered, hasLength(1));
  });

  test('subscription does not survive disconnect: a reconnect with a '
      'delay re-opens the loss window', () async {
    await central.connect(peripheralId); // immediate subscribe
    await central.disconnect(peripheralId);

    central.notificationSubscribeDelay = const Duration(milliseconds: 50);
    final delivered = <PortPeerData>[];
    central.events.listen((e) {
      if (e is PortPeerData) delivered.add(e);
    });
    await central.connect(peripheralId);

    await peripheral.sendData(centralId, bytes([1]));
    await Future<void>.delayed(Duration.zero);

    expect(delivered, isEmpty,
        reason: 'the first connection\'s subscription must not leak into '
            'the new physical link');
    expect(peripheral.preSubscribeDrops[centralId], 1);
  });

  test('a rejected peripheral link still delivers notifications to a '
      'subscribed central (mirrors the real port: the physical link '
      'stays up, and the WIRE4-9 re-send depends on it)', () async {
    final delivered = <PortPeerData>[];
    central.events.listen((e) {
      if (e is PortPeerData) delivered.add(e);
    });

    await central.connect(peripheralId); // immediate subscribe
    // Capacity rejection: the peripheral tears down its own role
    // bookkeeping, but bluey has no per-client disconnect — the link
    // stays physically alive until the central closes it.
    await peripheral.disconnectRole(centralId, ConnectionRole.peripheral);

    await peripheral.sendData(centralId, bytes([3, 1]));
    await Future<void>.delayed(Duration.zero);

    expect(delivered, hasLength(1),
        reason: 'the rejection re-send must reach the still-alive central');
  });

  test('writes from the central are NOT gated on subscription '
      '(write-without-response needs no CCCD)', () async {
    central.notificationSubscribeDelay = const Duration(milliseconds: 50);

    final delivered = <PortPeerData>[];
    peripheral.events.listen((e) {
      if (e is PortPeerData) delivered.add(e);
    });

    await central.connect(peripheralId);
    await central.sendData(peripheralId, bytes([8, 9]));
    await Future<void>.delayed(Duration.zero);

    expect(delivered, hasLength(1),
        reason: 'central->peripheral writes never depended on subscription');
  });
}
