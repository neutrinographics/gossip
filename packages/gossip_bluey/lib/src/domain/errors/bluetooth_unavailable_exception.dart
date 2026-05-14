import 'package:gossip/gossip.dart';

/// Thrown by BlueyPort lifecycle and operation methods when the
/// underlying Bluetooth adapter is in a state that prevents normal
/// operation — typically because the adapter is off, transitioning, or
/// permission was revoked.
///
/// The port observes `Bluey.stateStream` and proactively transitions
/// to a *disabled* state on any non-`on` value. While disabled, calls
/// throw this exception immediately. The port re-enables when
/// `stateStream` emits `on` again, but advertising/services must be
/// re-established by an explicit call to `BlueyPort.startAdvertising`.
class BluetoothUnavailableException implements Exception {
  /// Underlying error from bluey or the platform plugin, when this
  /// exception was caused by a thrown lifecycle call. Null when the
  /// exception was thrown proactively because the port was already
  /// disabled.
  final Object? cause;

  /// Optional NodeId context — set when this exception surfaces from
  /// a per-peer call (e.g. `connect`, `sendData`). Null for global
  /// lifecycle calls like `startAdvertising`.
  final NodeId? nodeId;

  const BluetoothUnavailableException({this.cause, this.nodeId});

  @override
  String toString() {
    final parts = <String>[];
    if (cause != null) parts.add('cause: $cause');
    if (nodeId != null) parts.add('nodeId: $nodeId');
    return 'BluetoothUnavailableException(${parts.join(', ')})';
  }
}
