import 'package:gossip/gossip.dart';

import '../entities/connection.dart';
import '../events/connection_event.dart';
import '../value_objects/endpoint.dart';
import '../value_objects/endpoint_id.dart';

/// Returned by [ConnectionRegistry.completeHandshake] when a new connection
/// replaces an existing one for the same [NodeId].
///
/// The caller should disconnect the replaced endpoint at the platform level
/// to avoid leaving a stale BLE connection on the remote device.
class ReplacedEndpoint {
  final EndpointId endpointId;
  const ReplacedEndpoint(this.endpointId);
}

/// Aggregate root managing connections and pending handshakes.
///
/// Enforces the invariant that a [NodeId] can only be associated with
/// one [EndpointId] at a time. If the same [NodeId] connects via a new
/// endpoint, the old connection is replaced.
class ConnectionRegistry {
  final Map<EndpointId, Connection> _connections = {};
  final Set<EndpointId> _pendingHandshakes = {};
  final Map<NodeId, EndpointId> _nodeIdToEndpointId = {};

  /// Registers that a handshake is in progress for the given endpoint.
  void registerPendingHandshake(EndpointId endpointId) {
    _pendingHandshakes.add(endpointId);
  }

  /// Checks if there's a pending handshake for the given endpoint.
  bool hasPendingHandshake(EndpointId endpointId) {
    return _pendingHandshakes.contains(endpointId);
  }

  /// Completes the handshake, creating a connection.
  ///
  /// If the [nodeId] is already associated with a different endpoint,
  /// the old connection is removed (enforcing NodeId uniqueness) and
  /// a [ReplacedEndpoint] is returned so the caller can disconnect
  /// the stale platform connection.
  ///
  /// Returns [ReplacedEndpoint] if a duplicate was replaced, or `null`.
  ReplacedEndpoint? completeHandshake(Endpoint endpoint, NodeId nodeId) {
    _pendingHandshakes.remove(endpoint.id);

    ReplacedEndpoint? replaced;
    final existingEndpointId = _nodeIdToEndpointId[nodeId];
    if (existingEndpointId != null && existingEndpointId != endpoint.id) {
      _connections.remove(existingEndpointId);
      _pendingHandshakes.remove(existingEndpointId);
      replaced = ReplacedEndpoint(existingEndpointId);
    }

    final connection = Connection(
      endpoint: endpoint,
      nodeId: nodeId,
      connectedAt: DateTime.now(),
    );

    _connections[endpoint.id] = connection;
    _nodeIdToEndpointId[nodeId] = endpoint.id;

    return replaced;
  }

  /// Cancels a pending handshake.
  ///
  /// Returns [HandshakeFailed] event if there was a pending handshake,
  /// or null if there was nothing to cancel.
  HandshakeFailed? cancelPendingHandshake(
    EndpointId endpointId,
    String reason,
  ) {
    if (!_pendingHandshakes.remove(endpointId)) {
      return null;
    }

    return HandshakeFailed(
      endpoint: Endpoint(id: endpointId, displayName: ''),
      reason: reason,
    );
  }

  /// Removes an established connection.
  ///
  /// Returns [ConnectionClosed] event if there was a connection to remove,
  /// or null if there was no connection.
  ConnectionClosed? removeConnection(EndpointId endpointId, String reason) {
    final connection = _connections.remove(endpointId);
    if (connection == null) {
      return null;
    }

    _nodeIdToEndpointId.remove(connection.nodeId);

    return ConnectionClosed(nodeId: connection.nodeId, reason: reason);
  }

  /// Gets the connection for the given endpoint, if it exists.
  Connection? getConnection(EndpointId endpointId) {
    return _connections[endpointId];
  }

  /// Gets the NodeId for the given endpoint, if connected.
  NodeId? getNodeIdForEndpoint(EndpointId endpointId) {
    return _connections[endpointId]?.nodeId;
  }

  /// Gets the EndpointId for the given NodeId, if connected.
  EndpointId? getEndpointIdForNodeId(NodeId nodeId) {
    return _nodeIdToEndpointId[nodeId];
  }

  /// All active connections.
  Iterable<Connection> get connections => _connections.values;

  /// Number of active connections.
  int get connectionCount => _connections.length;

  /// Number of pending handshakes.
  int get pendingHandshakeCount => _pendingHandshakes.length;
}
