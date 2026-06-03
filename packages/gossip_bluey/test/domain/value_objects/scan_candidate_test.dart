import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/src/domain/value_objects/ble_address.dart';
import 'package:gossip_bluey/src/domain/value_objects/scan_candidate.dart';

void main() {
  group('ScanCandidate', () {
    const addr = BleAddress('AA:BB:CC:DD:EE:FF');
    final t = DateTime.utc(2026, 6, 3, 12);

    test('exposes address, displayName, rssi, lastSeen', () {
      final c = ScanCandidate(
        address: addr,
        displayName: 'Pixel 6a',
        rssi: -48,
        lastSeen: t,
      );
      expect(c.address, addr);
      expect(c.displayName, 'Pixel 6a');
      expect(c.rssi, -48);
      expect(c.lastSeen, t);
    });

    test('displayName and rssi are nullable; lastSeen is required', () {
      final c = ScanCandidate(address: addr, lastSeen: t);
      expect(c.displayName, isNull);
      expect(c.rssi, isNull);
      expect(c.lastSeen, t);
    });

    test('value equality by all four fields', () {
      final a = ScanCandidate(
        address: addr,
        displayName: 'X',
        rssi: -50,
        lastSeen: t,
      );
      final b = ScanCandidate(
        address: addr,
        displayName: 'X',
        rssi: -50,
        lastSeen: t,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('inequality on differing fields', () {
      final base = ScanCandidate(
        address: addr,
        displayName: 'X',
        rssi: -50,
        lastSeen: t,
      );
      expect(
        ScanCandidate(
          address: const BleAddress('FF:FF:FF:FF:FF:FF'),
          displayName: 'X',
          rssi: -50,
          lastSeen: t,
        ),
        isNot(equals(base)),
      );
      expect(
        ScanCandidate(
          address: addr,
          displayName: 'Y',
          rssi: -50,
          lastSeen: t,
        ),
        isNot(equals(base)),
      );
      expect(
        ScanCandidate(
          address: addr,
          displayName: 'X',
          rssi: -49,
          lastSeen: t,
        ),
        isNot(equals(base)),
      );
      expect(
        ScanCandidate(
          address: addr,
          displayName: 'X',
          rssi: -50,
          lastSeen: DateTime.utc(2026, 6, 4),
        ),
        isNot(equals(base)),
      );
    });
  });
}
