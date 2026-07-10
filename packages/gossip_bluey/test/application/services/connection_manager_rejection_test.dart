import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/application/observability/bluey_metrics.dart';
import 'package:gossip_bluey/src/application/services/connection_manager.dart';
import 'package:gossip_bluey/src/domain/aggregates/connection_registry.dart';
import 'package:gossip_bluey/src/domain/interfaces/bluey_port.dart';
import 'package:gossip_bluey/src/domain/value_objects/ble_address.dart';
import 'package:gossip_bluey/src/infrastructure/codec/control_frame_codec.dart';

import '../../fakes/fake_bluey_port.dart';

void main() {
  late FakeBlueyNetwork network;

  setUp(() {
    network = FakeBlueyNetwork();
  });

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  test('capacity rejection of an inbound peripheral sends one GSP2 '
      'rejection frame on the live link', () async {
    final port = FakeBlueyPort(localNodeId: NodeId('local'), network: network);
    final registry = ConnectionRegistry();
    // Also create the remote's port so sendData can route to it.
    FakeBlueyPort(localNodeId: NodeId('remote-2'), network: network);
    ConnectionManager(
      port: port,
      registry: registry,
      metrics: BlueyMetrics(),
      localNodeId: NodeId('local'),
      maxConnections: 1,
    );

    port.emitPeerConnected(NodeId('remote-1'), ConnectionRole.peripheral,
        address: const BleAddress('addr-1'));
    await pump();
    expect(registry.connectionCount, 1);

    // Second inbound peer hits the cap. NOTE: the fake's sendData
    // requires a live link record — mark it connected first.
    port.markConnectedAsPeripheralForTest(NodeId('remote-2'));
    port.emitPeerConnected(NodeId('remote-2'), ConnectionRole.peripheral,
        address: const BleAddress('addr-2'));
    await pump();

    final rejections = port.sentData
        .map(ControlFrameCodec.tryParse)
        .whereType<ConnectionRejectedFrame>()
        .toList();
    expect(rejections, hasLength(1));
    expect(rejections.single.reason, RejectionReason.capacity);
  });

  test('duplicate / tie-break rejections send NO frame', () async {
    final port = FakeBlueyPort(localNodeId: NodeId('aaa'), network: network);
    final registry = ConnectionRegistry();
    ConnectionManager(
      port: port,
      registry: registry,
      metrics: BlueyMetrics(),
      localNodeId: NodeId('aaa'),
    );

    port.emitPeerConnected(NodeId('zzz'), ConnectionRole.central,
        address: const BleAddress('addr-1'));
    await pump();
    port.emitPeerConnected(NodeId('zzz'), ConnectionRole.peripheral,
        address: const BleAddress('addr-1'));
    await pump();

    expect(
      port.sentData.map(ControlFrameCodec.tryParse).whereType<ControlFrame>(),
      isEmpty,
    );
  });

  test('a failed rejection-frame write is logged and does not throw',
      () async {
    final port = FakeBlueyPort(localNodeId: NodeId('local'), network: network);
    final registry = ConnectionRegistry();
    final logs = <String>[];
    ConnectionManager(
      port: port,
      registry: registry,
      metrics: BlueyMetrics(),
      localNodeId: NodeId('local'),
      maxConnections: 0,
      onLog: (level, message, [error, stack]) => logs.add(message),
    );

    // No link record exists for this peer → the fake's sendData throws.
    port.emitPeerConnected(NodeId('remote-1'), ConnectionRole.peripheral,
        address: const BleAddress('addr-1'));
    await pump();
    await pump();

    expect(registry.connectionCount, 0);
    expect(logs.where((m) => m.contains('rejection frame')), isNotEmpty);
  });
}
