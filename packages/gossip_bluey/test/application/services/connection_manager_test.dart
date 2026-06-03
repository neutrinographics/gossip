import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/application/observability/bluey_metrics.dart';
import 'package:gossip_bluey/src/application/services/connection_manager.dart';
import 'package:gossip_bluey/src/domain/aggregates/connection_registry.dart';
import 'package:gossip_bluey/src/domain/errors/connection_error.dart';
import 'package:gossip_bluey/src/domain/events/connection_event.dart';
// ignore: unused_import
import 'package:gossip_bluey/src/domain/interfaces/bluey_port.dart';
import 'package:gossip_bluey/src/domain/value_objects/ble_address.dart';
import 'package:gossip_bluey/src/domain/value_objects/scan_candidate.dart';
import 'package:gossip_bluey/src/domain/value_objects/service_uuid.dart';
import 'package:gossip_bluey/src/infrastructure/codec/frame_codec.dart';
import '../../fakes/fake_bluey_port.dart';

final _t0 = DateTime.utc(2026, 1, 1);

void main() {
  group('ConnectionManager', () {
    final localId = NodeId('11111111-1111-1111-1111-111111111111');
    final remoteId = NodeId('22222222-2222-2222-2222-222222222222');
    final serviceUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');

    test('emits PeerOpened on PortPeerConnected (peripheral role)', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);
      final svc = ConnectionManager(
        localNodeId: localId,
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );
      final events = <ConnectionEvent>[];
      final sub = svc.events.listen(events.add);

      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Local',
        localNodeId: localId,
      );
      await remotePort.connect(localId);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.first, isA<PeerOpened>());
      expect((events.first as PeerOpened).nodeId, equals(remoteId));

      await sub.cancel();
      await svc.dispose();
      await remotePort.dispose();
    });

    test('emits PeerClosed on PortPeerDisconnected', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);
      final svc = ConnectionManager(
        localNodeId: localId,
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );
      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Local',
        localNodeId: localId,
      );
      await remotePort.connect(localId);
      await Future<void>.delayed(Duration.zero);
      final events = <ConnectionEvent>[];
      final sub = svc.events.listen(events.add);

      await remotePort.disconnect(localId);
      await Future<void>.delayed(Duration.zero);

      final closed = events.whereType<PeerClosed>().toList();
      expect(closed, hasLength(1));
      expect(closed.first.nodeId, equals(remoteId));
      expect(svc.registry.connectionCount, equals(0));

      await sub.cancel();
      await svc.dispose();
      await remotePort.dispose();
    });

    test(
      'PortPeerConnected for already-registered NodeId triggers '
      'disconnectRole on the just-arrived role; existing handle untouched',
      () async {
        final network = FakeBlueyNetwork();
        final localPort = FakeBlueyPort(localNodeId: localId, network: network);
        final remotePort = FakeBlueyPort(
          localNodeId: remoteId,
          network: network,
        );
        final registry = ConnectionRegistry();
        final svc = ConnectionManager(
          localNodeId: localId,
          port: localPort,
          registry: registry,
          metrics: BlueyMetrics(),
          serviceUuid: serviceUuid,
        );

        await localPort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'Local',
          localNodeId: localId,
        );

        // First: peer connects to us → registry stores remoteId as peripheral.
        await remotePort.connect(localId);
        await Future<void>.delayed(Duration.zero);
        expect(registry.contains(remoteId), isTrue);
        expect(registry.get(remoteId)!.role, equals(ConnectionRole.peripheral));

        // Now we initiate to the same peer → duplicate central connection.
        await localPort.connect(remoteId);
        await Future<void>.delayed(Duration.zero);

        expect(
          registry.contains(remoteId),
          isTrue,
          reason:
              'peripheral handle should remain after duplicate central drop',
        );
        expect(
          localPort.connectedAsCentral,
          isNot(contains(remoteId)),
          reason: 'duplicate central connection should have been disconnected',
        );

        await svc.dispose();
        await remotePort.dispose();
      },
    );

    test(
      'frame recovery: PortPeerData with corrupted bytes does not disconnect '
      'and increments BlueyMetrics.frameRecoveries',
      () async {
        final network = FakeBlueyNetwork();
        final localPort = FakeBlueyPort(localNodeId: localId, network: network);
        final remotePort = FakeBlueyPort(
          localNodeId: remoteId,
          network: network,
        );
        final metrics = BlueyMetrics();
        final logs = <String>[];
        final svc = ConnectionManager(
          localNodeId: localId,
          port: localPort,
          registry: ConnectionRegistry(),
          metrics: metrics,
          serviceUuid: serviceUuid,
          onLog: (level, msg, [e, st]) {
            if (level == LogLevel.warning) logs.add(msg);
          },
        );

        await localPort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'Local',
          localNodeId: localId,
        );
        await remotePort.connect(localId);
        await Future<void>.delayed(Duration.zero);
        expect(svc.registry.contains(remoteId), isTrue);

        const magic = [0x47, 0x53, 0x50, 0x31];
        final payload = [0xAA, 0xBB, 0xCC];
        final corruptedThenValid = Uint8List.fromList([
          0xDE, 0xAD, 0xBE, 0xEF, 0x12, 0x34, 0x56, // 7 garbage
          ...magic,
          0x00, 0x00, 0x00, payload.length,
          ...payload,
        ]);

        await remotePort.sendData(localId, corruptedThenValid);
        await Future<void>.delayed(Duration.zero);

        expect(svc.registry.contains(remoteId), isTrue);
        expect(metrics.frameRecoveries, equals(1));
        expect(metrics.bytesDiscarded, equals(7));
        expect(logs, isNotEmpty);
        expect(logs.first, contains('discarded 7 bytes'));

        await svc.dispose();
        await remotePort.dispose();
      },
    );

    test('sustained traffic with one dropped chunk: connection persists, '
        'metric records the recovery, subsequent messages flow', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);
      final localMetrics = BlueyMetrics();
      final localSvc = ConnectionManager(
        localNodeId: localId,
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: localMetrics,
        serviceUuid: serviceUuid,
      );
      final remoteSvc = ConnectionManager(
        localNodeId: remoteId,
        port: remotePort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );

      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Local',
        localNodeId: localId,
      );
      await remotePort.connect(localId);
      await Future<void>.delayed(Duration.zero);

      remotePort.chunkSize = 12; // 8-byte header + 4 bytes payload per chunk

      final incoming = <IncomingMessage>[];
      final sub = localSvc.incomingMessages.listen(incoming.add);

      var dropsRemaining = 1;
      remotePort.chunkDropInjector = (_, _) {
        if (dropsRemaining > 0) {
          dropsRemaining--;
          return true;
        }
        return false;
      };

      await remoteSvc.sendGossipMessage(
        localId,
        Uint8List.fromList(List.generate(20, (i) => i)),
      );
      await remoteSvc.sendGossipMessage(
        localId,
        Uint8List.fromList([0xCA, 0xFE, 0xBA, 0xBE]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(localSvc.registry.contains(remoteId), isTrue);
      expect(incoming, isNotEmpty);
      expect(incoming.last.bytes, equals([0xCA, 0xFE, 0xBA, 0xBE]));
      expect(localMetrics.frameRecoveries, greaterThanOrEqualTo(1));
      expect(localMetrics.bytesDiscarded, greaterThan(0));

      await sub.cancel();
      await localSvc.dispose();
      await remoteSvc.dispose();
      await remotePort.dispose();
    });

    test(
      'PortPeerData feeds the FrameDecoder and emits IncomingMessage',
      () async {
        final network = FakeBlueyNetwork();
        final localPort = FakeBlueyPort(localNodeId: localId, network: network);
        final remotePort = FakeBlueyPort(
          localNodeId: remoteId,
          network: network,
        );
        final svc = ConnectionManager(
          localNodeId: localId,
          port: localPort,
          registry: ConnectionRegistry(),
          metrics: BlueyMetrics(),
          serviceUuid: serviceUuid,
        );
        await localPort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'Local',
          localNodeId: localId,
        );
        await remotePort.connect(localId);
        await Future<void>.delayed(Duration.zero);

        final received = <IncomingMessage>[];
        final sub = svc.incomingMessages.listen(received.add);

        final payload = Uint8List.fromList([10, 20, 30]);
        final chunks = FrameEncoder.encode(payload, mtuPayloadSize: 100);
        for (final c in chunks) {
          await remotePort.sendData(localId, c);
        }
        await Future<void>.delayed(Duration.zero);

        expect(received, hasLength(1));
        expect(received.first.sender, equals(remoteId));
        expect(received.first.bytes, equals(payload));

        await sub.cancel();
        await svc.dispose();
        await remotePort.dispose();
      },
    );

    test('sendGossipMessage encodes and writes chunks to the port', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);

      final svc = ConnectionManager(
        localNodeId: localId,
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );
      final remoteSvc = ConnectionManager(
        localNodeId: remoteId,
        port: remotePort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );

      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Local',
        localNodeId: localId,
      );
      await remotePort.connect(localId);
      await Future<void>.delayed(Duration.zero);

      final received = <IncomingMessage>[];
      final sub = remoteSvc.incomingMessages.listen(received.add);

      final payload = Uint8List.fromList(List.generate(50, (i) => i));
      await svc.sendGossipMessage(remoteId, payload);
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(received.first.bytes, equals(payload));

      await sub.cancel();
      await svc.dispose();
      await remoteSvc.dispose();
      await remotePort.dispose();
    });

    test(
      'sendGossipMessage emits ConnectionNotFoundError for unknown peer',
      () async {
        final network = FakeBlueyNetwork();
        final localPort = FakeBlueyPort(localNodeId: localId, network: network);
        final svc = ConnectionManager(
          localNodeId: localId,
          port: localPort,
          registry: ConnectionRegistry(),
          metrics: BlueyMetrics(),
          serviceUuid: serviceUuid,
        );

        final errs = <ConnectionError>[];
        final sub = svc.errors.listen(errs.add);

        await svc.sendGossipMessage(
          remoteId,
          Uint8List.fromList([1, 2, 3]),
        );
        await Future<void>.delayed(Duration.zero);

        expect(errs, hasLength(1));
        expect(errs.first, isA<ConnectionNotFoundError>());
        expect(
          (errs.first as ConnectionNotFoundError).nodeId,
          equals(remoteId),
        );

        await sub.cancel();
        await svc.dispose();
      },
    );

    test('responder disconnects extra inbound past maxConnections', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final r2 = FakeBlueyPort(
        localNodeId: NodeId('33333333-3333-3333-3333-333333333333'),
        network: network,
      );
      final r3 = FakeBlueyPort(
        localNodeId: NodeId('44444444-4444-4444-4444-444444444444'),
        network: network,
      );

      final svc = ConnectionManager(
        localNodeId: localId,
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
        maxConnections: 1,
      );
      final errs = <ConnectionError>[];
      final sub = svc.errors.listen(errs.add);
      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Local',
        localNodeId: localId,
      );

      await r2.connect(localId);
      await Future<void>.delayed(Duration.zero);
      await r3.connect(localId);
      await Future<void>.delayed(Duration.zero);

      expect(svc.registry.connectionCount, equals(1));
      expect(errs.whereType<ConnectionLimitReachedError>(), isNotEmpty);

      await sub.cancel();
      await svc.dispose();
      await r2.dispose();
      await r3.dispose();
    });

    test('disconnectAll calls port.disconnect for every active peer', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final r2id = NodeId('33333333-3333-3333-3333-333333333333');
      final r2 = FakeBlueyPort(localNodeId: r2id, network: network);
      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'L',
        localNodeId: localId,
      );
      final svc = ConnectionManager(
        localNodeId: localId,
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );
      await r2.connect(localId);
      await Future<void>.delayed(Duration.zero);
      expect(svc.registry.connectionCount, equals(1));

      await svc.disconnectAll();
      await Future<void>.delayed(Duration.zero);

      expect(svc.registry.connectionCount, equals(0));

      await svc.dispose();
      await r2.dispose();
    });

    group('connectTo', () {
      test('returns NodeId from port.connectAndIdentify (happy path)', () async {
        final network = FakeBlueyNetwork();
        final localPort = FakeBlueyPort(localNodeId: localId, network: network);
        final remotePort = FakeBlueyPort(
          localNodeId: remoteId,
          network: network,
        );
        // Remote must be advertising so the fake's connectAndIdentify
        // can resolve it via the network.
        await remotePort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'Remote',
          localNodeId: remoteId,
        );
        final svc = ConnectionManager(
          localNodeId: localId,
          port: localPort,
          registry: ConnectionRegistry(),
          metrics: BlueyMetrics(),
          serviceUuid: serviceUuid,
        );

        final candidate = ScanCandidate(
          address: BleAddress(remoteId.value),
          displayName: 'Remote',
          lastSeen: _t0,
        );
        final id = await svc.connectTo(candidate);
        expect(id, equals(remoteId));

        await svc.dispose();
        await remotePort.dispose();
      });

      test(
        'reentrant connectTo for the same address throws StateError',
        () async {
          final network = FakeBlueyNetwork();
          final localPort = FakeBlueyPort(
            localNodeId: localId,
            network: network,
          );
          final remotePort = FakeBlueyPort(
            localNodeId: remoteId,
            network: network,
          );
          await remotePort.startAdvertising(
            serviceUuid: serviceUuid,
            displayName: 'Remote',
            localNodeId: remoteId,
          );
          // Slow connectAndIdentify so the second call is in flight while
          // the first hasn't yet resolved.
          localPort.connectAndIdentifyDelay = const Duration(milliseconds: 50);

          final svc = ConnectionManager(
            localNodeId: localId,
            port: localPort,
            registry: ConnectionRegistry(),
            metrics: BlueyMetrics(),
            serviceUuid: serviceUuid,
          );

          final candidate = ScanCandidate(
            address: BleAddress(remoteId.value),
            displayName: 'Remote',
            lastSeen: _t0,
          );
          final f1 = svc.connectTo(candidate);
          expect(() => svc.connectTo(candidate), throwsStateError);

          // Drain the first call to clean up.
          await f1;

          await svc.dispose();
          await remotePort.dispose();
        },
      );

      test(
        'after connectTo succeeds, the address becomes connectable again',
        () async {
          final network = FakeBlueyNetwork();
          final localPort = FakeBlueyPort(
            localNodeId: localId,
            network: network,
          );
          final remotePort = FakeBlueyPort(
            localNodeId: remoteId,
            network: network,
          );
          await remotePort.startAdvertising(
            serviceUuid: serviceUuid,
            displayName: 'Remote',
            localNodeId: remoteId,
          );
          final svc = ConnectionManager(
            localNodeId: localId,
            port: localPort,
            registry: ConnectionRegistry(),
            metrics: BlueyMetrics(),
            serviceUuid: serviceUuid,
          );

          final candidate = ScanCandidate(
            address: BleAddress(remoteId.value),
            displayName: 'Remote',
            lastSeen: _t0,
          );
          await svc.connectTo(candidate);
          // Second call must not throw.
          await svc.connectTo(candidate);

          await svc.dispose();
          await remotePort.dispose();
        },
      );

      test(
        'after connectTo fails, the address becomes connectable again',
        () async {
          final network = FakeBlueyNetwork();
          final localPort = FakeBlueyPort(
            localNodeId: localId,
            network: network,
          );
          final remotePort = FakeBlueyPort(
            localNodeId: remoteId,
            network: network,
          );
          await remotePort.startAdvertising(
            serviceUuid: serviceUuid,
            displayName: 'Remote',
            localNodeId: remoteId,
          );

          var failOnce = true;
          localPort.connectAndIdentifyFailureInjector = (_) {
            if (failOnce) {
              failOnce = false;
              return true;
            }
            return false;
          };

          final svc = ConnectionManager(
            localNodeId: localId,
            port: localPort,
            registry: ConnectionRegistry(),
            metrics: BlueyMetrics(),
            serviceUuid: serviceUuid,
          );

          final candidate = ScanCandidate(
            address: BleAddress(remoteId.value),
            displayName: 'Remote',
            lastSeen: _t0,
          );
          await expectLater(
            svc.connectTo(candidate),
            throwsA(isA<StateError>()),
          );
          // Reentrancy guard must have been released; a follow-up call
          // for the same address should be allowed (and succeed now that
          // the injector returns false).
          final id = await svc.connectTo(candidate);
          expect(id, equals(remoteId));

          await svc.dispose();
          await remotePort.dispose();
        },
      );
    });
  });
}
