import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy_platform_interface/bluetooth_low_energy_platform_interface.dart';

import '../../domain/ports/ble_port.dart';
import '../../domain/value_objects/device_id.dart';
import '../../domain/value_objects/service_id.dart';
import 'central_adapter.dart';
import 'peripheral_adapter.dart';

/// Callback for logging.
typedef BleLogCallback = void Function(String message);

/// Implements [BlePort] by combining Central and Peripheral adapters.
///
/// Each device acts as BOTH:
/// - A Peripheral (advertises a GATT service for others to connect)
/// - A Central (scans for and connects to other peripherals)
class BlePortImpl implements BlePort {
  final CentralAdapter _centralAdapter;
  final PeripheralAdapter _peripheralAdapter;
  final BleLogCallback? _onLog;

  final _eventController = StreamController<BleEvent>.broadcast();
  StreamSubscription? _centralSubscription;
  StreamSubscription? _peripheralSubscription;

  BlePortImpl({
    CentralManager? centralManager,
    PeripheralManager? peripheralManager,
    BleLogCallback? onLog,
  }) : _onLog = onLog,
       _centralAdapter = CentralAdapter(
         centralManager: centralManager,
         onLog: onLog,
       ),
       _peripheralAdapter = PeripheralAdapter(
         peripheralManager: peripheralManager,
         onLog: onLog,
       ) {
    _centralSubscription = _centralAdapter.events.listen(_eventController.add);
    _peripheralSubscription = _peripheralAdapter.events.listen(
      _eventController.add,
    );
  }

  void _log(String message) {
    _onLog?.call('[BlePort] $message');
  }

  @override
  Stream<BleEvent> get events => _eventController.stream;

  @override
  Future<void> startAdvertising(ServiceId serviceId, String displayName) async {
    _log('Starting advertising: $displayName');
    await _peripheralAdapter.startAdvertising(displayName);
  }

  @override
  Future<void> stopAdvertising() async {
    _log('Stopping advertising');
    await _peripheralAdapter.stopAdvertising();
  }

  @override
  Future<void> startDiscovery(ServiceId serviceId) async {
    _log('Starting discovery');
    await _centralAdapter.startDiscovery();
  }

  @override
  Future<void> stopDiscovery() async {
    _log('Stopping discovery');
    await _centralAdapter.stopDiscovery();
  }

  @override
  Future<void> requestConnection(DeviceId deviceId) async {
    _log('Requesting connection to $deviceId');
    await _centralAdapter.connect(deviceId);
  }

  @override
  Future<void> disconnect(DeviceId deviceId) async {
    _log('Disconnecting from $deviceId');

    // Try both adapters - connection could be from either role
    if (_centralAdapter.hasConnection(deviceId)) {
      await _centralAdapter.disconnect(deviceId);
    }
    // Note: PeripheralManager doesn't have explicit disconnect in v7
  }

  @override
  Future<void> send(DeviceId deviceId, Uint8List bytes) async {
    // Try to send via the appropriate adapter based on connection type
    if (_centralAdapter.hasConnection(deviceId)) {
      await _centralAdapter.send(deviceId, bytes);
    } else if (_peripheralAdapter.hasConnection(deviceId)) {
      await _peripheralAdapter.send(deviceId, bytes);
    } else {
      _log('No connection for $deviceId');
    }
  }

  @override
  Future<void> dispose() async {
    _log('Disposing BlePortImpl');
    await _centralSubscription?.cancel();
    await _peripheralSubscription?.cancel();
    await _centralAdapter.dispose();
    await _peripheralAdapter.dispose();
    await _eventController.close();
  }
}
