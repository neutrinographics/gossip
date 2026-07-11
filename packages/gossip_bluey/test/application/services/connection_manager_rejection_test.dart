import 'dart:typed_data';

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

    test('a byte-exact GSP2 frame arriving MID-GSP1-FRAME is NOT dispatched '
        'as a rejection (decoder.isAtFrameBoundary guard)', () async {
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

      // A payload-agnostic library carries opaque app bytes: build a
      // gossip payload whose interior is a byte-exact GSP2 rejection frame
      // (x ++ GSP2 ++ y). Framed into a single GSP1 frame, then delivered
      // in three writes so the SECOND write is exactly the GSP2 rejection
      // frame — arriving while the decoder is mid-payload, i.e. NOT at a
      // frame boundary.
      final gsp2 =
          ControlFrameCodec.encodeRejection(RejectionReason.capacity);
      final x = Uint8List.fromList([0x01, 0x02, 0x03]);
      final y = Uint8List.fromList([0x04, 0x05]);
      final payload = Uint8List.fromList([...x, ...gsp2, ...y]);
      // One GSP1 frame: [magic 4][len 4][payload]. header = 8 bytes.
      final frame =
          FrameEncoder.encode(payload, mtuPayloadSize: 4096).single;
      const header = 8;
      final gsp2Start = header + x.length;
      final gsp2End = gsp2Start + gsp2.length;

      // Write 1: header + x → decoder now mid-payload (not at boundary).
      port.emitPeerData(remote, frame.sublist(0, gsp2Start));
      await pump();
      // Write 2: the byte-exact GSP2 rejection frame, mid-GSP1-frame.
      final gsp2Chunk = frame.sublist(gsp2Start, gsp2End);
      expect(gsp2Chunk, equals(gsp2),
          reason: 'second write must be byte-identical to a GSP2 frame');
      port.emitPeerData(remote, gsp2Chunk);
      await pump();

      // The guard suppressed dispatch: the central link is untouched.
      expect(registry.contains(remote), isTrue,
          reason: 'a GSP2 frame mid-GSP1-frame must not close the link');
      expect(received, isEmpty);

      // Write 3: the remainder → the original payload reassembles intact,
      // GSP2 bytes and all.
      port.emitPeerData(remote, frame.sublist(gsp2End));
      await pump();

      expect(registry.contains(remote), isTrue);
      expect(received, hasLength(1));
      expect(received.single.bytes, equals(payload));
    });
  });
}
