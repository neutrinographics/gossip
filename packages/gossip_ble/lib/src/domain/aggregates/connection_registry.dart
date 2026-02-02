import 'package:gossip/gossip.dart';

import '../entities/ble_connection.dart';
import '../events/connection_event.dart';
import '../value_objects/device_id.dart';

/// Aggregate root managing BLE connections and pending handshakes.
///
/// ## Invariants
///
/// This aggregate enforces the following invariants:
///
/// 1. **NodeId Uniqueness**: A [NodeId] can only be associated with one
///    [DeviceId] at a time. This handles the case where a peer reconnects
///    from a different BLE address (common on iOS where addresses rotate).
///
/// ## Connection Replacement Behavior
///
/// When a new handshake completes with a [NodeId] that's already connected
/// via a different [DeviceId], the old connection is **silently removed**
/// and replaced with the new one. This is intentional:
///
/// - On iOS, BLE addresses rotate frequently for privacy
/// - A peer might reconnect quickly after a network hiccup
/// - The most recent connection is assumed to be the valid one
///
/// **Note**: No [ConnectionClosed] event is emitted for the replaced
/// connection. Applications that need to track this should compare
/// the [DeviceId] in sequential [HandshakeCompleted] events for the
/// same [NodeId].
///
/// ## Thread Safety
///
/// This class is NOT thread-safe. All access should be from the same
/// isolate (typically the main isolate in Flutter).
class ConnectionRegistry {
  final Map<DeviceId, BleConnection> _connections = {};
  final Set<DeviceId> _pendingHandshakes = {};
  final Map<NodeId, DeviceId> _nodeIdToDeviceId = {};

  /// Registers that a handshake is in progress for the given device.
  void registerPendingHandshake(DeviceId deviceId) {
    _pendingHandshakes.add(deviceId);
  }

  /// Checks if there's a pending handshake for the given device.
  bool hasPendingHandshake(DeviceId deviceId) {
    return _pendingHandshakes.contains(deviceId);
  }

  /// Completes the handshake, creating a connection.
  ///
  /// If the [nodeId] is already associated with a different device,
  /// the old connection is silently removed (enforcing NodeId uniqueness).
  /// See class documentation for details on this replacement behavior.
  ///
  /// Returns [HandshakeCompleted] event for the new connection.
  HandshakeCompleted completeHandshake(DeviceId deviceId, NodeId nodeId) {
    _pendingHandshakes.remove(deviceId);

    // Enforce NodeId uniqueness - silently remove any existing connection
    // with the same NodeId. This handles reconnection from a different BLE
    // address (common on iOS where addresses rotate for privacy).
    final existingDeviceId = _nodeIdToDeviceId[nodeId];
    if (existingDeviceId != null && existingDeviceId != deviceId) {
      _connections.remove(existingDeviceId);
    }

    final connection = BleConnection(
      deviceId: deviceId,
      nodeId: nodeId,
      connectedAt: DateTime.now(),
    );

    _connections[deviceId] = connection;
    _nodeIdToDeviceId[nodeId] = deviceId;

    return HandshakeCompleted(deviceId: deviceId, nodeId: nodeId);
  }

  /// Cancels a pending handshake.
  ///
  /// Returns [HandshakeFailed] event if there was a pending handshake,
  /// or null if there was nothing to cancel.
  HandshakeFailed? cancelPendingHandshake(DeviceId deviceId, String reason) {
    if (!_pendingHandshakes.remove(deviceId)) {
      return null;
    }

    return HandshakeFailed(deviceId: deviceId, reason: reason);
  }

  /// Removes an established connection.
  ///
  /// Returns [ConnectionClosed] event if there was a connection to remove,
  /// or null if there was no connection.
  ConnectionClosed? removeConnection(DeviceId deviceId, String reason) {
    final connection = _connections.remove(deviceId);
    if (connection == null) {
      return null;
    }

    _nodeIdToDeviceId.remove(connection.nodeId);

    return ConnectionClosed(nodeId: connection.nodeId, reason: reason);
  }

  /// Gets the connection for the given device, if it exists.
  BleConnection? getConnection(DeviceId deviceId) {
    return _connections[deviceId];
  }

  /// Gets the NodeId for the given device, if connected.
  NodeId? getNodeIdForDevice(DeviceId deviceId) {
    return _connections[deviceId]?.nodeId;
  }

  /// Gets the DeviceId for the given NodeId, if connected.
  DeviceId? getDeviceIdForNode(NodeId nodeId) {
    return _nodeIdToDeviceId[nodeId];
  }

  /// All active connections.
  Iterable<BleConnection> get connections => _connections.values;

  /// Number of active connections.
  int get connectionCount => _connections.length;

  /// Number of pending handshakes.
  int get pendingHandshakeCount => _pendingHandshakes.length;
}
