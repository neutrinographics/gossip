import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/application/services/discovery_service.dart';
import 'package:gossip_bluey/src/domain/value_objects/ble_address.dart';
import 'package:gossip_bluey/src/domain/value_objects/scan_candidate.dart';
import 'package:gossip_bluey/src/domain/value_objects/service_uuid.dart';

import '../../fakes/fake_bluey_port.dart';

final _t0 = DateTime.utc(2026, 1, 1);

ScanCandidate _candidate(String addr, {int rssi = -50, DateTime? at}) =>
    ScanCandidate(
      address: BleAddress(addr),
      lastSeen: at ?? _t0,
      rssi: rssi,
    );

void main() {
  late FakeBlueyPort port;
  late DiscoveryService service;
  late ServiceUuid uuid;

  setUp(() {
    port = FakeBlueyPort(
      localNodeId: NodeId('11111111-1111-1111-1111-111111111111'),
      network: FakeBlueyNetwork(),
    );
    uuid = ServiceUuid('f0000000-0000-0000-0000-67c155b1ea7c');
    service = DiscoveryService(port: port, serviceUuid: uuid);
  });

  tearDown(() async {
    await service.dispose();
  });

  group('DiscoveryService', () {
    test('isRunning is false before start', () {
      expect(service.isRunning, isFalse);
    });

    test('start() subscribes to port.scanForCandidates', () async {
      await service.start();
      expect(service.isRunning, isTrue);
      expect(port.scanForCandidatesCallCount, 1);
    });

    test('start() is idempotent', () async {
      await service.start();
      await service.start();
      expect(port.scanForCandidatesCallCount, 1);
    });

    test('candidates stream emits each scan event', () async {
      await service.start();
      final received = <ScanCandidate>[];
      final sub = service.candidates.listen(received.add);
      port.emitCandidate(_candidate('AA:BB:CC:DD:EE:01'));
      port.emitCandidate(_candidate('AA:BB:CC:DD:EE:02'));
      await Future<void>.delayed(Duration.zero);
      expect(received.map((c) => c.address.value), [
        'AA:BB:CC:DD:EE:01',
        'AA:BB:CC:DD:EE:02',
      ]);
      await sub.cancel();
    });

    test('repeated emissions for same address overwrite (RSSI/lastSeen update)',
        () async {
      await service.start();
      port.emitCandidate(_candidate('AA:BB:CC:DD:EE:01', rssi: -50));
      port.emitCandidate(_candidate('AA:BB:CC:DD:EE:01', rssi: -42));
      await Future<void>.delayed(Duration.zero);
      expect(service.currentCandidates, hasLength(1));
      expect(service.currentCandidates.single.rssi, -42);
    });

    test('snapshots stream replays current map on subscribe', () async {
      await service.start();
      port.emitCandidate(_candidate('AA:BB:CC:DD:EE:01'));
      port.emitCandidate(_candidate('AA:BB:CC:DD:EE:02'));
      await Future<void>.delayed(Duration.zero);
      final firstSnapshot = await service.snapshots.first;
      expect(firstSnapshot.map((c) => c.address.value), [
        'AA:BB:CC:DD:EE:01',
        'AA:BB:CC:DD:EE:02',
      ]);
    });

    test('snapshots stream emits on every change', () async {
      await service.start();
      final received = <List<ScanCandidate>>[];
      final sub = service.snapshots.listen(received.add);
      port.emitCandidate(_candidate('AA:BB:CC:DD:EE:01'));
      port.emitCandidate(_candidate('AA:BB:CC:DD:EE:02'));
      await Future<void>.delayed(Duration.zero);
      // First emission = empty (replayed current); then two updates.
      expect(received, hasLength(3));
      expect(received[0], isEmpty);
      expect(received[1].map((c) => c.address.value).toList(),
          ['AA:BB:CC:DD:EE:01']);
      expect(received[2].map((c) => c.address.value).toList(),
          ['AA:BB:CC:DD:EE:01', 'AA:BB:CC:DD:EE:02']);
      await sub.cancel();
    });

    test('stop() unsubscribes, clears candidates, and emits empty snapshot',
        () async {
      await service.start();
      final received = <List<ScanCandidate>>[];
      final sub = service.snapshots.listen(received.add);
      port.emitCandidate(_candidate('AA:BB:CC:DD:EE:01'));
      await Future<void>.delayed(Duration.zero);
      await service.stop();
      await Future<void>.delayed(Duration.zero);
      expect(service.isRunning, isFalse);
      expect(service.currentCandidates, isEmpty);
      expect(port.stopScanCallCount, greaterThan(0));
      // Final emission must be the empty list.
      expect(received.last, isEmpty);
      await sub.cancel();
    });

    test('multiple subscribers each get independent replay', () async {
      await service.start();
      port.emitCandidate(_candidate('AA:BB:CC:DD:EE:01'));
      await Future<void>.delayed(Duration.zero);

      // Subscriber A subscribes while map has {EE:01}.
      final receivedA = <List<ScanCandidate>>[];
      final subA = service.snapshots.listen(receivedA.add);
      await Future<void>.delayed(Duration.zero);

      // State transitions: add EE:02.
      port.emitCandidate(_candidate('AA:BB:CC:DD:EE:02'));
      await Future<void>.delayed(Duration.zero);

      // Subscriber B subscribes while map has {EE:01, EE:02}.
      final receivedB = <List<ScanCandidate>>[];
      final subB = service.snapshots.listen(receivedB.add);
      await Future<void>.delayed(Duration.zero);

      // A's first emission must reflect state-at-A-time (just EE:01).
      expect(receivedA.first.map((c) => c.address.value), ['AA:BB:CC:DD:EE:01']);

      // B's first emission must reflect state-at-B-time (EE:01 + EE:02).
      expect(receivedB.first.map((c) => c.address.value), [
        'AA:BB:CC:DD:EE:01',
        'AA:BB:CC:DD:EE:02',
      ]);

      // A must have received the EE:02 update too (proving the subscription
      // continues to receive transitions, not just the initial replay).
      expect(receivedA.last.map((c) => c.address.value), [
        'AA:BB:CC:DD:EE:01',
        'AA:BB:CC:DD:EE:02',
      ]);

      await subA.cancel();
      await subB.cancel();
    });
  });
}
