import 'dart:async';

import 'package:bluey/bluey.dart' as bluey;
import 'package:gossip/gossip.dart';
import 'package:meta/meta.dart';

import '../application/observability/bluey_metrics.dart';
import '../application/services/connection_manager.dart';
import '../domain/aggregates/connection_registry.dart';
import '../domain/errors/connection_error.dart';
import '../domain/events/connection_event.dart';
import '../domain/interfaces/bluey_port.dart';
import '../domain/value_objects/bluetooth_adapter_state.dart';
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
    required BlueyMessagePort messagePort,
    LogCallback? onLog,
  }) : _serviceUuid = serviceUuid,
       _displayName = displayName,
       _port = port,
       _service = service,
       _messagePort = messagePort,
       _onLog = onLog {
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
    @Deprecated(
      'No-op since C3; targetConnections moves to AutoConnectPolicy in C4.',
    )
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
      localNodeId: nodeId,
      port: port,
      registry: registry,
      metrics: metrics,
      serviceUuid: serviceUuid,
      maxConnections: maxConnections,
      onLog: onLog,
    );
    return BlueyTransport._(
      localNodeId: nodeId,
      serviceUuid: serviceUuid,
      displayName: displayName,
      port: port,
      service: service,
      messagePort: BlueyMessagePort(service),
      onLog: onLog,
    );
  }

  /// Test-only constructor that wires a `BlueyPort` directly.
  factory BlueyTransport.testing({
    required NodeId localNodeId,
    required ServiceUuid serviceUuid,
    required String displayName,
    required BlueyPort port,
    int? maxConnections,
    @Deprecated(
      'No-op since C3; targetConnections moves to AutoConnectPolicy in C4.',
    )
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
      localNodeId: localNodeId,
      port: port,
      registry: registry,
      metrics: metrics,
      serviceUuid: serviceUuid,
      maxConnections: maxConnections,
      onLog: onLog,
    );
    final mp = BlueyMessagePort(service);
    return BlueyTransport._(
      localNodeId: localNodeId,
      serviceUuid: serviceUuid,
      displayName: displayName,
      port: port,
      service: service,
      messagePort: mp,
      onLog: onLog,
    );
  }

  final NodeId localNodeId;
  final ServiceUuid _serviceUuid;
  final String _displayName;
  final BlueyPort _port;
  final ConnectionManager _service;
  final BlueyMessagePort _messagePort;
  final LogCallback? _onLog;

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

  // TODO(C5): re-introduce startDiscovery / stopDiscovery once
  // DiscoveryService + AutoConnectPolicy are wired through the facade.
  // Until then, startDiscovery is a no-op stub kept ONLY to preserve
  // gossip_chat compilation. It logs a warning so test runs surface the
  // missing behavior.
  Future<void> startDiscovery({bool Function(NodeId)? filter}) async {
    _onLog?.call(
      LogLevel.warning,
      'BlueyTransport.startDiscovery is a no-op until C5; '
      'no peers will be discovered or auto-connected',
    );
  }

  Future<void> stopDiscovery() async {
    // no-op until C5
  }

  Future<void> disconnectAll() => _service.disconnectAll();

  Future<void> dispose() async {
    await _eventSub.cancel();
    await _peers.close();
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
