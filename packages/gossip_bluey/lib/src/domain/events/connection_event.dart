import 'package:gossip/gossip.dart';

/// Domain events emitted by `ConnectionService` as connections come and go.
sealed class ConnectionEvent {
  const ConnectionEvent();
}

/// Emitted when a peer connection has been established and is ready for
/// gossip traffic.
final class PeerOpened extends ConnectionEvent {
  final NodeId nodeId;
  final String? displayName;

  const PeerOpened({required this.nodeId, this.displayName});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PeerOpened &&
          other.nodeId == nodeId &&
          other.displayName == displayName);

  @override
  int get hashCode => Object.hash(nodeId, displayName);
}

/// Emitted when a peer connection has been torn down.
final class PeerClosed extends ConnectionEvent {
  final NodeId nodeId;
  final String reason;

  const PeerClosed({required this.nodeId, required this.reason});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PeerClosed && other.nodeId == nodeId && other.reason == reason);

  @override
  int get hashCode => Object.hash(nodeId, reason);
}
