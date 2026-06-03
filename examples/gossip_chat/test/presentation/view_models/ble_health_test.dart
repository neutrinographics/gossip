import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_chat/presentation/view_models/ble_health.dart';

void main() {
  group('BleHealth.fromRssi', () {
    test('null rssi -> unknown',
        () => expect(BleHealth.fromRssi(null), BleHealth.unknown));
    test('-50 -> excellent',
        () => expect(BleHealth.fromRssi(-50), BleHealth.excellent));
    test('-60 (boundary) -> excellent',
        () => expect(BleHealth.fromRssi(-60), BleHealth.excellent));
    test('-61 -> good',
        () => expect(BleHealth.fromRssi(-61), BleHealth.good));
    test('-75 (boundary) -> good',
        () => expect(BleHealth.fromRssi(-75), BleHealth.good));
    test('-76 -> fair',
        () => expect(BleHealth.fromRssi(-76), BleHealth.fair));
    test('-85 (boundary) -> fair',
        () => expect(BleHealth.fromRssi(-85), BleHealth.fair));
    test('-86 -> poor',
        () => expect(BleHealth.fromRssi(-86), BleHealth.poor));
    test('-120 -> poor',
        () => expect(BleHealth.fromRssi(-120), BleHealth.poor));
    test('extreme positive rssi -> excellent',
        () => expect(BleHealth.fromRssi(0), BleHealth.excellent));
  });
}
