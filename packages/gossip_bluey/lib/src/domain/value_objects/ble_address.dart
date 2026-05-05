class BleAddress {
  final String value;
  const BleAddress(this.value);

  @override
  bool operator ==(Object other) => other is BleAddress && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'BleAddress($value)';
}
