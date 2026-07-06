import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/application/observability/bluey_metrics.dart';
import 'package:gossip_bluey/src/application/services/auto_connect_policy.dart';
import 'package:gossip_bluey/src/application/services/connection_manager.dart';
import 'package:gossip_bluey/src/application/services/discovery_service.dart';
import 'package:gossip_bluey/src/domain/aggregates/connection_registry.dart';
import 'package:gossip_bluey/src/domain/errors/already_connecting_exception.dart';
import 'package:gossip_bluey/src/domain/value_objects/ble_address.dart';
import 'package:gossip_bluey/src/domain/value_objects/connection_mode.dart';
import 'package:gossip_bluey/src/domain/value_objects/scan_candidate.dart';
import 'package:gossip_bluey/src/domain/value_objects/service_uuid.dart';

import '../../fakes/fake_bluey_port.dart';

final _t0 = DateTime.utc(2026, 1, 1);

ScanCandidate _candidateFor(NodeId nodeId) => ScanCandidate(
  address: BleAddress(nodeId.value),
  displayName: 'peer',
  rssi: -50,
  lastSeen: _t0,
);

void main() {
  final localId = NodeId('11111111-1111-1111-1111-111111111111');
  final remoteId = NodeId('22222222-2222-2222-2222-222222222222');
  final serviceUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');

  group('M18: AutoConnectPolicy error classification', () {
    test(
      'a StateError from the connect path records backoff (only the '
      'typed reentrancy exception is benign)',
      () async {
        final network = FakeBlueyNetwork();
        final port = FakeBlueyPort(localNodeId: localId, network: network);
        final registry = ConnectionRegistry();
        final manager = ConnectionManager(
          port: port,
          registry: registry,
          metrics: BlueyMetrics(),
        );
        final discovery = DiscoveryService(
          port: port,
          serviceUuid: serviceUuid,
        );
        var now = _t0;
        final policy = AutoConnectPolicy(
          discovery: discovery,
          connections: manager,
          registry: registry,
          now: () => now,
        );
        policy.setMode(ConnectionMode.auto);
        await discovery.start();

        final candidate = _candidateFor(remoteId);
        // Stale candidate: the port no longer knows the device (adapter
        // cycled) — connectAndIdentify throws StateError.
        port.injectConnectAndIdentifyError(
          candidate.address,
          StateError('no scan-emitted device for ${candidate.address}'),
        );
        port.emitCandidate(candidate);
        await Future<void>.delayed(Duration.zero);
        expect(port.connectAndIdentifyCallCount, equals(1));

        // Re-emission a moment later: with no backoff recorded, this is
        // the hot retry storm.
        now = now.add(const Duration(milliseconds: 10));
        port.injectConnectAndIdentifyError(
          candidate.address,
          StateError('no scan-emitted device for ${candidate.address}'),
        );
        port.emitCandidate(candidate);
        await Future<void>.delayed(Duration.zero);

        expect(
          port.connectAndIdentifyCallCount,
          equals(1),
          reason:
              'a real StateError must record backoff — treating every '
              'StateError as the benign reentrancy guard causes a hot '
              'retry storm on every advertisement',
        );

        await policy.dispose();
        await discovery.dispose();
        await manager.dispose();
        await port.dispose();
      },
    );

    test(
      'the typed reentrancy exception is benign: no backoff recorded',
      () async {
        final network = FakeBlueyNetwork();
        final port = FakeBlueyPort(localNodeId: localId, network: network);
        final registry = ConnectionRegistry();
        final manager = ConnectionManager(
          port: port,
          registry: registry,
          metrics: BlueyMetrics(),
        );
        final discovery = DiscoveryService(
          port: port,
          serviceUuid: serviceUuid,
        );
        var now = _t0;
        final policy = AutoConnectPolicy(
          discovery: discovery,
          connections: manager,
          registry: registry,
          now: () => now,
        );
        policy.setMode(ConnectionMode.auto);
        await discovery.start();

        final candidate = _candidateFor(remoteId);
        port.injectConnectAndIdentifyError(
          candidate.address,
          AlreadyConnectingException(candidate.address),
        );
        port.emitCandidate(candidate);
        await Future<void>.delayed(Duration.zero);
        expect(port.connectAndIdentifyCallCount, equals(1));

        // Immediate re-emission must be allowed to retry (no backoff).
        now = now.add(const Duration(milliseconds: 10));
        await FakeBlueyPort(
          localNodeId: remoteId,
          network: network,
        ).startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'Remote',
          localNodeId: remoteId,
        );
        port.emitCandidate(candidate);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(
          port.connectAndIdentifyCallCount,
          equals(2),
          reason: 'the reentrancy guard firing is not a failure',
        );

        await policy.dispose();
        await discovery.dispose();
        await manager.dispose();
        await port.dispose();
      },
    );
  });

  group('M20: targetConnections soft cap under concurrency', () {
    test('a burst of candidates cannot overshoot the cap', () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      final registry = ConnectionRegistry();
      final manager = ConnectionManager(
        port: port,
        registry: registry,
        metrics: BlueyMetrics(),
      );
      final discovery = DiscoveryService(port: port, serviceUuid: serviceUuid);
      final policy = AutoConnectPolicy(
        discovery: discovery,
        connections: manager,
        registry: registry,
        now: () => _t0,
        targetConnections: 1,
      );
      policy.setMode(ConnectionMode.auto);
      await discovery.start();

      // Three distinct peers advertise simultaneously; connects are slow
      // so all three candidate events arrive before any connect lands.
      port.connectAndIdentifyDelay = const Duration(milliseconds: 20);
      final peers = [
        NodeId('33333333-3333-3333-3333-333333333333'),
        NodeId('44444444-4444-4444-4444-444444444444'),
        NodeId('55555555-5555-5555-5555-555555555555'),
      ];
      for (final p in peers) {
        final peerPort = FakeBlueyPort(localNodeId: p, network: network);
        await peerPort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'p',
          localNodeId: p,
        );
        port.emitCandidate(_candidateFor(p));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        port.connectAndIdentifyCallCount,
        equals(1),
        reason:
            'checking the cap only before the await lets a scan burst '
            'overshoot targetConnections',
      );

      await policy.dispose();
      await discovery.dispose();
      await manager.dispose();
      await port.dispose();
    });
  });

  group('M17: DiscoveryService adapter-cycle recovery', () {
    test('a closed scan stream resets the service so start() works again',
        () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      final discovery = DiscoveryService(port: port, serviceUuid: serviceUuid);

      await discovery.start();
      port.emitCandidate(_candidateFor(remoteId));
      await Future<void>.delayed(Duration.zero);
      expect(discovery.currentCandidates, hasLength(1));

      // Adapter off: the port closes the scan stream.
      await port.stopScan();
      await Future<void>.delayed(Duration.zero);

      expect(
        discovery.isRunning,
        isFalse,
        reason: 'a dead subscription must not report itself as running',
      );
      expect(
        discovery.currentCandidates,
        isEmpty,
        reason: 'stale candidates feed the auto-connect path with devices '
            'the port no longer knows',
      );

      // Adapter back on: start() must actually restart the scan.
      await discovery.start();
      expect(
        port.scanForCandidatesCallCount,
        equals(2),
        reason: 'start() after an adapter cycle silently no-ops',
      );

      await discovery.dispose();
      await port.dispose();
    });
  });

  group('L17: connectTo registration visibility', () {
    test('the registry contains the peer when connectTo resolves', () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);
      await remotePort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Remote',
        localNodeId: remoteId,
      );
      final registry = ConnectionRegistry();
      final manager = ConnectionManager(
        port: port,
        registry: registry,
        metrics: BlueyMetrics(),
      );

      final nodeId = await manager.connectTo(_candidateFor(remoteId));

      expect(
        registry.contains(nodeId),
        isTrue,
        reason:
            'a caller that sends immediately after connectTo succeeds must '
            'not get ConnectionNotFoundError',
      );

      await manager.dispose();
      await port.dispose();
      await remotePort.dispose();
    });
  });

  group('L19: connect failures reach metrics', () {
    test('PortConnectFailed increments totalConnectionsFailed', () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      final metrics = BlueyMetrics();
      final manager = ConnectionManager(
        port: port,
        registry: ConnectionRegistry(),
        metrics: metrics,
      );

      port.connectFailureInjector = (_) => true;
      await expectLater(() => port.connect(remoteId), throwsStateError);
      await Future<void>.delayed(Duration.zero);

      expect(
        metrics.totalConnectionsFailed,
        equals(1),
        reason: 'failure accounting was never wired to any path',
      );

      await manager.dispose();
      await port.dispose();
    });
  });
}
