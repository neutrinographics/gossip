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

    test('PortPeerConnected for already-registered NodeId triggers '
        'disconnectRole on the just-arrived role; existing handle untouched',
        () async {
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

      expect(registry.contains(remoteId), isTrue,
          reason: 'peripheral handle should remain after duplicate central drop');
      expect(localPort.connectedAsCentral, isNot(contains(remoteId)),
          reason: 'duplicate central connection should have been disconnected');

      await svc.dispose();
      await remotePort.dispose();
    });

    test('scan emission → connectAndIdentify → peer registered (happy path)',
        () async {
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
    });

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
          serviceUuid: serviceUuid, displayName: 'L', localNodeId: localId);
      await remotePort.startAdvertising(
          serviceUuid: serviceUuid, displayName: 'R', localNodeId: remoteId);

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

    test('address cache silences re-emission while peer remains connected',
        () async {
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
      var calls = 0;
      localPort.onConnectAndIdentify = (_) => calls++;

      await localPort.startAdvertising(
          serviceUuid: serviceUuid, displayName: 'L', localNodeId: localId);
      await remotePort.startAdvertising(
          serviceUuid: serviceUuid, displayName: 'R', localNodeId: remoteId);

      await svc.startDiscovery();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(registry.contains(remoteId), isTrue);
      final initialCalls = calls;

      // Rebroadcast timer keeps emitting; cache should silence them.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(calls, equals(initialCalls),
          reason: 'cache should silence re-emissions while peer is registered');

      await svc.dispose();
      await remotePort.dispose();
    });

    test('targetConnections respected: candidate ignored when at cap',
        () async {
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
        maxConnections: 1,
        targetConnections: 0,
      );
      var calls = 0;
      localPort.onConnectAndIdentify = (_) => calls++;

      await localPort.startAdvertising(
          serviceUuid: serviceUuid, displayName: 'L', localNodeId: localId);
      await remotePort.startAdvertising(
          serviceUuid: serviceUuid, displayName: 'R', localNodeId: remoteId);

      await svc.startDiscovery();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, equals(0));
      expect(registry.contains(remoteId), isFalse);

      await svc.dispose();
      await remotePort.dispose();
    });

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
          serviceUuid: serviceUuid, displayName: 'L', localNodeId: localId);
      await remotePort.startAdvertising(
          serviceUuid: serviceUuid, displayName: 'R', localNodeId: remoteId);
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

    test('PortPeerData feeds the FrameDecoder and emits IncomingMessage', () async {
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
    });

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
      expect(
        errs.whereType<ConnectionLimitReachedError>(),
        isNotEmpty,
      );

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

    test('initiator stops at targetConnections but accepts more inbound', () async {
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
    });

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

    test('skips reconnect within address-backoff window after a connect failure',
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
