import 'dart:typed_data';

import 'package:gossip/gossip.dart';

import '../value_objects/discovered_peer.dart';
import '../value_objects/scan_candidate.dart';
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

  /// Verify Bluetooth is on / supported / authorized at the OS layer.
  /// Throws a platform-specific exception if not. Routed through the
  /// port (rather than `Bluey.shared.ensureReady()`) so apps don't have
  /// to instantiate a second Bluey instance — that creates duplicate
  /// Dart-side platform listeners and observably breaks discovery on iOS.
  Future<void> ensureReady();

  /// Run a single discovery round. Returns peers that advertised our
  /// gossip service, deduplicated by `NodeId`.
  @Deprecated('Use scanForCandidates + connectAndIdentify instead')
  Future<List<DiscoveredPeer>> discoverPeers({
    required ServiceUuid serviceUuid,
    Duration timeout = const Duration(seconds: 5),
  });

  /// Long-lived scan filtered by the gossip service UUID. Emits a
  /// [ScanCandidate] per advertisement seen — the same device may be
  /// emitted repeatedly (BLE scans stream continuously). Caller is
  /// responsible for dedup.
  Stream<ScanCandidate> scanForCandidates({required ServiceUuid serviceUuid});

  /// Stop the active scan started by [scanForCandidates], if any.
  /// Idempotent.
  Future<void> stopScan();

  /// Connect to [candidate] and read the remote NodeId from the bluey
  /// control characteristic. Returns the NodeId on success; throws on
  /// connection failure or if the device is not a bluey peer.
  Future<NodeId> connectAndIdentify(ScanCandidate candidate);

  /// Disconnect a specific role's link to [nodeId]. Used by race-loser
  /// cleanup, where [disconnect] (which prefers central) is too coarse.
  Future<void> disconnectRole(NodeId nodeId, ConnectionRole role);

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

  /// Effective per-chunk payload size for [nodeId]: the negotiated ATT
  /// payload (MTU - 3) minus a small safety margin. Falls back to 20
  /// (the BLE default with no negotiation) if the peer is unknown or
  /// MTU has not yet been read.
  int chunkSizeFor(NodeId nodeId);

  /// Stream of role-agnostic transport events.
  Stream<BlueyPortEvent> get events;

  /// Diagnostic log lines from the underlying BLE library, formatted as
  /// human-readable strings. Useful for debugging discovery and
  /// connection issues. Emits the empty stream for adapter implementations
  /// that have no underlying library to surface (e.g. the in-memory fake).
  Stream<String> get diagnosticLog;

  /// Diagnostic event lines from the underlying BLE library (scan
  /// started/stopped, device discovered, connecting, connected, etc.).
  /// Same caveat as [diagnosticLog] for adapters with nothing to surface.
  Stream<String> get diagnosticEvents;

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
  final ConnectionRole role;
  final String reason;
  const PortPeerDisconnected({
    required this.nodeId,
    required this.role,
    required this.reason,
  });
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
