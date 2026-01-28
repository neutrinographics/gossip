import 'package:gossip/gossip.dart';

import '../value_objects/endpoint_id.dart';

/// Base class for connection-related errors.
sealed class ConnectionError implements Exception {
  const ConnectionError();
}

/// Tried to send to a NodeId with no active connection.
class ConnectionNotFound extends ConnectionError {
  final NodeId nodeId;

  const ConnectionNotFound(this.nodeId);

  @override
  String toString() => 'ConnectionNotFound(nodeId: $nodeId)';
}

/// Handshake didn't complete within the timeout period.
class HandshakeTimeout extends ConnectionError {
  final EndpointId endpointId;

  const HandshakeTimeout(this.endpointId);

  @override
  String toString() => 'HandshakeTimeout(endpointId: $endpointId)';
}

/// Received malformed handshake data.
class HandshakeInvalid extends ConnectionError {
  final EndpointId endpointId;
  final String reason;

  const HandshakeInvalid(this.endpointId, this.reason);

  @override
  String toString() =>
      'HandshakeInvalid(endpointId: $endpointId, reason: $reason)';
}

/// Failed to send bytes over Nearby Connections.
class SendFailed extends ConnectionError {
  final NodeId nodeId;
  final String reason;

  const SendFailed(this.nodeId, this.reason);

  @override
  String toString() => 'SendFailed(nodeId: $nodeId, reason: $reason)';
}
