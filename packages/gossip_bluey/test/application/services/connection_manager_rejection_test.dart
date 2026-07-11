import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/application/observability/bluey_metrics.dart';
import 'package:gossip_bluey/src/application/services/connection_manager.dart';
import 'package:gossip_bluey/src/domain/aggregates/connection_registry.dart';
import 'package:gossip_bluey/src/domain/errors/connection_error.dart';
import 'package:gossip_bluey/src/domain/events/connection_event.dart';
import 'package:gossip_bluey/src/domain/interfaces/bluey_port.dart';
import 'package:gossip_bluey/src/domain/value_objects/ble_address.dart';
import 'package:gossip_bluey/src/infrastructure/codec/control_frame_codec.dart';
import 'package:gossip_bluey/src/infrastructure/codec/frame_codec.dart';

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

  group('rejection receiver', () {
    test('central receiving CONNECTION_REJECTED closes its link, emits '
        'PeerClosed with a distinct reason, and surfaces a typed error',
        () async {
      final port = FakeBlueyPort(localNodeId: NodeId('local'), network: network);
      final registry = ConnectionRegistry();
      final manager = ConnectionManager(
        port: port,
        registry: registry,
        metrics: BlueyMetrics(),
        localNodeId: NodeId('local'),
      );
      final events = <ConnectionEvent>[];
      final errors = <ConnectionError>[];
      manager.events.listen(events.add);
      manager.errors.listen(errors.add);

      final remote = NodeId('remote');
      port.emitPeerConnected(remote, ConnectionRole.central,
          address: const BleAddress('addr-1'));
      await pump();

      port.emitPeerData(
        remote,
        ControlFrameCodec.encodeRejection(RejectionReason.capacity),
      );
      await pump();

      expect(registry.contains(remote), isFalse);
      expect(
        port.disconnectRoleCalls,
        contains((remote, ConnectionRole.central)),
      );
      final closed = events.whereType<PeerClosed>().single;
      expect(closed.reason, contains('rejected by peer'));
      final rejected =
          errors.whereType<ConnectionRejectedByPeerError>().single;
      expect(rejected.nodeId, remote);
      expect(rejected.reason, RejectionReason.capacity);
    });

    test('a rejection frame on a link where we are NOT central is ignored',
        () async {
      final port = FakeBlueyPort(localNodeId: NodeId('local'), network: network);
      final registry = ConnectionRegistry();
      ConnectionManager(
        port: port,
        registry: registry,
        metrics: BlueyMetrics(),
        localNodeId: NodeId('local'),
      );

      final remote = NodeId('remote');
      port.emitPeerConnected(remote, ConnectionRole.peripheral,
          address: const BleAddress('addr-1'));
      await pump();

      port.emitPeerData(
        remote,
        ControlFrameCodec.encodeRejection(RejectionReason.capacity),
      );
      await pump();

      expect(registry.contains(remote), isTrue,
          reason: 'only a central acts on rejection frames');
    });

    test('GSP2-looking bytes inside a GSP1 payload are NOT treated as '
        'control frames', () async {
      final port = FakeBlueyPort(localNodeId: NodeId('local'), network: network);
      final registry = ConnectionRegistry();
      final manager = ConnectionManager(
        port: port,
        registry: registry,
        metrics: BlueyMetrics(),
        localNodeId: NodeId('local'),
      );
      final received = <IncomingMessage>[];
      manager.incomingMessages.listen(received.add);

      final remote = NodeId('remote');
      port.emitPeerConnected(remote, ConnectionRole.central,
          address: const BleAddress('addr-1'));
      await pump();

      // A gossip payload whose bytes are exactly a rejection frame,
      // legitimately framed in GSP1 and split so the second chunk starts
      // with the GSP2 magic (decoder is mid-frame at that point).
      final payload = ControlFrameCodec.encodeRejection(RejectionReason.capacity);
      final chunks = FrameEncoder.encode(payload, mtuPayloadSize: 9);
      for (final c in chunks) {
        port.emitPeerData(remote, c);
      }
      await pump();

      expect(registry.contains(remote), isTrue);
      expect(received, hasLength(1));
      expect(received.single.bytes, equals(payload));
    });
  });
}
