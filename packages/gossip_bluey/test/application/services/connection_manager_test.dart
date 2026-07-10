import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/application/observability/bluey_metrics.dart';
import 'package:gossip_bluey/src/application/services/connection_manager.dart';
import 'package:gossip_bluey/src/domain/aggregates/connection_registry.dart';
import 'package:gossip_bluey/src/domain/errors/already_connecting_exception.dart';
import 'package:gossip_bluey/src/domain/errors/connection_error.dart';
import 'package:gossip_bluey/src/domain/errors/connection_rejected_exception.dart';
import 'package:gossip_bluey/src/domain/events/connection_event.dart';
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
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
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
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
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
          port: localPort,
          registry: registry,
          metrics: BlueyMetrics(),
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
          port: localPort,
          registry: ConnectionRegistry(),
          metrics: metrics,
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
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: localMetrics,
      );
      final remoteSvc = ConnectionManager(
        port: remotePort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
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
          port: localPort,
          registry: ConnectionRegistry(),
          metrics: BlueyMetrics(),
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
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
      );
      final remoteSvc = ConnectionManager(
        port: remotePort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
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
          port: localPort,
          registry: ConnectionRegistry(),
          metrics: BlueyMetrics(),
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

    test(
      'a hung port.sendData times out instead of wedging the peer\'s '
      'drain loop (COR3-22)',
      () async {
        final network = FakeBlueyNetwork();
        final localPort = FakeBlueyPort(localNodeId: localId, network: network);
        final remotePort = FakeBlueyPort(
          localNodeId: remoteId,
          network: network,
        );
        final otherId = NodeId('33333333-3333-3333-3333-333333333333');
        final otherPort = FakeBlueyPort(localNodeId: otherId, network: network);
        final otherSvc = ConnectionManager(
          port: otherPort,
          registry: ConnectionRegistry(),
          metrics: BlueyMetrics(),
        );
        final errs = <ConnectionError>[];
        final svc = ConnectionManager(
          port: localPort,
          registry: ConnectionRegistry(),
          metrics: BlueyMetrics(),
          sendTimeout: const Duration(milliseconds: 50),
        );
        final errSub = svc.errors.listen(errs.add);

        await localPort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'Local',
          localNodeId: localId,
        );
        await remotePort.connect(localId);
        await otherPort.connect(localId);
        await Future<void>.delayed(Duration.zero);
        expect(svc.registry.contains(remoteId), isTrue);
        expect(svc.registry.contains(otherId), isTrue);

        // Writes to the remote peer hang forever (dead GATT link the
        // state watcher never noticed); writes to the other peer flow.
        localPort.sendGate = (target, _) => target == remoteId
            ? Completer<void>().future
            : Future<void>.value();

        // Two sends to the hung peer: the first parks at the gate, the
        // second queues behind it and can only ever drain if the first
        // times out. Completion semantics of a failed send are pinned by
        // the COR3-20 tests; here we only care that both complete.
        final hung = svc
            .sendGossipMessage(remoteId, Uint8List.fromList([1]))
            .then((_) {}, onError: (_) {});
        final queued = svc
            .sendGossipMessage(remoteId, Uint8List.fromList([2]))
            .then((_) {}, onError: (_) {});
        await Future.wait([hung, queued]).timeout(
          const Duration(seconds: 2),
          onTimeout: () => fail(
            'drain loop wedged: a hung sendData never times out',
          ),
        );

        expect(errs.whereType<SendFailedError>(), isNotEmpty);
        expect(
          errs.whereType<SendFailedError>().first.cause,
          isA<TimeoutException>(),
        );

        // Sends to the other peer still proceed.
        final received = <IncomingMessage>[];
        final sub = otherSvc.incomingMessages.listen(received.add);
        await svc
            .sendGossipMessage(otherId, Uint8List.fromList([9]))
            .timeout(const Duration(seconds: 1));
        await Future<void>.delayed(Duration.zero);
        expect(received, hasLength(1));

        await sub.cancel();
        await errSub.cancel();
        await svc.dispose();
        await otherSvc.dispose();
        await remotePort.dispose();
        await otherPort.dispose();
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
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
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

    test('disconnect delegates to the port', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);
      final svc = ConnectionManager(
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
      );

      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Local',
        localNodeId: localId,
      );
      await remotePort.connect(localId);
      await Future<void>.delayed(Duration.zero);
      expect(svc.registry.contains(remoteId), isTrue);

      await svc.disconnect(remoteId);
      await Future<void>.delayed(Duration.zero);

      expect(svc.registry.contains(remoteId), isFalse);
      expect(svc.registry.connectionCount, equals(0));

      await svc.dispose();
      await remotePort.dispose();
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
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
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

    group('COR3-20: failed sends complete with an error', () {
      test(
        'a send whose chunk write throws completes its future with that '
        'error (and still emits SendFailedError)',
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
          final errs = <ConnectionError>[];
          final svc = ConnectionManager(
            port: localPort,
            registry: ConnectionRegistry(),
            metrics: BlueyMetrics(),
          );
          final errSub = svc.errors.listen(errs.add);
          await localPort.startAdvertising(
            serviceUuid: serviceUuid,
            displayName: 'Local',
            localNodeId: localId,
          );
          await remotePort.connect(localId);
          await Future<void>.delayed(Duration.zero);

          localPort.sendGate = (_, _) async {
            throw StateError('GATT write failed');
          };

          await expectLater(
            svc.sendGossipMessage(remoteId, Uint8List.fromList([1])),
            throwsA(isA<StateError>()),
            reason:
                'completing a known-failed send as success defeats the '
                'core engine\'s pending-request rollback',
          );
          expect(errs.whereType<SendFailedError>(), isNotEmpty);

          await errSub.cancel();
          await svc.dispose();
          await remotePort.dispose();
        },
      );

      test(
        'a send queued behind a disconnect completes with an error',
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
          final svc = ConnectionManager(
            port: localPort,
            registry: ConnectionRegistry(),
            metrics: BlueyMetrics(),
          );
          await localPort.startAdvertising(
            serviceUuid: serviceUuid,
            displayName: 'Local',
            localNodeId: localId,
          );
          await remotePort.connect(localId);
          await Future<void>.delayed(Duration.zero);

          // The first send parks at the gate (in-flight); the second
          // waits in the queue.
          final gate = Completer<void>();
          localPort.sendGate = (_, _) => gate.future;
          final first = svc.sendGossipMessage(
            remoteId,
            Uint8List.fromList([1]),
          );
          // Attach expectations immediately so the errors are observed
          // the moment they fire.
          final firstExpect = expectLater(first, throwsA(isA<StateError>()));
          final second = svc.sendGossipMessage(
            remoteId,
            Uint8List.fromList([2]),
          );
          final secondExpect = expectLater(
            second,
            throwsA(isA<ConnectionNotFoundError>()),
            reason: 'connection gone at dequeue is a known-failed send',
          );
          await Future<void>.delayed(Duration.zero);

          // Peer drops while both sends are pending.
          await remotePort.disconnect(localId);
          await Future<void>.delayed(Duration.zero);
          gate.complete();

          await firstExpect;
          await secondExpect;

          await svc.dispose();
          await remotePort.dispose();
        },
      );

      test(
        'dispose completes still-queued sends with an error, not success',
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
          final svc = ConnectionManager(
            port: localPort,
            registry: ConnectionRegistry(),
            metrics: BlueyMetrics(),
            // Bounds the in-flight (gated) send so the test ends promptly.
            sendTimeout: const Duration(milliseconds: 50),
          );
          await localPort.startAdvertising(
            serviceUuid: serviceUuid,
            displayName: 'Local',
            localNodeId: localId,
          );
          await remotePort.connect(localId);
          await Future<void>.delayed(Duration.zero);

          final gate = Completer<void>();
          localPort.sendGate = (_, _) => gate.future;
          final inFlight = svc.sendGossipMessage(
            remoteId,
            Uint8List.fromList([1]),
          );
          final inFlightExpect = expectLater(
            inFlight,
            throwsA(isA<TimeoutException>()),
            reason: 'the in-flight send is resolved by its own drain loop',
          );
          final queued = svc.sendGossipMessage(
            remoteId,
            Uint8List.fromList([2]),
          );
          final queuedExpect = expectLater(
            queued,
            throwsA(
              isA<SendFailedError>().having(
                (e) => e.message,
                'message',
                contains('transport disposed'),
              ),
            ),
          );
          await Future<void>.delayed(Duration.zero);

          await svc.dispose();

          await queuedExpect;
          await inFlightExpect;

          await remotePort.dispose();
        },
      );
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
          port: localPort,
          registry: ConnectionRegistry(),
          metrics: BlueyMetrics(),
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
        'reentrant connectTo for the same address throws '
        'AlreadyConnectingException',
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
            port: localPort,
            registry: ConnectionRegistry(),
            metrics: BlueyMetrics(),
          );

          final candidate = ScanCandidate(
            address: BleAddress(remoteId.value),
            displayName: 'Remote',
            lastSeen: _t0,
          );
          final f1 = svc.connectTo(candidate);
          expect(
            () => svc.connectTo(candidate),
            throwsA(isA<AlreadyConnectingException>()),
          );

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
            port: localPort,
            registry: ConnectionRegistry(),
            metrics: BlueyMetrics(),
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
        'connectTo throws ConnectionRejectedException when the connection '
        'was cap-rejected (COR3-6)',
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
          final thirdId = NodeId('33333333-3333-3333-3333-333333333333');
          final thirdPort = FakeBlueyPort(
            localNodeId: thirdId,
            network: network,
          );
          await remotePort.startAdvertising(
            serviceUuid: serviceUuid,
            displayName: 'Remote',
            localNodeId: remoteId,
          );
          await thirdPort.startAdvertising(
            serviceUuid: serviceUuid,
            displayName: 'Third',
            localNodeId: thirdId,
          );
          final registry = ConnectionRegistry();
          final svc = ConnectionManager(
            port: localPort,
            registry: registry,
            metrics: BlueyMetrics(),
            maxConnections: 1,
          );

          // Fill the single slot.
          await svc.connectTo(
            ScanCandidate(
              address: BleAddress(remoteId.value),
              displayName: 'Remote',
              lastSeen: _t0,
            ),
          );
          expect(registry.contains(remoteId), isTrue);

          // The GATT connect + identification succeeds, but registration
          // is cap-rejected — success here means the caller holds a
          // NodeId it can never send to.
          await expectLater(
            svc.connectTo(
              ScanCandidate(
                address: BleAddress(thirdId.value),
                displayName: 'Third',
                lastSeen: _t0,
              ),
            ),
            throwsA(isA<ConnectionRejectedException>()),
          );
          expect(registry.contains(thirdId), isFalse);

          await svc.dispose();
          await remotePort.dispose();
          await thirdPort.dispose();
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
            port: localPort,
            registry: ConnectionRegistry(),
            metrics: BlueyMetrics(),
          );

          final candidate = ScanCandidate(
            address: BleAddress(remoteId.value),
            displayName: 'Remote',
            lastSeen: _t0,
          );
          await expectLater(
            svc.connectTo(candidate),
            throwsA(isA<Exception>()),
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
