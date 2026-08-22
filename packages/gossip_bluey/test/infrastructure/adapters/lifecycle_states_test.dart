import 'package:bluey/bluey.dart' as bluey;
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/gossip_bluey.dart';
import 'package:gossip_bluey/src/infrastructure/adapters/bluey_port_impl.dart';

void main() {
  test('every bluey AdvertisingState maps to exactly one owned value', () {
    for (final s in bluey.AdvertisingState.values) {
      expect(
        BlueyPortImpl.mapAdvertisingState(s).name,
        s.name,
        reason: 'the owned enum mirrors bluey 1:1',
      );
    }
    expect(
      AdvertisingState.values.length,
      bluey.AdvertisingState.values.length,
    );
  });

  test('every bluey ScanState maps to exactly one owned value', () {
    for (final s in bluey.ScanState.values) {
      expect(BlueyPortImpl.mapScanState(s).name, s.name);
    }
    expect(ScanState.values.length, bluey.ScanState.values.length);
  });
}
