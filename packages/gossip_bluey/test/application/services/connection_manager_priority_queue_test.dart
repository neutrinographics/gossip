import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/application/observability/bluey_metrics.dart';
import 'package:gossip_bluey/src/application/services/connection_manager.dart';
import 'package:gossip_bluey/src/domain/aggregates/connection_registry.dart';
import 'package:gossip_bluey/src/domain/value_objects/service_uuid.dart';

import '../../fakes/fake_bluey_port.dart';

/// H1: `ConnectionManager` must give SWIM pings/acks a high-priority lane
/// ahead of bulk gossip and report real queue depth, so the core's
/// per-peer congestion gate (`gossip_engine` `pendingSendCount`) and the
/// failure detector's high-priority pings actually work on BLE.
void main() {
  group('ConnectionManager priority send queue (H1)', () {
    final localId = NodeId('11111111-1111-1111-1111-111111111111');
    final remoteId = NodeId('22222222-2222-2222-2222-222222222222');
    final otherId = NodeId('33333333-3333-3333-3333-333333333333');
    final unknownId = NodeId('99999999-9999-9999-9999-999999999999');
    final serviceUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');

    Future<void> pump([int times = 3]) async {
      for (var i = 0; i < times; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test(
      'pendingSendCount / totalPendingSendCount report messages queued '
      'behind an in-flight send (was hardcoded 0)',
      () async {
        final network = FakeBlueyNetwork();
        final localPort = FakeBlueyPort(localNodeId: localId, network: network);
        final remotePort = FakeBlueyPort(
          localNodeId: remoteId,
          network: network,
        );
        final svc = ConnectionManager(
          port: localPort,
          registry: ConnectionRegistry(),
          metrics: BlueyMetrics(),
          localNodeId: localId,
        );
        await localPort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'Local',
          localNodeId: localId,
        );
        await remotePort.connect(localId);
        await pump();
        expect(svc.registry.contains(remoteId), isTrue);

        // Block all sends so nothing drains until we open the gate.
        final gate = Completer<void>();
        localPort.sendGate = (_, _) => gate.future;

        // Fire three sends without awaiting. The first parks at the gate
        // (dequeued, in-flight); the other two wait in the queue.
        final f1 = svc.sendGossipMessage(remoteId, Uint8List.fromList([1]));
        final f2 = svc.sendGossipMessage(remoteId, Uint8List.fromList([2]));
        final f3 = svc.sendGossipMessage(remoteId, Uint8List.fromList([3]));
        await pump();

        expect(
          svc.pendingSendCount(remoteId),
          equals(2),
          reason: 'two queued behind the one in-flight send',
        );
        expect(svc.totalPendingSendCount, equals(2));
        expect(svc.pendingSendCount(unknownId), equals(0));

        // Open the gate and let everything drain.
        gate.complete();
        await Future.wait([f1, f2, f3]);

        expect(svc.pendingSendCount(remoteId), equals(0));
        expect(svc.totalPendingSendCount, equals(0));

        await svc.dispose();
        await remotePort.dispose();
      },
    );

    test(
      'a high-priority message jumps ahead of queued normal-priority '
      'messages',
      () async {
        final network = FakeBlueyNetwork();
        final localPort = FakeBlueyPort(localNodeId: localId, network: network);
        final remotePort = FakeBlueyPort(
          localNodeId: remoteId,
          network: network,
        );
        final svc = ConnectionManager(
          port: localPort,
          registry: ConnectionRegistry(),
          metrics: BlueyMetrics(),
          localNodeId: localId,
        );
        final remoteSvc = ConnectionManager(
          port: remotePort,
          registry: ConnectionRegistry(),
          metrics: BlueyMetrics(),
          localNodeId: remoteId,
        );
        await localPort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'Local',
          localNodeId: localId,
        );
        await remotePort.connect(localId);
        await pump();

        final received = <List<int>>[];
        final sub = remoteSvc.incomingMessages.listen(
          (m) => received.add(m.bytes),
        );

        final gate = Completer<void>();
        localPort.sendGate = (_, _) => gate.future;

        // A is fired first and parks at the gate (in-flight). Then a
        // normal B and a high-priority H queue up behind it.
        final fa = svc.sendGossipMessage(remoteId, Uint8List.fromList([0xAA]));
        final fb = svc.sendGossipMessage(remoteId, Uint8List.fromList([0xBB]));
        final fh = svc.sendGossipMessage(
          remoteId,
          Uint8List.fromList([0xCC]),
          priority: MessagePriority.high,
        );
        await pump();

        gate.complete();
        await Future.wait([fa, fb, fh]);
        await pump();

        // A already in flight, then H jumps the queued normal B.
        expect(
          received,
          equals([
            [0xAA],
            [0xCC],
            [0xBB],
          ]),
        );

        await sub.cancel();
        await svc.dispose();
        await remoteSvc.dispose();
        await remotePort.dispose();
      },
    );

    test(
      'a send blocked to one peer does not delay sends to another peer '
      '(per-peer queues, not one global queue)',
      () async {
        final network = FakeBlueyNetwork();
        final localPort = FakeBlueyPort(localNodeId: localId, network: network);
        final portA = FakeBlueyPort(localNodeId: remoteId, network: network);
        final portB = FakeBlueyPort(localNodeId: otherId, network: network);
        final svc = ConnectionManager(
          port: localPort,
          registry: ConnectionRegistry(),
          metrics: BlueyMetrics(),
          localNodeId: localId,
        );
        final svcB = ConnectionManager(
          port: portB,
          registry: ConnectionRegistry(),
          metrics: BlueyMetrics(),
          localNodeId: otherId,
        );
        await localPort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'Local',
          localNodeId: localId,
        );
        await portA.connect(localId);
        await portB.connect(localId);
        await pump();
        expect(svc.registry.contains(remoteId), isTrue);
        expect(svc.registry.contains(otherId), isTrue);

        final bReceived = <List<int>>[];
        final sub = svcB.incomingMessages.listen((m) => bReceived.add(m.bytes));

        // Gate blocks only sends destined for peer A.
        final gateA = Completer<void>();
        localPort.sendGate = (target, _) =>
            target == remoteId ? gateA.future : Future<void>.value();

        final fa = svc.sendGossipMessage(remoteId, Uint8List.fromList([0xA1]));
        final fb = svc.sendGossipMessage(otherId, Uint8List.fromList([0xB1]));
        await pump();

        // B flowed through while A is still blocked.
        expect(bReceived, equals([
          [0xB1],
        ]));

        gateA.complete();
        await Future.wait([fa, fb]);

        await sub.cancel();
        await svc.dispose();
        await svcB.dispose();
        await portA.dispose();
        await portB.dispose();
      },
    );

    test(
      'a high-priority message never preempts a multi-chunk message that '
      'is already mid-transmission (whole-message granularity)',
      () async {
        final network = FakeBlueyNetwork();
        final localPort = FakeBlueyPort(localNodeId: localId, network: network);
        final remotePort = FakeBlueyPort(
          localNodeId: remoteId,
          network: network,
        );
        // Small chunks so the normal message spans several frames.
        localPort.chunkSize = 12;
        final svc = ConnectionManager(
          port: localPort,
          registry: ConnectionRegistry(),
          metrics: BlueyMetrics(),
          localNodeId: localId,
        );
        final remoteSvc = ConnectionManager(
          port: remotePort,
          registry: ConnectionRegistry(),
          metrics: BlueyMetrics(),
          localNodeId: remoteId,
        );
        await localPort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'Local',
          localNodeId: localId,
        );
        await remotePort.connect(localId);
        await pump();

        final received = <List<int>>[];
        final sub = remoteSvc.incomingMessages.listen(
          (m) => received.add(m.bytes),
        );

        final gate = Completer<void>();
        localPort.sendGate = (_, _) => gate.future;

        final big = Uint8List.fromList(List.generate(20, (i) => i));
        // N parks mid-chunking; a high-priority H queues behind it.
        final fn = svc.sendGossipMessage(remoteId, big);
        final fh = svc.sendGossipMessage(
          remoteId,
          Uint8List.fromList([0xFF]),
          priority: MessagePriority.high,
        );
        await pump();

        gate.complete();
        await Future.wait([fn, fh]);
        await pump();

        // N is delivered intact and in full before H — H did not slip
        // between N's chunks (which would corrupt the frame stream).
        expect(received, hasLength(2));
        expect(received[0], equals(List.generate(20, (i) => i)));
        expect(received[1], equals([0xFF]));

        await sub.cancel();
        await svc.dispose();
        await remoteSvc.dispose();
        await remotePort.dispose();
      },
    );
  });
}
