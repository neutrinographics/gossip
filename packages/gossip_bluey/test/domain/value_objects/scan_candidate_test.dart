import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/src/domain/value_objects/ble_address.dart';
import 'package:gossip_bluey/src/domain/value_objects/scan_candidate.dart';

void main() {
  group('ScanCandidate', () {
    const address = BleAddress('AA:BB:CC:DD:EE:FF');

    test('constructs with required address and optional displayName', () {
      const c = ScanCandidate(address: address, displayName: 'phone');
      expect(c.address, equals(address));
      expect(c.displayName, equals('phone'));
    });

    test('displayName is optional', () {
      const c = ScanCandidate(address: address);
      expect(c.displayName, isNull);
    });
  });
}
