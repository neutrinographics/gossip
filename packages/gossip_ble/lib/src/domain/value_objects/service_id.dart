import 'package:meta/meta.dart';

/// Identifies a BLE service for discovery filtering.
///
/// Typically a reverse-domain identifier like 'com.example.app'.
@immutable
class ServiceId {
  final String value;

  const ServiceId(this.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ServiceId && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ServiceId($value)';
}
