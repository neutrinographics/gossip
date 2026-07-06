import '../value_objects/ble_address.dart';

/// Thrown by `ConnectionManager.connectTo` when a connection attempt for
/// the same address is already in flight (reentrancy guard).
///
/// A DISTINCT type on purpose: callers (AutoConnectPolicy) treat this as
/// benign — the in-flight attempt will resolve — whereas a generic
/// [StateError] from the connect path (e.g. "no scan-emitted device for
/// this address" after an adapter cycle) is a real failure that must
/// record backoff. Conflating the two causes a hot retry storm on every
/// advertisement.
class AlreadyConnectingException implements Exception {
  final BleAddress address;

  AlreadyConnectingException(this.address);

  @override
  String toString() =>
      'AlreadyConnectingException: a connect attempt for $address is '
      'already in flight';
}
