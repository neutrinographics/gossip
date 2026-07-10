import 'package:gossip/gossip.dart';

/// Thrown by `ConnectionManager.connectTo` when the GATT connect and
/// bluey-protocol identification succeeded but the connection was NOT
/// registered — the manager rejected it (maxConnections cap, or a
/// duplicate link for an already-registered NodeId).
///
/// A DISTINCT type on purpose: returning the NodeId as success hands the
/// caller a peer it can never send to. `AutoConnectPolicy` treats this as
/// a real failure and records backoff — otherwise every advertisement
/// repeats the full connect→identify→reject→disconnect cycle (GATT
/// connect churn at the cap boundary).
class ConnectionRejectedException implements Exception {
  final NodeId nodeId;

  ConnectionRejectedException(this.nodeId);

  @override
  String toString() =>
      'ConnectionRejectedException: connection to $nodeId was established '
      'but rejected at registration (cap or duplicate)';
}
