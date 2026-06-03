import 'dart:typed_data';

import 'package:bluey/bluey.dart' as bluey;
import 'package:gossip/gossip.dart';

import '../value_objects/ble_address.dart';
import '../value_objects/bluetooth_adapter_state.dart';
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

  /// Current advertising lifecycle state — derived from the underlying
  /// bluey `Server.advertisingState`. Reflects platform reality, not the
  /// consumer's last call to [startAdvertising]. Stable across the
  /// starting/stopping transient windows; transitions to
  /// [bluey.AdvertisingState.invalidated] after an adapter cycle. The
  /// matching [advertisingStateStream] replays this value on subscribe.
  bluey.AdvertisingState get advertisingState;

  /// Stream of advertising-state transitions. Replays the current value
  /// on subscribe (Stream.multi pattern; matches bluey's I334 convention
  /// for `Server.advertisingStateChanges`), then emits every subsequent
  /// transition. Multi-listener — each subscriber gets its own
  /// replay-current emission.
  Stream<bluey.AdvertisingState> get advertisingStateStream;

  /// Current scan lifecycle state — derived from the underlying bluey
  /// `Scanner.state`. Reflects platform reality, not the consumer's last
  /// call to [scanForCandidates]. Stable across the starting/stopping
  /// transient windows; transitions to [bluey.ScanState.invalidated]
  /// after an adapter cycle. The matching [scanStateStream] replays this
  /// value on subscribe.
  bluey.ScanState get scanState;

  /// Stream of scan-state transitions. Replays the current value on
  /// subscribe, then emits every subsequent transition. Multi-listener.
  Stream<bluey.ScanState> get scanStateStream;

  /// Stream of role-agnostic transport events.
  Stream<BlueyPortEvent> get events;

  /// Last-known Bluetooth adapter state. Synchronous; backed by an
  /// internal cache that [bluetoothStateStream] keeps current.
  BluetoothAdapterState get bluetoothAdapterState;

  /// Stream of every Bluetooth adapter transition. Broadcast; emits the
  /// current value on subscription, then every transition. While the
  /// state is anything other than [BluetoothAdapterState.on], all
  /// lifecycle and per-peer operation methods on this port throw
  /// `BluetoothUnavailableException`.
  Stream<BluetoothAdapterState> get bluetoothStateStream;

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
/// BlueyPort.sendData hides that detail anyway. [address] is the BLE
/// address (or platform-equivalent stable peer identifier on iOS) for
/// the remote, populated from `peerClient.client.id` on the peripheral
/// side and from the originating `ScanCandidate.address` on the central
/// side. Used by ConnectionService to dedup scan candidates against
/// existing connections.
final class PortPeerConnected extends BlueyPortEvent {
  final NodeId nodeId;
  final ConnectionRole role;
  final BleAddress address;
  final String? displayName;
  const PortPeerConnected({
    required this.nodeId,
    required this.role,
    required this.address,
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
