import 'package:gossip/gossip.dart';

/// Events emitted when peer connection state changes.
///
/// Listen to these events to add/remove peers from the gossip coordinator.
sealed class PeerEvent {
  const PeerEvent();
}

/// Emitted when a peer has connected and completed the handshake.
///
/// The [nodeId] is the application-provided stable identifier exchanged
/// during the handshake, not the Nearby endpoint ID.
class PeerConnected extends PeerEvent {
  final NodeId nodeId;

  const PeerConnected(this.nodeId);

  @override
  String toString() => 'PeerConnected($nodeId)';
}

/// Emitted when a peer has disconnected.
class PeerDisconnected extends PeerEvent {
  final NodeId nodeId;

  /// The reason for disconnection, if known.
  final DisconnectReason reason;

  const PeerDisconnected(this.nodeId, {this.reason = DisconnectReason.unknown});

  @override
  String toString() => 'PeerDisconnected($nodeId, reason: $reason)';
}

/// Reasons why a peer may have disconnected.
enum DisconnectReason {
  /// The remote peer initiated the disconnect.
  remoteDisconnect,

  /// The local device initiated the disconnect.
  localDisconnect,

  /// The connection was lost (e.g., out of range).
  connectionLost,

  /// The handshake failed or timed out.
  handshakeFailed,

  /// Unknown reason.
  unknown,
}
