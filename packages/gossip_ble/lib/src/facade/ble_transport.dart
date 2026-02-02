import 'dart:async';

import 'package:gossip/gossip.dart';

import '../application/observability/ble_metrics.dart';
import '../application/observability/log_level.dart';
import '../application/services/connection_service.dart';
import '../domain/aggregates/connection_registry.dart';
import '../domain/errors/connection_error.dart';
import '../domain/events/connection_event.dart';
import '../domain/ports/ble_port.dart';
import '../domain/value_objects/device_id.dart';
import '../domain/value_objects/service_id.dart';
import '../infrastructure/adapters/ble_port_impl.dart';
import '../infrastructure/codec/handshake_codec.dart';
import '../infrastructure/ports/ble_message_port.dart';

/// Events emitted when peer connection state changes.
sealed class PeerEvent {
  const PeerEvent();
}

/// Emitted when a peer has connected and completed the handshake.
class PeerConnected extends PeerEvent {
  final NodeId nodeId;
  const PeerConnected(this.nodeId);

  @override
  String toString() => 'PeerConnected($nodeId)';
}

/// Emitted when a peer has disconnected.
class PeerDisconnected extends PeerEvent {
  final NodeId nodeId;
  const PeerDisconnected(this.nodeId);

  @override
  String toString() => 'PeerDisconnected($nodeId)';
}

/// High-level facade for BLE transport.
///
/// This is the main entry point for using gossip_ble. It manages
/// the complete lifecycle of peer discovery, connection management,
/// and message delivery over Bluetooth Low Energy.
///
/// ## Usage
///
/// ```dart
/// // Create transport
/// final transport = BleTransport(
///   localNodeId: NodeId('device-uuid'),
///   serviceId: ServiceId('com.example.app'),
///   displayName: 'My Device',
///   onLog: (level, message, [error, stack]) {
///     print('[$level] $message');
///   },
/// );
///
/// // Get the message port for gossip
/// final coordinator = await Coordinator.create(
///   localNode: transport.localNodeId,
///   messagePort: transport.messagePort,
///   // ... other params
/// );
///
/// // Listen for peer events
/// transport.peerEvents.listen((event) {
///   switch (event) {
///     case PeerConnected(:final nodeId):
///       coordinator.addPeer(nodeId);
///     case PeerDisconnected(:final nodeId):
///       coordinator.removePeer(nodeId);
///   }
/// });
///
/// // Start advertising and discovery
/// await transport.startAdvertising();
/// await transport.startDiscovery();
/// ```
class BleTransport {
  final NodeId localNodeId;
  final ServiceId _serviceId;
  final String _displayName;
  final LogCallback? _onLog;

  final ConnectionRegistry _registry;
  final ConnectionService _connectionService;
  final BleMessagePort _messagePort;
  final BlePort _blePort;

  final _peerEventController = StreamController<PeerEvent>.broadcast();
  StreamSubscription<ConnectionEvent>? _eventSubscription;
  StreamSubscription<BleEvent>? _bleEventSubscription;

  bool _isAdvertising = false;
  bool _isDiscovering = false;

  BleTransport._({
    required this.localNodeId,
    required ServiceId serviceId,
    required String displayName,
    required ConnectionRegistry registry,
    required ConnectionService connectionService,
    required BleMessagePort messagePort,
    required BlePort blePort,
    LogCallback? onLog,
  }) : _serviceId = serviceId,
       _displayName = displayName,
       _registry = registry,
       _connectionService = connectionService,
       _messagePort = messagePort,
       _blePort = blePort,
       _onLog = onLog {
    _eventSubscription = _connectionService.events.listen(_onConnectionEvent);
    _bleEventSubscription = _blePort.events.listen(_onBleEvent);
  }

  /// Creates a new BLE transport.
  factory BleTransport({
    required NodeId localNodeId,
    required ServiceId serviceId,
    required String displayName,
    LogCallback? onLog,
  }) {
    void bleLog(String message) {
      onLog?.call(LogLevel.debug, message);
    }

    final blePort = BlePortImpl(onLog: bleLog);

    return BleTransport.withPort(
      localNodeId: localNodeId,
      serviceId: serviceId,
      displayName: displayName,
      blePort: blePort,
      onLog: onLog,
    );
  }

