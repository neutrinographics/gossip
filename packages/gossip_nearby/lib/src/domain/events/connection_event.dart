import 'package:gossip/gossip.dart';

import '../value_objects/endpoint.dart';

/// Base class for connection-related domain events.
sealed class ConnectionEvent {
  const ConnectionEvent();
}

/// Emitted when a handshake completes successfully.
///
/// At this point, the connection is ready for gossip communication.
/// The [endpoint] is the Nearby Connections endpoint, and [nodeId] is
/// the application-level peer identifier exchanged during handshake.
/// The [displayName] is the human-readable name provided by the peer.
class HandshakeCompleted extends ConnectionEvent {
  final Endpoint endpoint;
  final NodeId nodeId;
  final String? displayName;

  const HandshakeCompleted({
    required this.endpoint,
    required this.nodeId,
    this.displayName,
  });

  @override
  String toString() =>
      'HandshakeCompleted(endpoint: $endpoint, nodeId: $nodeId, '
      'displayName: $displayName)';
}

/// Emitted when a handshake fails.
///
/// The connection will not be usable for gossip communication.
class HandshakeFailed extends ConnectionEvent {
  final Endpoint endpoint;
  final String reason;

  const HandshakeFailed({required this.endpoint, required this.reason});

  @override
  String toString() => 'HandshakeFailed(endpoint: $endpoint, reason: $reason)';
}

/// Emitted when an established connection is closed.
class ConnectionClosed extends ConnectionEvent {
  final NodeId nodeId;
  final String reason;

  const ConnectionClosed({required this.nodeId, required this.reason});

  @override
  String toString() => 'ConnectionClosed(nodeId: $nodeId, reason: $reason)';
}
