import 'dart:async';

import 'package:bluey/bluey.dart' as bluey;
import 'package:gossip/gossip.dart';
import 'package:meta/meta.dart';

import '../application/observability/bluey_metrics.dart';
import '../application/services/auto_connect_policy.dart';
import '../application/services/connection_manager.dart';
import '../application/services/discovery_service.dart';
import '../domain/aggregates/connection_registry.dart';
import '../domain/errors/connection_error.dart';
import '../domain/events/connection_event.dart';
import '../domain/interfaces/bluey_port.dart';
import '../domain/value_objects/ble_address.dart';
import '../domain/value_objects/bluetooth_adapter_state.dart';
import '../domain/value_objects/connection_mode.dart';
import '../domain/value_objects/scan_candidate.dart';
import '../domain/value_objects/service_uuid.dart';
import '../infrastructure/adapters/bluey_port_impl.dart';
import '../infrastructure/ports/bluey_message_port.dart';

/// Sealed event hierarchy emitted by [BlueyTransport.peerEvents].
sealed class PeerEvent {
  const PeerEvent();
}

final class PeerConnected extends PeerEvent {
  final NodeId nodeId;
  final String? displayName;
  const PeerConnected(this.nodeId, {this.displayName});
}

final class PeerDisconnected extends PeerEvent {
  final NodeId nodeId;
  const PeerDisconnected(this.nodeId);
}

/// Public facade for the bluey BLE transport. Mirrors the shape of
/// `NearbyTransport` from `gossip_nearby`.
class BlueyTransport {
  BlueyTransport._({
    required this.localNodeId,
    required ServiceUuid serviceUuid,
    required String displayName,
    required BlueyPort port,
    required ConnectionManager service,
    required DiscoveryService discovery,
    required AutoConnectPolicy autoConnect,
    required BlueyMessagePort messagePort,
  }) : _serviceUuid = serviceUuid,
       _displayName = displayName,
       _port = port,
       _service = service,
       _discovery = discovery,
       _autoConnect = autoConnect,
       _messagePort = messagePort {
    _eventSub = service.events.listen(_onEvent);
  }

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  /// Creates a transport using the real bluey adapter. Validates the
  /// resolved NodeId is a well-formed UUID before any BLE activity.
  static Future<BlueyTransport> create({
    required LocalNodeRepository localNodeRepository,
    required ServiceUuid serviceUuid,
    required String displayName,
    int? maxConnections,
    int? targetConnections,
    @Deprecated(
      'No-op since the scan-upgrade migration; scan is now '
      'long-lived and does not run on a fixed interval.',
    )
    Duration discoveryInterval = const Duration(seconds: 30),
    LogCallback? onLog,
  }) async {
    final nodeId = await localNodeRepository.resolveNodeId();
    if (!_uuidPattern.hasMatch(nodeId.value.toLowerCase())) {
      throw ArgumentError.value(
        nodeId.value,
        'localNodeId',
        'gossip_bluey requires NodeId to be a well-formed UUID',
      );
    }
    final port = await BlueyPortImpl.create(localNodeId: nodeId);
    final registry = ConnectionRegistry();
    final metrics = BlueyMetrics();
    final service = ConnectionManager(
      port: port,
      registry: registry,
      metrics: metrics,
      maxConnections: maxConnections,
      onLog: onLog,
    );
    final discovery = DiscoveryService(port: port, serviceUuid: serviceUuid);
    final autoConnect = AutoConnectPolicy(
      discovery: discovery,
      connections: service,
      registry: registry,
      now: DateTime.now,
      targetConnections: targetConnections,
      onLog: onLog,
    );
    return BlueyTransport._(
      localNodeId: nodeId,
      serviceUuid: serviceUuid,
      displayName: displayName,
      port: port,
      service: service,
      discovery: discovery,
      autoConnect: autoConnect,
      messagePort: BlueyMessagePort(service),
    );
  }

