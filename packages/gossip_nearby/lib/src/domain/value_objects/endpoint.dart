import 'endpoint_id.dart';

/// Information about a discovered Nearby Connections endpoint.
///
/// Contains the platform-assigned [id] and a human-readable [displayName].
/// Equality is based solely on [id] since displayName is informational.
class Endpoint {
  final EndpointId id;
  final String displayName;

  Endpoint({required this.id, required this.displayName});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Endpoint && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Endpoint(id: $id, displayName: $displayName)';
}