  /// Creates a transport with a custom BlePort (for testing).
  ///
  /// The optional [timePort] parameter allows injecting a fake time source
  /// for deterministic testing. If not provided, uses [RealTimePort].
  factory BleTransport.withPort({
    required NodeId localNodeId,
    required ServiceId serviceId,
    required String displayName,
    required BlePort blePort,
    TimePort? timePort,
    LogCallback? onLog,
  }) {
    final registry = ConnectionRegistry();
    final connectionService = ConnectionService(
      localNodeId: localNodeId,
      blePort: blePort,
      registry: registry,
      codec: const HandshakeCodec(),
      timePort: timePort ?? RealTimePort(),
      onLog: onLog,
    );
    final messagePort = BleMessagePort(connectionService);

    return BleTransport._(
      localNodeId: localNodeId,
      serviceId: serviceId,
      displayName: displayName,
      registry: registry,
      connectionService: connectionService,
      messagePort: messagePort,
      blePort: blePort,
      onLog: onLog,
    );
  }

  /// The [MessagePort] to pass to gossip's [Coordinator].
  MessagePort get messagePort => _messagePort;

  /// Stream of peer connection events.
  Stream<PeerEvent> get peerEvents => _peerEventController.stream;

  /// Stream of connection errors for observability.
  ///
  /// Applications should listen to this stream to log errors, implement
  /// retry policies, or alert users about connection issues.
  Stream<ConnectionError> get errors => _connectionService.errors;

  /// Metrics for monitoring transport health and performance.
  BleMetrics get metrics => _connectionService.metrics;

  /// Currently connected peer NodeIds.
  Set<NodeId> get connectedPeers =>
      _registry.connections.map((c) => c.nodeId).toSet();

  /// Number of currently connected peers.
  int get connectedPeerCount => _registry.connectionCount;

  /// Whether advertising is currently active.
  bool get isAdvertising => _isAdvertising;

  /// Whether discovery is currently active.
  bool get isDiscovering => _isDiscovering;

  /// Starts advertising this device to nearby peers.
  Future<void> startAdvertising() async {
    if (_isAdvertising) return;

    _log(LogLevel.info, 'Starting advertising as "$_displayName"');
    await _blePort.startAdvertising(_serviceId, _displayName);
    _isAdvertising = true;
  }

  /// Stops advertising.
  Future<void> stopAdvertising() async {
    if (!_isAdvertising) return;

    _log(LogLevel.info, 'Stopping advertising');
    await _blePort.stopAdvertising();
    _isAdvertising = false;
  }

  /// Starts discovering nearby peers.
  Future<void> startDiscovery() async {
    if (_isDiscovering) return;

    _log(LogLevel.info, 'Starting discovery for service ${_serviceId.value}');
    await _blePort.startDiscovery(_serviceId);
    _isDiscovering = true;
  }

  /// Stops discovery.
  Future<void> stopDiscovery() async {
    if (!_isDiscovering) return;

    _log(LogLevel.info, 'Stopping discovery');
    await _blePort.stopDiscovery();
    _isDiscovering = false;
  }

  /// Disposes all resources.
  Future<void> dispose() async {
    _log(LogLevel.debug, 'Disposing BleTransport');
    await _eventSubscription?.cancel();
    await _bleEventSubscription?.cancel();
    await _peerEventController.close();
    await _messagePort.close();
    await _connectionService.dispose();
    await _blePort.dispose();
    _isAdvertising = false;
    _isDiscovering = false;
  }

  void _onConnectionEvent(ConnectionEvent event) {
    switch (event) {
      case HandshakeCompleted(:final nodeId):
        _peerEventController.add(PeerConnected(nodeId));
      case ConnectionClosed(:final nodeId):
        _peerEventController.add(PeerDisconnected(nodeId));
      case HandshakeFailed():
        // Not exposed as a peer event
        break;
    }
  }

  void _onBleEvent(BleEvent event) {
    switch (event) {
      case DeviceDiscovered(:final id, :final displayName):
        _onDeviceDiscovered(id, displayName);
      case ConnectionEstablished():
      case BytesReceived():
      case DeviceDisconnected():
        // Handled by ConnectionService
        break;
    }
  }

  void _onDeviceDiscovered(DeviceId deviceId, String displayName) {
    _log(LogLevel.info, 'Discovered device: $displayName ($deviceId)');

    // Auto-connect to discovered devices
    _log(LogLevel.debug, 'Requesting connection to $deviceId');
    unawaited(
      _blePort.requestConnection(deviceId).catchError((Object error) {
        _log(LogLevel.warning, 'Failed to connect to $deviceId: $error');
      }),
    );
  }

  void _log(
    LogLevel level,
    String message, [
    Object? error,
    StackTrace? stack,
  ]) {
    _onLog?.call(level, message, error, stack);
  }
}
