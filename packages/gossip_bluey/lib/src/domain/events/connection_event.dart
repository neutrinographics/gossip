import 'package:gossip/gossip.dart';

import '../value_objects/ble_address.dart';

/// Domain events emitted by `ConnectionManager` as connections come and go.
sealed class ConnectionEvent {
  const ConnectionEvent();
}

/// Emitted when a peer connection has been established and is ready for
/// gossip traffic. [address] is the BLE address (or platform-equivalent
/// stable peer identifier on iOS) of the remote, propagated from
/// `PortPeerConnected.address`. Consumers use it to dedup against a
/// previously-emitted scan candidate that named the same address.
final class PeerOpened extends ConnectionEvent {
  final NodeId nodeId;
  final BleAddress address;
  final String? displayName;

  const PeerOpened({
    required this.nodeId,
    required this.address,
    this.displayName,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PeerOpened &&
          other.nodeId == nodeId &&
          other.address == address &&
          other.displayName == displayName);

  @override
  int get hashCode => Object.hash(nodeId, address, displayName);
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