  /// Test-only constructor that wires a `BlueyPort` directly.
  factory BlueyTransport.testing({
    required NodeId localNodeId,
    required ServiceUuid serviceUuid,
    required String displayName,
    required BlueyPort port,
    int? maxConnections,
    int? targetConnections,
    @Deprecated(
      'No-op since the scan-upgrade migration; scan is now '
      'long-lived and does not run on a fixed interval.',
    )
    Duration discoveryInterval = const Duration(seconds: 5),
    LogCallback? onLog,
  }) {
    final registry = ConnectionRegistry();
    final metrics = BlueyMetrics();
    final service = ConnectionManager(
      port: port,
      registry: registry,
      metrics: metrics,
      maxConnections: maxConnections,
      onLog: onLog,
    );
    final discovery = DiscoveryService(port: port, serviceUuid: serviceUuid);
    final autoConnect = AutoConnectPolicy(
      discovery: discovery,
      connections: service,
      registry: registry,
      now: DateTime.now,
      targetConnections: targetConnections,
      onLog: onLog,
    );
    final mp = BlueyMessagePort(service);
    return BlueyTransport._(
      localNodeId: localNodeId,
      serviceUuid: serviceUuid,
      displayName: displayName,
      port: port,
      service: service,
      discovery: discovery,
      autoConnect: autoConnect,
      messagePort: mp,
    );
  }

  final NodeId localNodeId;
  final ServiceUuid _serviceUuid;
  final String _displayName;
  final BlueyPort _port;
  final ConnectionManager _service;
  final DiscoveryService _discovery;
  final AutoConnectPolicy _autoConnect;
  final BlueyMessagePort _messagePort;

  late final StreamSubscription<ConnectionEvent> _eventSub;
  final StreamController<PeerEvent> _peers =
      StreamController<PeerEvent>.broadcast();

  /// Current advertising lifecycle state. Derived from the underlying
  /// bluey `Server.advertisingState`; reflects platform reality, not the
  /// consumer's last call to [startAdvertising]. The matching
  /// [advertisingStateStream] replays this value on subscribe.
  bluey.AdvertisingState get advertisingState => _port.advertisingState;

  /// Stream of advertising-state transitions. Replays the current value
  /// on subscribe (Stream.multi pattern), then emits every subsequent
  /// transition. Multi-listener.
  Stream<bluey.AdvertisingState> get advertisingStateStream =>
      _port.advertisingStateStream;

  /// Current scan lifecycle state. Derived from the underlying bluey
  /// `Scanner.state`; reflects platform reality, not the consumer's
  /// last call to [startDiscovery]. The matching [scanStateStream]
  /// replays this value on subscribe.
  bluey.ScanState get scanState => _port.scanState;

  /// Stream of scan-state transitions. Replays the current value on
  /// subscribe, then emits every subsequent transition. Multi-listener.
  Stream<bluey.ScanState> get scanStateStream => _port.scanStateStream;
  MessagePort get messagePort => _messagePort;
  Stream<PeerEvent> get peerEvents => _peers.stream;
  Stream<ConnectionError> get errors => _service.errors;

  /// Last-known Bluetooth adapter state. Synchronous; reflects the most
  /// recent value observed from the underlying platform.
  BluetoothAdapterState get bluetoothAdapterState =>
      _port.bluetoothAdapterState;

  /// Stream of Bluetooth adapter transitions. Emits the current value on
  /// subscription, then every transition. Multi-listener.
  ///
  /// When the value is anything other than [BluetoothAdapterState.on],
  /// `BlueyTransport` is in a disabled state: [startAdvertising] and
  /// other operations throw `BluetoothUnavailableException`. Disabled
  /// transitions also fire [PeerDisconnected] events on [peerEvents] for
  /// every previously-active peer.
  Stream<BluetoothAdapterState> get bluetoothStateStream =>
      _port.bluetoothStateStream;

  /// Diagnostic log lines from the underlying BLE library. Useful for
  /// debugging discovery and connection issues. Emits the empty stream
  /// when the transport is wired with a port that has nothing to surface
  /// (e.g. a test fake).
  Stream<String> get diagnosticLog => _port.diagnosticLog;

  /// Diagnostic event lines from the underlying BLE library (scan
  /// started/stopped, device discovered, connecting, connected, etc.).
  Stream<String> get diagnosticEvents => _port.diagnosticEvents;
  Set<NodeId> get connectedPeers =>
      _service.registry.connections.map((h) => h.nodeId).toSet();
  int get connectedPeerCount => _service.registry.connectionCount;
  BlueyMetrics get metrics => _service.metrics;

  /// Snapshot stream of the current discovery candidates. Emits the
  /// current set on subscribe (replay-current), then every change.
  Stream<List<ScanCandidate>> get candidates => _discovery.snapshots;

  /// Per-event candidate stream. Each scan advertisement surfaces as one
  /// emission.
  Stream<ScanCandidate> get candidateEvents => _discovery.candidates;

  /// Immutable snapshot of the current candidate set, in insertion order.
  List<ScanCandidate> get currentCandidates => _discovery.currentCandidates;

