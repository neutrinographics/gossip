/// 128-bit BLE service UUID, validated at construction.
class ServiceUuid {
  static final RegExp _pattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  final String value;

  ServiceUuid(String input) : value = input.toLowerCase() {
    if (!_pattern.hasMatch(value)) {
      throw ArgumentError.value(
        input,
        'value',
        'not a well-formed 128-bit UUID',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is ServiceUuid && other.value == value);

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ServiceUuid($value)';
}
