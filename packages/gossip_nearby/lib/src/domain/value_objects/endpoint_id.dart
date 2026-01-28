/// A unique identifier assigned by Nearby Connections to an endpoint.
///
/// This is a platform-assigned, transient identifier that may change
/// between connection sessions.
class EndpointId {
  final String value;

  EndpointId(this.value) {
    if (value.isEmpty) {
      throw ArgumentError.value(value, 'value', 'EndpointId cannot be empty');
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EndpointId &&
          runtimeType == other.runtimeType &&
          value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'EndpointId($value)';
}
