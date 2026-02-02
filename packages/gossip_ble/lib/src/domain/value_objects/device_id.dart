import 'package:meta/meta.dart';

/// Identifies a BLE device (peripheral or central).
///
/// This is a transient, platform-assigned identifier that may change
/// between connections. Use `NodeId` from gossip for stable peer identity.
@immutable
class DeviceId {
  final String value;

  const DeviceId(this.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is DeviceId && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'DeviceId($value)';
}
