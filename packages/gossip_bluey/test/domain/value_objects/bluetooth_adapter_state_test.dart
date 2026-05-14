import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/src/domain/value_objects/bluetooth_adapter_state.dart';

void main() {
  group('BluetoothAdapterState', () {
    test('has the five expected values', () {
      expect(BluetoothAdapterState.values, hasLength(5));
      expect(BluetoothAdapterState.values, containsAll([
        BluetoothAdapterState.on,
        BluetoothAdapterState.off,
        BluetoothAdapterState.unauthorized,
        BluetoothAdapterState.unsupported,
        BluetoothAdapterState.unknown,
      ]));
    });
  });
}
