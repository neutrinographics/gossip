import 'package:gossip/gossip.dart';

import '../entities/connection_handle.dart';

/// Tracks active connections, keyed by NodeId. Enforces NodeId-uniqueness:
/// adding a second handle for the same NodeId returns the previous handle
/// so the caller can tear it down.
class ConnectionRegistry {
  final Map<NodeId, ConnectionHandle> _byNodeId = {};

  int get connectionCount => _byNodeId.length;

  Iterable<ConnectionHandle> get connections => _byNodeId.values;

  bool contains(NodeId nodeId) => _byNodeId.containsKey(nodeId);

  ConnectionHandle? get(NodeId nodeId) => _byNodeId[nodeId];

  /// Adds [handle]. Returns the previous handle for the same NodeId if
  /// one existed (caller is responsible for tearing it down), or null
  /// if this is a fresh registration.
  ConnectionHandle? add(ConnectionHandle handle) {
    final previous = _byNodeId[handle.nodeId];
    _byNodeId[handle.nodeId] = handle;
    return previous;
  }

  /// Removes the handle for [nodeId]. Returns it, or null if absent.
  ConnectionHandle? remove(NodeId nodeId) => _byNodeId.remove(nodeId);
}
