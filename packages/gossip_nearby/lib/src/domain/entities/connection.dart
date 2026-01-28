import 'package:gossip/gossip.dart';

import '../value_objects/endpoint.dart';
import '../value_objects/endpoint_id.dart';

/// An established connection between the local device and a remote peer.
///
/// A Connection is created after the handshake completes, associating
/// the platform-assigned [endpoint] with the application-level [nodeId].
///
/// Identity is based on [endpointId] since that's the unique identifier
/// for the underlying Nearby Connections link.
class Connection {
  final Endpoint endpoint;
  final NodeId nodeId;
  final DateTime connectedAt;

  Connection({
    required this.endpoint,
    required this.nodeId,
    required this.connectedAt,
  });

  /// Convenience accessor for the endpoint's ID.
  EndpointId get endpointId => endpoint.id;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Connection &&
          runtimeType == other.runtimeType &&
          endpointId == other.endpointId;

  @override
  int get hashCode => endpointId.hashCode;

  @override
  String toString() =>
      'Connection(endpointId: $endpointId, nodeId: $nodeId, connectedAt: $connectedAt)';
}
