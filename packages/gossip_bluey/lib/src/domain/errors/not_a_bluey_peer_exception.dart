import '../value_objects/ble_address.dart';

/// Thrown by [BlueyPort.connectAndIdentify] when a device connected at
/// the BLE layer but does not host the bluey lifecycle control service.
/// The underlying connection has already been torn down by bluey by the
/// time this is raised, so callers do not need to perform additional
/// cleanup.
class NotABlueyPeerException implements Exception {
  final BleAddress address;
  const NotABlueyPeerException(this.address);

  @override
  String toString() => 'NotABlueyPeerException($address)';
}
