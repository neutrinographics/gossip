import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/gossip_bluey.dart';

import '../fakes/fake_bluey_port.dart';

void main() {
  group('BlueyTransport candidates + connection mode', () {
    final localId = NodeId('11111111-1111-1111-1111-111111111111');
    final remoteAId = NodeId('22222222-2222-2222-2222-222222222222');
    final remoteBId = NodeId('33333333-3333-3333-3333-333333333333');
    final serviceUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');

    ScanCandidate candidateFor(NodeId id) => ScanCandidate(
          address: BleAddress(id.value),
          lastSeen: DateTime.utc(2026, 1, 1),
          rssi: -50,
        );

    test('defaults to ConnectionMode.manual', () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      final transport = BlueyTransport.testing(
        localNodeId: localId,
        serviceUuid: serviceUuid,
        displayName: 'phone',
        port: port,
      );
      expect(transport.connectionMode, ConnectionMode.manual);
      await transport.dispose();
    });

    test(
      'candidates stream replays current on subscribe and emits on change',
      () async {
        final network = FakeBlueyNetwork();
        final port = FakeBlueyPort(localNodeId: localId, network: network);
        final transport = BlueyTransport.testing(
          localNodeId: localId,
          serviceUuid: serviceUuid,
          displayName: 'phone',
          port: port,
        );

        await transport.startDiscovery();

        final snapshots = <List<ScanCandidate>>[];
        final sub = transport.candidates.listen(snapshots.add);

        // First emission is the (empty) current snapshot.
        await Future<void>.delayed(Duration.zero);
        expect(snapshots, isNotEmpty);
        expect(snapshots.first, isEmpty);

        port.emitCandidate(candidateFor(remoteAId));
        await Future<void>.delayed(Duration.zero);

        expect(snapshots.last.map((c) => c.address.value),
            contains(remoteAId.value));
        expect(transport.currentCandidates.map((c) => c.address.value),
            contains(remoteAId.value));

        await sub.cancel();
        await transport.dispose();
      },
    );

    test('candidateEvents emits per-event', () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      final transport = BlueyTransport.testing(
        localNodeId: localId,
        serviceUuid: serviceUuid,
        displayName: 'phone',
        port: port,
      );
      await transport.startDiscovery();

      final events = <ScanCandidate>[];
      final sub = transport.candidateEvents.listen(events.add);

      port.emitCandidate(candidateFor(remoteAId));
      port.emitCandidate(candidateFor(remoteBId));
      await Future<void>.delayed(Duration.zero);

      expect(events.map((c) => c.address.value),
          containsAll([remoteAId.value, remoteBId.value]));

      await sub.cancel();
      await transport.dispose();
    });

    test(
      'setConnectionMode(auto) drives a connect attempt on next candidate',
      () async {
        final network = FakeBlueyNetwork();
        final port = FakeBlueyPort(localNodeId: localId, network: network);
        // Remote must exist on the network so connectAndIdentify can
        // resolve it.
        FakeBlueyPort(localNodeId: remoteAId, network: network);
        final transport = BlueyTransport.testing(
          localNodeId: localId,
          serviceUuid: serviceUuid,
          displayName: 'phone',
          port: port,
        );

        await transport.startDiscovery();
        transport.setConnectionMode(ConnectionMode.auto);
        expect(transport.connectionMode, ConnectionMode.auto);

        port.emitCandidate(candidateFor(remoteAId));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(port.connectAndIdentifyCallCount, equals(1));
        expect(transport.connectedPeerCount, equals(1));

        await transport.dispose();
      },
    );

    test(
      'setConnectionMode(manual) after connection silences further auto-connects '
      'but preserves the existing connection',
      () async {
        final network = FakeBlueyNetwork();
        final port = FakeBlueyPort(localNodeId: localId, network: network);
        FakeBlueyPort(localNodeId: remoteAId, network: network);
        FakeBlueyPort(localNodeId: remoteBId, network: network);
        final transport = BlueyTransport.testing(
          localNodeId: localId,
          serviceUuid: serviceUuid,
          displayName: 'phone',
          port: port,
        );

        await transport.startDiscovery();
        transport.setConnectionMode(ConnectionMode.auto);
        port.emitCandidate(candidateFor(remoteAId));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(transport.connectedPeerCount, equals(1));

        final beforeSwitchCalls = port.connectAndIdentifyCallCount;
        transport.setConnectionMode(ConnectionMode.manual);
        // New candidate after the mode switch must NOT trigger a connect.
        port.emitCandidate(candidateFor(remoteBId));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(port.connectAndIdentifyCallCount, equals(beforeSwitchCalls));
        // Existing connection is preserved.
        expect(transport.connectedPeerCount, equals(1));

        await transport.dispose();
      },
    );

    test(
      'connectByAddress throws StateError when no candidate is known',
      () async {
        final network = FakeBlueyNetwork();
        final port = FakeBlueyPort(localNodeId: localId, network: network);
        final transport = BlueyTransport.testing(
          localNodeId: localId,
          serviceUuid: serviceUuid,
          displayName: 'phone',
          port: port,
        );

        // No discovery started, no candidate emitted.
        expect(
          () => transport.connectByAddress(const BleAddress('AA:BB:CC:DD:EE:FF')),
          throwsStateError,
        );

        await transport.dispose();
      },
    );

    test(
      'connectByAddress connects using the candidate currently known',
      () async {
        final network = FakeBlueyNetwork();
        final port = FakeBlueyPort(localNodeId: localId, network: network);
        // Remote must exist on the network so connectAndIdentify can
        // resolve it to remoteAId.
        FakeBlueyPort(localNodeId: remoteAId, network: network);
        final transport = BlueyTransport.testing(
          localNodeId: localId,
          serviceUuid: serviceUuid,
          displayName: 'phone',
          port: port,
        );

        await transport.startDiscovery();
        port.emitCandidate(candidateFor(remoteAId));
        await Future<void>.delayed(Duration.zero);

        final resolved = await transport
            .connectByAddress(BleAddress(remoteAId.value));
        expect(resolved, equals(remoteAId));
        expect(transport.connectedPeerCount, equals(1));

        await transport.dispose();
      },
    );

    test('connectTo works in manual mode (drives ConnectionManager directly)',
        () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      FakeBlueyPort(localNodeId: remoteAId, network: network);
      final transport = BlueyTransport.testing(
        localNodeId: localId,
        serviceUuid: serviceUuid,
        displayName: 'phone',
        port: port,
      );

      // No discovery, no auto: explicit connectTo.
      expect(transport.connectionMode, ConnectionMode.manual);
      final resolved = await transport.connectTo(candidateFor(remoteAId));
      await Future<void>.delayed(Duration.zero);

      expect(resolved, equals(remoteAId));
      expect(transport.connectedPeerCount, equals(1));

      await transport.dispose();
    });
  });
}
