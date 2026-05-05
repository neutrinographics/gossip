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

  /// First-write-wins registration. Returns [Registered] if [handle] was
  /// stored, or [DuplicateRejected] if a handle for this NodeId already
  /// exists (existing handle is left in place; caller should tear down
  /// the rejected handle's underlying connection).
  RegistrationResult tryRegister(ConnectionHandle handle) {
    final existing = _byNodeId[handle.nodeId];
    if (existing != null) {
      return DuplicateRejected(existing: existing, attempted: handle);
    }
    _byNodeId[handle.nodeId] = handle;
    return Registered(handle);
  }
}

sealed class RegistrationResult {
  const RegistrationResult();
}

final class Registered extends RegistrationResult {
  final ConnectionHandle handle;
  const Registered(this.handle);
}

final class DuplicateRejected extends RegistrationResult {
  final ConnectionHandle existing;
  final ConnectionHandle attempted;
  const DuplicateRejected({required this.existing, required this.attempted});
}
