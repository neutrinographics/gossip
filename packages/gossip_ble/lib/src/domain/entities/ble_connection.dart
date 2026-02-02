import 'package:gossip/gossip.dart';
import 'package:meta/meta.dart';

import '../value_objects/device_id.dart';

/// An established BLE connection between the local device and a remote peer.
///
/// Created after the handshake completes, associating the platform-assigned
/// [deviceId] with the application-level [nodeId].
///
/// Identity is based on [deviceId] since that's the unique identifier
/// for the underlying BLE link.
@immutable
class BleConnection {
  final DeviceId deviceId;
  final NodeId nodeId;
  final DateTime connectedAt;

  BleConnection({
    required this.deviceId,
    required this.nodeId,
    required this.connectedAt,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BleConnection && deviceId == other.deviceId;

  @override
  int get hashCode => deviceId.hashCode;

  @override
  String toString() =>
      'BleConnection(deviceId: $deviceId, nodeId: $nodeId, connectedAt: $connectedAt)';
}
