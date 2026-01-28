/// A unique identifier for a Nearby Connections service.
///
/// This should be a reverse-domain identifier (e.g., 'com.example.app').
/// Only devices advertising/discovering the same service ID can connect.
class ServiceId {
  final String value;

  ServiceId(this.value) {
    if (value.isEmpty) {
      throw ArgumentError.value(value, 'value', 'ServiceId cannot be empty');
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ServiceId &&
          runtimeType == other.runtimeType &&
          value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ServiceId($value)';
}
