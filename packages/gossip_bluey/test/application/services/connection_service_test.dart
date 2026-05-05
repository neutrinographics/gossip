import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/application/observability/bluey_metrics.dart';
import 'package:gossip_bluey/src/application/services/connection_service.dart';
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

class _ManualClock extends Clock {
  _ManualClock(this._now);
  DateTime _now;
  @override
  DateTime now() => _now;
  void advance(Duration d) => _now = _now.add(d);
}

void main() {
  group('ConnectionService', () {
    final localId = NodeId('11111111-1111-1111-1111-111111111111');
    final remoteId = NodeId('22222222-2222-2222-2222-222222222222');
    final serviceUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');

    test('emits PeerOpened on PortPeerConnected (peripheral role)', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);
      final svc = ConnectionService(
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
      final svc = ConnectionService(
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
        final svc = ConnectionService(
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
        // The fake fires PortPeerConnected(remoteId, central) on local; the
        // service should detect the duplicate via tryRegister and call
        // disconnectRole(remoteId, central), which (via the fake) tears
        // down the link. The peripheral handle stays.
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

    test('inbound peripheral registration writes address cache; '
        'subsequent scan emission for that address is silenced', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);
      final registry = ConnectionRegistry();
      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: registry,
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );

      var connectAndIdentifyCalls = 0;
      localPort.onConnectAndIdentify = (_) => connectAndIdentifyCalls++;

      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Local',
        localNodeId: localId,
      );

      // Remote connects to us as central — we are peripheral.
      await remotePort.connect(localId);
      await Future<void>.delayed(Duration.zero);
      expect(registry.contains(remoteId), isTrue);

      // Now we start discovery. The fake's scanForCandidates emits
      // candidates for advertising peers; remote is advertising too.
      // Without the dedup fix, _onCandidate would call
      // connectAndIdentify (driving the iOS CoreBluetooth peer-merge
      // bug in production). With the fix, the address cache silences
      // it because the inbound peripheral event populated the cache.
      await remotePort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Remote',
        localNodeId: remoteId,
      );
      await svc.startDiscovery();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(
        connectAndIdentifyCalls,
        equals(0),
        reason:
            'inbound peripheral should populate address cache so the '
            'subsequent scan emission for the same address is silenced',
      );

      await svc.dispose();
      await remotePort.dispose();
    });

    test('after peripheral disconnect, scan emission re-enables connect '
        '(cache is stale but registry gate opens)', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);
      final registry = ConnectionRegistry();
      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: registry,
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );

      var connectAndIdentifyCalls = 0;
      localPort.onConnectAndIdentify = (_) => connectAndIdentifyCalls++;

      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Local',
        localNodeId: localId,
      );

      // Inbound peripheral registration populates the cache.
      await remotePort.connect(localId);
      await Future<void>.delayed(Duration.zero);
      expect(registry.contains(remoteId), isTrue);

      // Remote disconnects — registry empties.
      await remotePort.disconnect(localId);
      await Future<void>.delayed(Duration.zero);
      expect(registry.contains(remoteId), isFalse);

      // The cache still has remote's address, but registry no longer
      // contains the NodeId — _onCandidate's gate
      // (`knownNode != null && registry.contains(knownNode)`) opens
      // because the registry side is false. connectAndIdentify must
      // fire on the next scan emission.
      await remotePort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Remote',
        localNodeId: remoteId,
      );
      await svc.startDiscovery();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(connectAndIdentifyCalls, greaterThanOrEqualTo(1));
      expect(registry.contains(remoteId), isTrue);

      await svc.dispose();
      await remotePort.dispose();
    });

    test('bidirectional discovery converges to one handle per pair '
        '(no reconnect loop)', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);
      final localRegistry = ConnectionRegistry();
      final remoteRegistry = ConnectionRegistry();

      final localSvc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: localRegistry,
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );
      final remoteSvc = ConnectionService(
        localNodeId: remoteId,
        port: remotePort,
        registry: remoteRegistry,
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );

      var localConnectCalls = 0;
      var remoteConnectCalls = 0;
      localPort.onConnectAndIdentify = (_) => localConnectCalls++;
      remotePort.onConnectAndIdentify = (_) => remoteConnectCalls++;

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

      // Both sides start discovery simultaneously.
      await localSvc.startDiscovery();
      await remoteSvc.startDiscovery();

      // Wait several rebroadcast cycles. With the dedup fix, the
      // system should settle quickly: one side wins the connect race,
      // the other side dedups subsequent scan emissions.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(localRegistry.contains(remoteId), isTrue);
      expect(remoteRegistry.contains(localId), isTrue);
      expect(localRegistry.connectionCount, equals(1));
      expect(remoteRegistry.connectionCount, equals(1));

      // Without dedup, we'd see double-digit counts as both sides
      // racy-reconnect. With dedup, expect at most a handful (one per
      // side worst case if both attempt simultaneously before either
      // has registered).
      expect(
        localConnectCalls + remoteConnectCalls,
        lessThan(5),
        reason: 'no infinite reconnect loop',
      );

      await localSvc.dispose();
      await remoteSvc.dispose();
    });

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
        final svc = ConnectionService(
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

        // Inject 7 bytes of garbage followed by a valid frame for a
        // 3-byte payload. The decoder should discard the garbage,
        // emit the message, and the service should record the
        // recovery.
        const magic = [0x47, 0x53, 0x50, 0x31];
        final payload = [0xAA, 0xBB, 0xCC];
        final corruptedThenValid = Uint8List.fromList([
          0xDE, 0xAD, 0xBE, 0xEF, 0x12, 0x34, 0x56, // 7 garbage
          ...magic,
          0x00, 0x00, 0x00, payload.length,
          ...payload,
        ]);

        // Use the fake's sendData to deliver these bytes onto local's
        // PortPeerData stream.
        await remotePort.sendData(localId, corruptedThenValid);
        await Future<void>.delayed(Duration.zero);

        // Connection still up.
        expect(svc.registry.contains(remoteId), isTrue);
        // Recovery metric incremented with the right count.
        expect(metrics.frameRecoveries, equals(1));
        expect(metrics.bytesDiscarded, equals(7));
        // A warning was logged.
        expect(logs, isNotEmpty);
        expect(logs.first, contains('discarded 7 bytes'));

        await svc.dispose();
        await remotePort.dispose();
      },
    );

    test(
      'sustained traffic with one dropped chunk: connection persists, '
      'metric records the recovery, subsequent messages flow',
      () async {
        final network = FakeBlueyNetwork();
        final localPort = FakeBlueyPort(localNodeId: localId, network: network);
        final remotePort = FakeBlueyPort(
          localNodeId: remoteId,
          network: network,
        );
        final localMetrics = BlueyMetrics();
        final localSvc = ConnectionService(
          localNodeId: localId,
          port: localPort,
          registry: ConnectionRegistry(),
          metrics: localMetrics,
          serviceUuid: serviceUuid,
        );
        final remoteSvc = ConnectionService(
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

        // Set the fake's per-write payload size deliberately small so a
        // single message gets chunked across multiple writes — and we
        // can drop one of them mid-message.
        remotePort.chunkSize = 12; // 8-byte header + 4 bytes payload per chunk

        // Capture incoming messages on the local side.
        final incoming = <IncomingMessage>[];
        final sub = localSvc.incomingMessages.listen(incoming.add);

        // Drop the first sendData chunk from remote → local for any
        // payload we send while the injector is enabled. After one drop,
        // disable.
        var dropsRemaining = 1;
        remotePort.chunkDropInjector = (_, __) {
          if (dropsRemaining > 0) {
            dropsRemaining--;
            return true;
          }
          return false;
        };

        // Send message 1 — its first chunk gets dropped, so the rest of
        // its bytes will look like garbage (or the next frame's magic
        // never arrives) to local's decoder.
        await remoteSvc.sendGossipMessage(
          localId,
          Uint8List.fromList(List.generate(20, (i) => i)),
        );
        // Send message 2 — chunks are intact; the decoder should
        // discard the leftover misaligned bytes from message 1, find
        // message 2's magic, and emit it.
        await remoteSvc.sendGossipMessage(
          localId,
          Uint8List.fromList([0xCA, 0xFE, 0xBA, 0xBE]),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // Connection still up.
        expect(localSvc.registry.contains(remoteId), isTrue);
        // Message 2 was emitted (possibly preceded by a bogus message
        // synthesized from the corrupted bytes — we accept that as the
        // cost of length-prefix corruption with plausible-but-wrong
        // length values; the key property is recovery).
        expect(incoming, isNotEmpty);
        expect(incoming.last.bytes, equals([0xCA, 0xFE, 0xBA, 0xBE]));
        // Recovery was recorded.
        expect(localMetrics.frameRecoveries, greaterThanOrEqualTo(1));
        expect(localMetrics.bytesDiscarded, greaterThan(0));

        await sub.cancel();
        await localSvc.dispose();
        await remoteSvc.dispose();
        await remotePort.dispose();
      },
    );

    test(
      'scan emission → connectAndIdentify → peer registered (happy path)',
      () async {
        final network = FakeBlueyNetwork();
        final localPort = FakeBlueyPort(localNodeId: localId, network: network);
        final remotePort = FakeBlueyPort(
          localNodeId: remoteId,
          network: network,
        );
        final registry = ConnectionRegistry();
        final svc = ConnectionService(
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
        await remotePort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'Remote',
          localNodeId: remoteId,
        );

        await svc.startDiscovery();
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(registry.contains(remoteId), isTrue);
        expect(registry.get(remoteId)!.role, equals(ConnectionRole.central));

        await svc.dispose();
        await remotePort.dispose();
      },
    );

    test('in-flight guard: same address emitted twice → connectAndIdentify '
        'invoked once', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);
      final registry = ConnectionRegistry();
      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: registry,
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );

      // Slow connectAndIdentify so the second emission lands while the
      // first is still in-flight.
      var calls = 0;
      localPort.connectAndIdentifyDelay = const Duration(milliseconds: 50);
      localPort.onConnectAndIdentify = (_) => calls++;

      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'L',
        localNodeId: localId,
      );
      await remotePort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'R',
        localNodeId: remoteId,
      );

      await svc.startDiscovery();
      // Two back-to-back emissions for the same address.
      final candidate = ScanCandidate(
        address: BleAddress(remoteId.value),
        displayName: 'R',
      );
      localPort.emitScanCandidate(candidate);
      localPort.emitScanCandidate(candidate);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // The fake's rebroadcast timer also seeds initial candidates in
      // the microtask, so we may see one or two calls depending on
      // timing — the assertion is "no extra call from the immediate
      // duplicate emission".
      expect(calls, lessThanOrEqualTo(1));

      await svc.dispose();
      await remotePort.dispose();
    });

    test(
      'address cache silences re-emission while peer remains connected',
      () async {
        final network = FakeBlueyNetwork();
        final localPort = FakeBlueyPort(localNodeId: localId, network: network);
        final remotePort = FakeBlueyPort(
          localNodeId: remoteId,
          network: network,
        );
        final registry = ConnectionRegistry();
        final svc = ConnectionService(
          localNodeId: localId,
          port: localPort,
          registry: registry,
          metrics: BlueyMetrics(),
          serviceUuid: serviceUuid,
        );
        var calls = 0;
        localPort.onConnectAndIdentify = (_) => calls++;

        await localPort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'L',
          localNodeId: localId,
        );
        await remotePort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'R',
          localNodeId: remoteId,
        );

        await svc.startDiscovery();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(registry.contains(remoteId), isTrue);
        final initialCalls = calls;

        // Rebroadcast timer keeps emitting; cache should silence them.
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(
          calls,
          equals(initialCalls),
          reason: 'cache should silence re-emissions while peer is registered',
        );

        await svc.dispose();
        await remotePort.dispose();
      },
    );

    test(
      'targetConnections respected: candidate ignored when at cap',
      () async {
        final network = FakeBlueyNetwork();
        final localPort = FakeBlueyPort(localNodeId: localId, network: network);
        final remotePort = FakeBlueyPort(
          localNodeId: remoteId,
          network: network,
        );
        final registry = ConnectionRegistry();
        final svc = ConnectionService(
          localNodeId: localId,
          port: localPort,
          registry: registry,
          metrics: BlueyMetrics(),
          serviceUuid: serviceUuid,
          maxConnections: 1,
          targetConnections: 0,
        );
        var calls = 0;
        localPort.onConnectAndIdentify = (_) => calls++;

        await localPort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'L',
          localNodeId: localId,
        );
        await remotePort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'R',
          localNodeId: remoteId,
        );

        await svc.startDiscovery();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(calls, equals(0));
        expect(registry.contains(remoteId), isFalse);

        await svc.dispose();
        await remotePort.dispose();
      },
    );

    test('NotABlueyPeerException → long backoff', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);
      final registry = ConnectionRegistry();
      final clock = _ManualClock(DateTime.utc(2026, 5, 5, 12));
      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: registry,
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
        clock: clock,
      );

      var calls = 0;
      localPort.notABlueyPeerInjector = (_) {
        calls++;
        return true;
      };

      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'L',
        localNodeId: localId,
      );
      await remotePort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'R',
        localNodeId: remoteId,
      );
      await svc.startDiscovery();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // First emission threw NotABlueyPeerException. Long backoff applied.
      expect(calls, equals(1));
      expect(registry.contains(remoteId), isFalse);

      // Even 30 s later (well past short transient backoff) we should
      // still be in the long backoff window (5 minutes) — re-emissions
      // ignored.
      clock.advance(const Duration(seconds: 30));
      localPort.emitScanCandidate(
        ScanCandidate(address: BleAddress(remoteId.value), displayName: 'R'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, equals(1));

      await svc.dispose();
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
        final svc = ConnectionService(
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

        // Encode a payload at the wire layer and inject as if remote sent it.
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

      // Create both services BEFORE the connect call so neither subscribes
      // to its port's broadcast stream after the PortPeerConnected event
      // has already fired.
      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );
      final remoteSvc = ConnectionService(
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

    test('discovery initiates connect to peers with greater NodeId', () async {
      final network = FakeBlueyNetwork();
      // localId < remoteId, so local should initiate.
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);
      await remotePort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Remote',
        localNodeId: remoteId,
      );
      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Local',
        localNodeId: localId,
      );

      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );
      final events = <ConnectionEvent>[];
      final sub = svc.events.listen(events.add);

      await svc.startDiscovery();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final opened = events.whereType<PeerOpened>().toList();
      expect(opened.map((e) => e.nodeId), contains(remoteId));

      await sub.cancel();
      await svc.dispose();
      await remotePort.dispose();
    });

    test('initiator skips connect when at maxConnections', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remoteId2 = NodeId('33333333-3333-3333-3333-333333333333');
      final remoteId3 = NodeId('44444444-4444-4444-4444-444444444444');
      final r2 = FakeBlueyPort(localNodeId: remoteId2, network: network);
      final r3 = FakeBlueyPort(localNodeId: remoteId3, network: network);
      await r2.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'r2',
        localNodeId: remoteId2,
      );
      await r3.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'r3',
        localNodeId: remoteId3,
      );
      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Local',
        localNodeId: localId,
      );

      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
        maxConnections: 1,
      );
      await svc.startDiscovery();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(svc.registry.connectionCount, equals(1));

      await svc.dispose();
      await r2.dispose();
      await r3.dispose();
    });

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

      final svc = ConnectionService(
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

    test('does not run discovery rounds while at targetConnections', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final r2id = NodeId('33333333-3333-3333-3333-333333333333');
      final r2 = FakeBlueyPort(localNodeId: r2id, network: network);
      await r2.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'r2',
        localNodeId: r2id,
      );
      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Local',
        localNodeId: localId,
      );

      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
        maxConnections: 1,
      );
      await svc.startDiscovery();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(svc.registry.connectionCount, equals(1));

      // At target — re-emitting the same address (e.g. the BLE scanner
      // sees r2's advertisement again) should NOT trigger another
      // connectAndIdentify call.
      var calls = 0;
      localPort.onConnectAndIdentify = (_) => calls++;
      localPort.emitScanCandidate(
        ScanCandidate(address: BleAddress(r2id.value), displayName: 'r2'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls, equals(0));

      await svc.dispose();
      await r2.dispose();
    });

    test(
      'initiator stops at targetConnections but accepts more inbound',
      () async {
        final network = FakeBlueyNetwork();
        final localPort = FakeBlueyPort(localNodeId: localId, network: network);
        final r2id = NodeId('33333333-3333-3333-3333-333333333333');
        final r3id = NodeId('44444444-4444-4444-4444-444444444444');
        final r2 = FakeBlueyPort(localNodeId: r2id, network: network);
        final r3 = FakeBlueyPort(localNodeId: r3id, network: network);
        await r2.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'r2',
          localNodeId: r2id,
        );
        await r3.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'r3',
          localNodeId: r3id,
        );
        await localPort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'Local',
          localNodeId: localId,
        );

        final svc = ConnectionService(
          localNodeId: localId,
          port: localPort,
          registry: ConnectionRegistry(),
          metrics: BlueyMetrics(),
          serviceUuid: serviceUuid,
          maxConnections: 2,
          targetConnections: 1,
        );
        await svc.startDiscovery();
        await Future<void>.delayed(const Duration(milliseconds: 10));

        // Soft cap: only one initiated.
        expect(svc.registry.connectionCount, equals(1));

        // Inbound still accepted up to maxConnections.
        // Find which one we connected to, then have the OTHER initiate inbound.
        final connectedTo = svc.registry.connections.first.nodeId;
        final remaining = connectedTo == r2id ? r3 : r2;
        await remaining.connect(localId);
        await Future<void>.delayed(Duration.zero);

        expect(svc.registry.connectionCount, equals(2));

        await svc.dispose();
        await r2.dispose();
        await r3.dispose();
      },
    );

    test('discovery filter rejects peers that do not match', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final r2id = NodeId('33333333-3333-3333-3333-333333333333');
      final r3id = NodeId('44444444-4444-4444-4444-444444444444');
      final r2 = FakeBlueyPort(localNodeId: r2id, network: network);
      final r3 = FakeBlueyPort(localNodeId: r3id, network: network);
      await r2.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'r2',
        localNodeId: r2id,
      );
      await r3.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'r3',
        localNodeId: r3id,
      );

      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );
      await svc.startDiscovery(filter: (id) => id == r3id);
      // Filter rejection in the new model: connectAndIdentify completes,
      // tryRegister adds the handle, then the post-connect filter check
      // calls disconnectRole(central) which fires PortPeerDisconnected,
      // and _onPortEvent removes the handle. Allow time for both legs.
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(svc.registry.connectionCount, equals(1));
      expect(svc.registry.contains(r3id), isTrue);
      expect(svc.registry.contains(r2id), isFalse);

      await svc.dispose();
      await r2.dispose();
      await r3.dispose();
    });

    test(
      'skips reconnect within address-backoff window after a connect failure',
      () async {
        final network = FakeBlueyNetwork();
        final localPort = FakeBlueyPort(localNodeId: localId, network: network);
        final r2id = NodeId('33333333-3333-3333-3333-333333333333');
        final r2 = FakeBlueyPort(localNodeId: r2id, network: network);
        await r2.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'r2',
          localNodeId: r2id,
        );
        // Inject failure for r2's address.
        localPort.connectAndIdentifyFailureInjector = (_) => true;

        final fakeClock = _ManualClock(DateTime(2026, 5, 4));
        final svc = ConnectionService(
          localNodeId: localId,
          port: localPort,
          registry: ConnectionRegistry(),
          metrics: BlueyMetrics(),
          serviceUuid: serviceUuid,
          clock: fakeClock,
        );
        await svc.startDiscovery();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(svc.registry.connectionCount, equals(0));

        // Within backoff window (1s) — re-emitting the same address
        // should NOT trigger another connectAndIdentify call.
        var attempts = 0;
        localPort.connectAndIdentifyFailureInjector = (_) {
          attempts++;
          return true;
        };
        fakeClock.advance(const Duration(milliseconds: 500));
        localPort.emitScanCandidate(
          ScanCandidate(address: BleAddress(r2id.value), displayName: 'r2'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(attempts, equals(0));
        expect(svc.registry.connectionCount, equals(0));

        // After backoff expires (1s elapsed), discovery retries.
        // (Total elapsed: 500ms + 600ms = 1100ms.)
        localPort.connectAndIdentifyFailureInjector = null;
        fakeClock.advance(const Duration(milliseconds: 600));
        localPort.emitScanCandidate(
          ScanCandidate(address: BleAddress(r2id.value), displayName: 'r2'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(svc.registry.connectionCount, equals(1));

        await svc.dispose();
        await r2.dispose();
      },
    );

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
      final svc = ConnectionService(
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
  });
}
