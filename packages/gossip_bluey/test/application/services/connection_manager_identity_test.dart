import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/application/observability/bluey_metrics.dart';
import 'package:gossip_bluey/src/application/services/connection_manager.dart';
import 'package:gossip_bluey/src/domain/aggregates/connection_registry.dart';
import 'package:gossip_bluey/src/domain/errors/connection_error.dart';
import 'package:gossip_bluey/src/domain/interfaces/bluey_port.dart';
import 'package:gossip_bluey/src/domain/value_objects/service_uuid.dart';

import '../../fakes/fake_bluey_port.dart';

void main() {
  final localId = NodeId('11111111-1111-1111-1111-111111111111');
  final remoteId = NodeId('22222222-2222-2222-2222-222222222222');
  final thirdId = NodeId('33333333-3333-3333-3333-333333333333');
  final serviceUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');

  group('ConnectionManager cap/duplicate rejection', () {
    test(
      'a duplicate role arriving at maxConnections must not tear down the '
      'active link',
      () async {
        final network = FakeBlueyNetwork();
        final localPort = FakeBlueyPort(localNodeId: localId, network: network);
        final remotePort = FakeBlueyPort(
          localNodeId: remoteId,
          network: network,
        );
        final registry = ConnectionRegistry();
        final svc = ConnectionManager(
          port: localPort,
          registry: registry,
          metrics: BlueyMetrics(),
          maxConnections: 1, // registry is AT cap once remote registers
        );

        await localPort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'Local',
          localNodeId: localId,
        );
        await remotePort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'Remote',
          localNodeId: remoteId,
        );

        // We connect out to remote → registered as central.
        await localPort.connect(remoteId);
        await Future<void>.delayed(Duration.zero);
        expect(registry.get(remoteId)?.role, equals(ConnectionRole.central));

        // Remote simultaneously connected in → duplicate peripheral role
        // for the SAME peer while the registry is at maxConnections.
        await remotePort.connect(localId);
        await Future<void>.delayed(Duration.zero);

        expect(
          registry.get(remoteId)?.role,
          equals(ConnectionRole.central),
          reason: 'the registered link must survive a duplicate at cap',
        );
        expect(
          localPort.disconnectCalls,
          isEmpty,
          reason:
              'role-blind disconnect() prefers the central role and would '
              'tear down the active link',
        );
        expect(
          localPort.disconnectRoleCalls,
          contains((remoteId, ConnectionRole.peripheral)),
          reason: 'only the duplicate role may be rejected',
        );
        expect(
          localPort.connectedAsCentral,
          contains(remoteId),
          reason: 'the physical central link must remain up',
        );

        await svc.dispose();
        await localPort.dispose();
        await remotePort.dispose();
      },
    );

    test(
      'a genuinely new peer rejected at cap is disconnected by role',
      () async {
        final network = FakeBlueyNetwork();
        final localPort = FakeBlueyPort(localNodeId: localId, network: network);
        final remotePort = FakeBlueyPort(
          localNodeId: remoteId,
          network: network,
        );
        final thirdPort = FakeBlueyPort(localNodeId: thirdId, network: network);
        final registry = ConnectionRegistry();
        final errors = <ConnectionError>[];
        final svc = ConnectionManager(
          port: localPort,
          registry: registry,
          metrics: BlueyMetrics(),
          maxConnections: 1,
        );
        svc.errors.listen(errors.add);

        await localPort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'Local',
          localNodeId: localId,
        );
        await localPort.connect(remoteId);
        await Future<void>.delayed(Duration.zero);

        // Third peer connects in over cap (peripheral role).
        await thirdPort.connect(localId);
        await Future<void>.delayed(Duration.zero);

        expect(registry.contains(thirdId), isFalse);
        expect(errors.whereType<ConnectionLimitReachedError>(), isNotEmpty);
        expect(
          localPort.disconnectRoleCalls,
          contains((thirdId, ConnectionRole.peripheral)),
          reason: 'the rejected inbound role must be torn down specifically',
        );
        expect(
          localPort.disconnectCalls,
          isEmpty,
          reason: 'role-blind disconnect risks the wrong link',
        );

        await svc.dispose();
        await localPort.dispose();
        await remotePort.dispose();
        await thirdPort.dispose();
      },
    );
  });

  group('ConnectionManager chunked send vs reconnect', () {
    test(
      'a mid-message reconnect aborts the remaining chunks instead of '
      'corrupting the new link',
      () async {
        final network = FakeBlueyNetwork();
        final localPort = FakeBlueyPort(localNodeId: localId, network: network);
        final remotePort = FakeBlueyPort(
          localNodeId: remoteId,
          network: network,
        );
        final registry = ConnectionRegistry();
        final errors = <ConnectionError>[];
        final svc = ConnectionManager(
          port: localPort,
          registry: registry,
          metrics: BlueyMetrics(),
        );
        svc.errors.listen(errors.add);

        await localPort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'Local',
          localNodeId: localId,
        );
        await localPort.connect(remoteId);
        await Future<void>.delayed(Duration.zero);

        // Force many small chunks so the send spans multiple writes.
        localPort.chunkSize = 16;
        final payload = Uint8List.fromList(List.generate(64, (i) => i));

        // Gate: after the first chunk goes through, hold the second
        // chunk while the connection is replaced (disconnect + fast
        // auto-reconnect).
        var chunkIndex = 0;
        final holdSecondChunk = Completer<void>();
        localPort.sendGate = (target, data) async {
          chunkIndex++;
          if (chunkIndex == 2) {
            await holdSecondChunk.future;
          }
        };

        final send = svc.sendGossipMessage(remoteId, payload);
        await Future<void>.delayed(Duration.zero);

        // Replace the connection while chunk 2 is gated.
        await localPort.disconnect(remoteId);
        await Future<void>.delayed(Duration.zero);
        await localPort.connect(remoteId);
        await Future<void>.delayed(Duration.zero);
        final newHandle = registry.get(remoteId);
        expect(newHandle, isNotNull, reason: 'sanity: reconnected');

        holdSecondChunk.complete();
        await send;
        await Future<void>.delayed(Duration.zero);

        // Chunk 1 landed before the swap; chunk 2 was already in-flight
        // at the platform layer when the swap happened (a GATT write
        // cannot be recalled — the same is true on real hardware).
        // The invariant: NO further chunks (3..5) may be issued after
        // the connection was replaced.
        expect(
          localPort.sentData.length,
          equals(2),
          reason:
              'chunks of the OLD frame must not be written to the NEW '
              'connection — the receiver\'s decoder would lose alignment',
        );
        expect(
          registry.get(remoteId),
          same(newHandle),
          reason: 'the aborted send must not tear down the new connection',
        );
        expect(
          localPort.disconnectCalls.length + localPort.disconnectRoleCalls.length,
          equals(1), // only OUR explicit disconnect() above
          reason: 'no extra teardown from the aborted send path',
        );

        await svc.dispose();
        await localPort.dispose();
        await remotePort.dispose();
      },
    );
  });
}
