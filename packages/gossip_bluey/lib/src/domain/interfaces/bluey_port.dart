import 'dart:typed_data';

import 'package:gossip/gossip.dart';

import '../value_objects/discovered_peer.dart';
import '../value_objects/service_uuid.dart';

/// Domain abstraction over the bluey library. Speaks only in domain types
/// — bluey's `BlueyPeer`/`PeerConnection`/`Server`/`PeerClient` are
/// internal to the infrastructure adapter.
///
/// Tests substitute an in-memory implementation; production wires
/// `BlueyPortImpl` (which holds a real `Bluey` instance).
abstract interface class BlueyPort {
  /// Begin advertising as a gossip-speaking peripheral.
  ///
  /// Constructs the GATT server (with [localNodeId] embedded as the
  /// bluey `ServerId`), registers the gossip service, and starts
  /// advertising with the bluey lifecycle control service in the payload
  /// so other devices can find us via discovery.
  Future<void> startAdvertising({
    required ServiceUuid serviceUuid,
    required String displayName,
    required NodeId localNodeId,
  });

  Future<void> stopAdvertising();

  /// Run a single discovery round. Returns peers that advertised our
  /// gossip service, deduplicated by `NodeId`.
  Future<List<DiscoveredPeer>> discoverPeers({
    required ServiceUuid serviceUuid,
    Duration timeout = const Duration(seconds: 5),
  });

  /// Initiate a central-role connection to [target]. Completes when the
  /// connection has been established and the gossip characteristic
  /// subscribed; throws on failure.
  Future<void> connect(NodeId target);

  /// Disconnect [nodeId] (whichever role we hold for that peer).
  Future<void> disconnect(NodeId nodeId);

  /// Send [data] to [nodeId]. Internally selects write (central role) or
  /// notify (peripheral role) based on the held connection. Throws on
  /// failure (transient or permanent).
  Future<void> sendData(NodeId nodeId, Uint8List data);

  /// Stream of role-agnostic transport events.
  Stream<BlueyPortEvent> get events;

  Future<void> dispose();
}

/// Sealed event hierarchy emitted by BlueyPort.events.
sealed class BlueyPortEvent {
  const BlueyPortEvent();
}

/// A bluey-confirmed peer is now connected (either we initiated or they
/// did). [role] tells the consumer which API to use for sends — but
/// BlueyPort.sendData hides that detail anyway.
final class PortPeerConnected extends BlueyPortEvent {
  final NodeId nodeId;
  final ConnectionRole role;
  final String? displayName;
  const PortPeerConnected({
    required this.nodeId,
    required this.role,
    this.displayName,
  });
}

final class PortPeerDisconnected extends BlueyPortEvent {
  final NodeId nodeId;
  final String reason;
  const PortPeerDisconnected({required this.nodeId, required this.reason});
}

/// Bytes received from a peer (already extracted from notification or
/// write request — pre-framing).
final class PortPeerData extends BlueyPortEvent {
  final NodeId nodeId;
  final Uint8List data;
  const PortPeerData({required this.nodeId, required this.data});
}

/// A central-role connect attempt failed.
final class PortConnectFailed extends BlueyPortEvent {
  final NodeId nodeId;
  final String reason;
  const PortConnectFailed({required this.nodeId, required this.reason});
}

enum ConnectionRole { central, peripheral }