  /// Current connection-mode policy. Defaults to [ConnectionMode.manual]
  /// — discovered peers are surfaced but no connection is initiated
  /// until [connectTo] is called explicitly.
  ConnectionMode get connectionMode => _autoConnect.mode;

  /// Sets the auto-connect policy mode.
  ///
  /// Returns synchronously. When transitioning from [ConnectionMode.manual]
  /// to [ConnectionMode.auto], the policy enumerates current discovery
  /// candidates and schedules connect attempts as background microtasks —
  /// individual attempts begin on subsequent microtasks and may not have
  /// started by the time this method returns. Use [candidateEvents] or
  /// [peerEvents] to observe when attempts actually begin.
  ///
  /// Transitioning to [ConnectionMode.manual] cancels the discovery
  /// subscription but does NOT tear down existing connections; consumers
  /// that want to disconnect must call [disconnect] or [disconnectAll]
  /// explicitly.
  void setConnectionMode(ConnectionMode mode) => _autoConnect.setMode(mode);

  /// Test-only access to the underlying ConnectionManager for triggering
  /// integration tests against connection lifecycle.
  @visibleForTesting
  ConnectionManager get serviceForTest => _service;

  /// Verify Bluetooth is on / supported / authorized at the OS layer.
  /// Throws a platform-specific exception if not. Use this between
  /// the app's permission grant and [startAdvertising] to catch the
  /// case where the user grants permissions but Bluetooth itself is off.
  ///
  /// This routes through the same Bluey instance that backs the
  /// transport — call this instead of `Bluey.shared.ensureReady()` so
  /// the app doesn't end up holding two Bluey instances (which causes
  /// duplicate platform listeners and observable issues on iOS).
  Future<void> ensureReady() => _port.ensureReady();

  /// Begin advertising. Idempotent at the port level — calling while
  /// already advertising or mid-start is a no-op.
  Future<void> startAdvertising() => _port.startAdvertising(
    serviceUuid: _serviceUuid,
    displayName: _displayName,
    localNodeId: localNodeId,
  );

  Future<void> stopAdvertising() => _port.stopAdvertising();

  /// Begin scanning for gossip-speaking peers. Idempotent: calling while
  /// already scanning is a no-op. Discovered candidates surface on
  /// [candidates] / [candidateEvents]; the consumer drives connection
  /// decisions via [connectTo] (manual mode) or sets
  /// [setConnectionMode] to [ConnectionMode.auto] to let
  /// [AutoConnectPolicy] auto-connect them.
  Future<void> startDiscovery() => _discovery.start();

  Future<void> stopDiscovery() => _discovery.stop();

  /// Initiate a connection to [candidate]. Returns the remote NodeId
  /// once the bluey-protocol identification handshake completes.
  /// Used in manual mode; [AutoConnectPolicy] calls this on its own in
  /// auto mode.
  Future<NodeId> connectTo(ScanCandidate candidate) =>
      _service.connectTo(candidate);

  /// Initiates a connection to the candidate currently known for [address].
  ///
  /// Equivalent to looking up the most recent [ScanCandidate] in
  /// [currentCandidates] and passing it to [connectTo], but resolved
  /// inside the facade so callers don't have to thread candidate
  /// lookups themselves.
  ///
  /// Throws [StateError] if no candidate is currently known for
  /// [address] (the scanner has not emitted one this session, or
  /// discovery has been stopped and the candidate map is empty).
  Future<NodeId> connectByAddress(BleAddress address) {
    final candidate = _discovery.currentCandidates
        .where((c) => c.address == address)
        .firstOrNull;
    if (candidate == null) {
      throw StateError('no candidate currently known for $address');
    }
    return _service.connectTo(candidate);
  }

  /// Disconnect a specific peer (whichever role we hold for that peer).
  Future<void> disconnect(NodeId nodeId) => _service.disconnect(nodeId);

  Future<void> disconnectAll() => _service.disconnectAll();

  Future<void> dispose() async {
    await _eventSub.cancel();
    await _peers.close();
    await _autoConnect.dispose();
    await _discovery.dispose();
    await _service.dispose();
    await _port.dispose();
  }

  void _onEvent(ConnectionEvent event) {
    switch (event) {
      case PeerOpened(:final nodeId, :final displayName):
        _peers.add(PeerConnected(nodeId, displayName: displayName));
      case PeerClosed(:final nodeId):
        _peers.add(PeerDisconnected(nodeId));
    }
  }
}
