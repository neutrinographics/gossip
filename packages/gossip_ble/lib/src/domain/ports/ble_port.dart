import 'dart:typed_data';

import '../value_objects/device_id.dart';
import '../value_objects/service_id.dart';

/// Port abstraction for BLE operations.
///
/// The domain defines this interface to specify what it needs from
/// a BLE implementation. The infrastructure layer provides a concrete
/// adapter implementing this interface.
abstract class BlePort {
  /// Starts advertising this device with the given service ID and display name.
  Future<void> startAdvertising(ServiceId serviceId, String displayName);

  /// Stops advertising.
  Future<void> stopAdvertising();

  /// Starts discovering nearby BLE devices with the given service ID.
  Future<void> startDiscovery(ServiceId serviceId);

  /// Stops discovery.
  Future<void> stopDiscovery();

  /// Requests a connection to the given device.
  Future<void> requestConnection(DeviceId deviceId);

  /// Disconnects from the given device.
  Future<void> disconnect(DeviceId deviceId);

  /// Sends bytes to the given device.
  Future<void> send(DeviceId deviceId, Uint8List bytes);

  /// Stream of events from the BLE layer.
  Stream<BleEvent> get events;

  /// Disposes all resources held by this port.
  ///
  /// After calling dispose, the port should not be used.
  Future<void> dispose();
}

/// Events emitted by the BLE layer.
sealed class BleEvent {
  const BleEvent();
}

/// A device was discovered during scanning.
class DeviceDiscovered extends BleEvent {
  final DeviceId id;
  final String displayName;

  const DeviceDiscovered({required this.id, required this.displayName});

  @override
  String toString() => 'DeviceDiscovered(id: $id, displayName: $displayName)';
}

/// A connection was established to a device.
class ConnectionEstablished extends BleEvent {
  final DeviceId id;

  const ConnectionEstablished({required this.id});

  @override
  String toString() => 'ConnectionEstablished(id: $id)';
}

/// Bytes were received from a device.
class BytesReceived extends BleEvent {
  final DeviceId id;
  final Uint8List bytes;

  const BytesReceived({required this.id, required this.bytes});

  @override
  String toString() => 'BytesReceived(id: $id, bytes: ${bytes.length} bytes)';
}

/// A device disconnected.
class DeviceDisconnected extends BleEvent {
  final DeviceId id;

  const DeviceDisconnected({required this.id});

  @override
  String toString() => 'DeviceDisconnected(id: $id)';
}
