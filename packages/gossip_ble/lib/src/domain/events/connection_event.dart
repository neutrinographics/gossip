import 'package:gossip/gossip.dart';
import 'package:meta/meta.dart';

import '../value_objects/device_id.dart';

/// Base class for connection-related domain events.
///
/// Domain events are immutable records of something that happened.
/// They should be treated as value objects for equality comparisons.
@immutable
sealed class ConnectionEvent {
  /// When this event occurred.
  final DateTime occurredAt;

  ConnectionEvent({DateTime? occurredAt})
    : occurredAt = occurredAt ?? DateTime.now();
}

/// Emitted when a handshake completes successfully.
///
/// At this point, the connection is ready for gossip communication.
@immutable
final class HandshakeCompleted extends ConnectionEvent {
  final DeviceId deviceId;
  final NodeId nodeId;

  HandshakeCompleted({
    required this.deviceId,
    required this.nodeId,
    super.occurredAt,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HandshakeCompleted &&
          runtimeType == other.runtimeType &&
          deviceId == other.deviceId &&
          nodeId == other.nodeId;

  @override
  int get hashCode => Object.hash(deviceId, nodeId);

  @override
  String toString() =>
      'HandshakeCompleted(deviceId: $deviceId, nodeId: $nodeId)';
}

/// Emitted when a handshake fails.
@immutable
final class HandshakeFailed extends ConnectionEvent {
  final DeviceId deviceId;
  final String reason;

  HandshakeFailed({
    required this.deviceId,
    required this.reason,
    super.occurredAt,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HandshakeFailed &&
          runtimeType == other.runtimeType &&
          deviceId == other.deviceId &&
          reason == other.reason;

  @override
  int get hashCode => Object.hash(deviceId, reason);

  @override
  String toString() => 'HandshakeFailed(deviceId: $deviceId, reason: $reason)';
}

/// Emitted when an established connection is closed.
@immutable
final class ConnectionClosed extends ConnectionEvent {
  final NodeId nodeId;
  final String reason;

  ConnectionClosed({
    required this.nodeId,
    required this.reason,
    super.occurredAt,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConnectionClosed &&
          runtimeType == other.runtimeType &&
          nodeId == other.nodeId &&
          reason == other.reason;

  @override
  int get hashCode => Object.hash(nodeId, reason);

  @override
  String toString() => 'ConnectionClosed(nodeId: $nodeId, reason: $reason)';
}
