import 'dart:async';

import 'package:bluey/bluey.dart' as bluey;
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/gossip_bluey.dart';

/// Service for managing Nearby Connections peer connections.
///
/// This is an application layer service that bridges the BlueyTransport
/// (infrastructure) with the Coordinator (domain).
class ConnectionService {
  final BlueyTransport _transport;
  final Coordinator _coordinator;

  StreamSubscription<PeerEvent>? _peerSubscription;

  ConnectionService({
    required BlueyTransport transport,
    required Coordinator coordinator,
  }) : _transport = transport,
       _coordinator = coordinator {
    _setupPeerEventHandling();
  }

  void _setupPeerEventHandling() {
    _peerSubscription = _transport.peerEvents.listen((event) {
      switch (event) {
        case PeerConnected(:final nodeId, :final displayName):
          _coordinator.addPeer(nodeId, displayName: displayName);
        case PeerDisconnected(:final nodeId):
          _coordinator.removePeer(nodeId);
      }
    });
  }

  /// Starts advertising this device to nearby peers.
  Future<void> startAdvertising() async {
    await _transport.startAdvertising();
  }

  /// Stops advertising.
  Future<void> stopAdvertising() async {
    await _transport.stopAdvertising();
  }

  /// Starts discovering nearby peers. Discovered candidates surface on
  /// [BlueyTransport.candidates] / [BlueyTransport.candidateEvents].
  /// Connection decisions are governed by [BlueyTransport.connectionMode]
  /// (manual by default; the consumer must call
  /// [BlueyTransport.connectTo] explicitly, or switch to
  /// [ConnectionMode.auto] for mesh-style auto-connect).
  Future<void> startDiscovery() async {
    await _transport.startDiscovery();
  }

  /// Stops discovery.
  Future<void> stopDiscovery() async {
    await _transport.stopDiscovery();
  }

  /// Disconnects all connected peers.
  Future<void> disconnectAll() async {
    await _transport.disconnectAll();
  }

  /// Verify Bluetooth is on / supported / authorized at the OS layer.
  Future<void> ensureReady() => _transport.ensureReady();

  /// Whether advertising is currently active.
  // TODO(Phase D): rewrite to consume transport.advertisingStateStream and
  // surface the full AdvertisingState enum (idle/starting/advertising/
  // stopping) in ChatController status, rather than collapsing the four
  // states into a single boolean here. Callers in the UI can then
  // distinguish "starting up" from "running" and "stopping" from "off"
  // without polling.
  bool get isAdvertising =>
      _transport.advertisingState == bluey.AdvertisingState.advertising;

  /// Whether discovery is currently active.
  // TODO(Phase D): rewrite to consume transport.scanStateStream and
  // surface the full ScanState enum (stopped/starting/scanning/stopping)
  // in ChatController status, rather than collapsing the four states
  // into a single boolean here. Callers in the UI can then distinguish
  // "starting up" from "running" and "stopping" from "off" without
  // polling.
  bool get isDiscovering =>
      _transport.scanState == bluey.ScanState.scanning;

  /// Current Bluetooth adapter state.
  BluetoothAdapterState get bluetoothAdapterState =>
      _transport.bluetoothAdapterState;

  /// Stream of Bluetooth adapter transitions. Replays the current value
  /// on subscription.
  Stream<BluetoothAdapterState> get bluetoothStateStream =>
      _transport.bluetoothStateStream;

  /// Stream of advertising lifecycle transitions
  /// (idle/starting/advertising/stopping/invalidated). Replays the
  /// current value on subscription.
  Stream<bluey.AdvertisingState> get advertisingStateStream =>
      _transport.advertisingStateStream;

  /// Stream of scan lifecycle transitions
  /// (stopped/starting/scanning/stopping/invalidated). Replays the
  /// current value on subscription.
  Stream<bluey.ScanState> get scanStateStream => _transport.scanStateStream;

  /// Currently connected peer count.
  int get connectedPeerCount => _transport.connectedPeerCount;

  /// Stream of peer events from transport.
  Stream<PeerEvent> get peerEvents => _transport.peerEvents;

  /// Per-event scan candidate stream from the BLE scanner.
  Stream<ScanCandidate> get candidateEvents => _transport.candidateEvents;

  /// Snapshot stream of the current discovery candidate set.
  Stream<List<ScanCandidate>> get candidates => _transport.candidates;

  /// Snapshot of currently-known discovery candidates, in insertion order.
  List<ScanCandidate> get currentCandidates => _transport.currentCandidates;

  /// Current auto-connect policy mode.
  ConnectionMode get connectionMode => _transport.connectionMode;

  /// Sets the auto-connect policy mode (manual/auto).
  void setConnectionMode(ConnectionMode mode) =>
      _transport.setConnectionMode(mode);

  /// Initiates a connection to a discovered candidate.
  Future<NodeId> connectTo(ScanCandidate candidate) =>
      _transport.connectTo(candidate);

  /// Initiates a connection to the candidate currently known for [address].
  /// Throws [StateError] if no such candidate exists.
  Future<NodeId> connectByAddress(BleAddress address) =>
      _transport.connectByAddress(address);

  /// Disconnects a specific peer.
  Future<void> disconnect(NodeId nodeId) => _transport.disconnect(nodeId);

  /// Stream of connection errors for observability.
  Stream<ConnectionError> get errors => _transport.errors;

  /// Diagnostic log lines from bluey itself (scan results, GATT
  /// operations, lifecycle heartbeats, platform errors).
  Stream<String> get diagnosticLog => _transport.diagnosticLog;

  /// Diagnostic events from bluey itself (scan started/stopped,
  /// device discovered, connecting, connected, etc.).
  Stream<String> get diagnosticEvents => _transport.diagnosticEvents;

  /// Metrics for monitoring transport health and performance.
  BlueyMetrics get metrics => _transport.metrics;

  /// Disposes resources.
  Future<void> dispose() async {
    await _peerSubscription?.cancel();
  }
}
