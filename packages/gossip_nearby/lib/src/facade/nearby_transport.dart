import 'dart:async';

import 'package:gossip/gossip.dart';

import '../application/observability/nearby_metrics.dart';
import '../application/services/connection_service.dart';
import '../domain/aggregates/connection_registry.dart';
import '../domain/errors/connection_error.dart';
import '../domain/events/connection_event.dart';
import '../domain/interfaces/nearby_port.dart';
import '../domain/value_objects/service_id.dart';
import '../infrastructure/adapters/nearby_adapter.dart';
import '../infrastructure/ports/nearby_message_port.dart';

/// Events emitted when peer connection state changes.
sealed class PeerEvent {
  const PeerEvent();
}

/// Emitted when a peer has connected and completed the handshake.
class PeerConnected extends PeerEvent {
  final NodeId nodeId;
  final String? displayName;
  const PeerConnected(this.nodeId, {this.displayName});

  @override
  String toString() => 'PeerConnected($nodeId, displayName: $displayName)';
}

/// Emitted when a peer has disconnected.
class PeerDisconnected extends PeerEvent {
  final NodeId nodeId;
  const PeerDisconnected(this.nodeId);

  @override
  String toString() => 'PeerDisconnected($nodeId)';
}

/// High-level facade for Nearby Connections transport.
///
/// This is the main entry point for using gossip_nearby. It manages
/// the complete lifecycle of peer discovery, connection management,
/// and message delivery over Nearby Connections.
///
/// **Note:** This package uses Google Nearby Connections which is
/// Android-only. For iOS or cross-platform BLE support, use the
/// `gossip_ble` package instead.
///
/// ## Usage
///
/// ```dart
/// // Create transport (resolves node ID from repository)
/// final localNodeRepo = InMemoryLocalNodeRepository();
/// final transport = await NearbyTransport.create(
///   localNodeRepository: localNodeRepo,
///   serviceId: ServiceId('com.example.app'),
///   displayName: 'My Device',
///   onLog: (level, message, [error, stack]) {
///     print('[$level] $message');
///   },
/// );
///
/// // Create coordinator (same repo guarantees same node ID)
/// final coordinator = await Coordinator.create(
///   localNodeRepository: localNodeRepo,
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
class NearbyTransport {
  final NodeId localNodeId;
  final ServiceId _serviceId;
  final String _displayName;
  final LogCallback? _onLog;

  final ConnectionRegistry _registry;
  final ConnectionService _connectionService;
  final NearbyMessagePort _messagePort;
  final NearbyPort _nearbyPort;

  final _peerEventController = StreamController<PeerEvent>.broadcast();
  StreamSubscription<ConnectionEvent>? _eventSubscription;

  bool _isAdvertising = false;
  bool _isDiscovering = false;

  NearbyTransport._({
    required this.localNodeId,
    required ServiceId serviceId,
    required String displayName,
    required ConnectionRegistry registry,
    required ConnectionService connectionService,
    required NearbyMessagePort messagePort,
    required NearbyPort nearbyPort,
    LogCallback? onLog,
  }) : _serviceId = serviceId,
       _displayName = displayName,
       _registry = registry,
       _connectionService = connectionService,
       _messagePort = messagePort,
       _nearbyPort = nearbyPort,
       _onLog = onLog {
    _eventSubscription = _connectionService.events.listen(_onConnectionEvent);
  }

  /// Creates a new Nearby Connections transport, resolving the node ID from
  /// the given [localNodeRepository].
  ///
  /// This is the recommended way to create a transport in production code.
  /// Pass the same [LocalNodeRepository] instance to both this method and
  /// [Coordinator.create] to guarantee consistent node identity.
  static Future<NearbyTransport> create({
    required LocalNodeRepository localNodeRepository,
    required ServiceId serviceId,
    required String displayName,
    LogCallback? onLog,
  }) async {
    final nodeId = await localNodeRepository.resolveNodeId();
    return NearbyTransport(
      localNodeId: nodeId,
      serviceId: serviceId,
      displayName: displayName,
      onLog: onLog,
    );
  }

  /// Creates a new Nearby Connections transport with an explicit [localNodeId].
  ///
  /// Prefer [NearbyTransport.create] in production code to avoid node ID
  /// mismatches. This constructor is useful for tests where you control the
  /// node ID directly.
  factory NearbyTransport({
    required NodeId localNodeId,
    required ServiceId serviceId,
    required String displayName,
    LogCallback? onLog,
  }) {
    return NearbyTransport.withPort(
      localNodeId: localNodeId,
      serviceId: serviceId,
      displayName: displayName,
      nearbyPort: NearbyAdapter(),
      onLog: onLog,
    );
  }

  /// Creates a transport with a custom NearbyPort (for testing).
  factory NearbyTransport.withPort({
    required NodeId localNodeId,
    required ServiceId serviceId,
    required String displayName,
    required NearbyPort nearbyPort,
    LogCallback? onLog,
  }) {
    final registry = ConnectionRegistry();
    final metrics = NearbyMetrics();
    final connectionService = ConnectionService(
      localNodeId: localNodeId,
      displayName: displayName,
      nearbyPort: nearbyPort,
      registry: registry,
      metrics: metrics,
      onLog: onLog,
    );
    final messagePort = NearbyMessagePort(connectionService);

    return NearbyTransport._(
      localNodeId: localNodeId,
      serviceId: serviceId,
      displayName: displayName,
      registry: registry,
      connectionService: connectionService,
      messagePort: messagePort,
      nearbyPort: nearbyPort,
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

  /// Currently connected peer NodeIds.
  Set<NodeId> get connectedPeers =>
      _registry.connections.map((c) => c.nodeId).toSet();

  /// Number of currently connected peers.
  int get connectedPeerCount => _registry.connectionCount;

  /// Metrics for monitoring transport health and performance.
  NearbyMetrics get metrics => _connectionService.metrics;

  /// Whether advertising is currently active.
  bool get isAdvertising => _isAdvertising;

  /// Whether discovery is currently active.
  bool get isDiscovering => _isDiscovering;

  /// Starts advertising this device to nearby peers.
  Future<void> startAdvertising() async {
    if (_isAdvertising) return;

    _log(LogLevel.info, 'Starting advertising as "$_displayName"');
    await _nearbyPort.startAdvertising(_serviceId, _advertisedName);
    _isAdvertising = true;
  }

  /// The name advertised to nearby devices.
  ///
  /// Encodes the nodeId for connection tie-breaking: when two devices
  /// discover each other simultaneously, only the one with the smaller
  /// nodeId initiates the connection to avoid race conditions.
  String get _advertisedName => '${localNodeId.value}|$_displayName';

  /// Stops advertising.
  Future<void> stopAdvertising() async {
    if (!_isAdvertising) return;

    _log(LogLevel.info, 'Stopping advertising');
    await _nearbyPort.stopAdvertising();
    _isAdvertising = false;
  }

  /// Starts discovering nearby peers.
  Future<void> startDiscovery() async {
    if (_isDiscovering) return;

    _log(LogLevel.info, 'Starting discovery for service ${_serviceId.value}');
    await _nearbyPort.startDiscovery(_serviceId);
    _isDiscovering = true;
  }

  /// Stops discovery.
  Future<void> stopDiscovery() async {
    if (!_isDiscovering) return;

    _log(LogLevel.info, 'Stopping discovery');
    await _nearbyPort.stopDiscovery();
    _isDiscovering = false;
  }

  /// Disconnects all connected peers.
  Future<void> disconnectAll() async {
    final endpoints = _registry.connections.map((c) => c.endpointId).toList();
    _log(LogLevel.info, 'Disconnecting all ${endpoints.length} peers');
    for (final endpointId in endpoints) {
      await _nearbyPort.disconnect(endpointId);
    }
  }

  /// Disposes all resources.
  Future<void> dispose() async {
    _log(LogLevel.debug, 'Disposing NearbyTransport');
    await _eventSubscription?.cancel();
    await _peerEventController.close();
    await _messagePort.close();
    await _connectionService.dispose();
    if (_nearbyPort case final NearbyAdapter adapter) {
      await adapter.dispose();
    }
    _isAdvertising = false;
    _isDiscovering = false;
  }

  void _onConnectionEvent(ConnectionEvent event) {
    switch (event) {
      case HandshakeCompleted(:final nodeId, :final displayName):
        _peerEventController.add(
          PeerConnected(nodeId, displayName: displayName),
        );
      case ConnectionClosed(:final nodeId):
        _peerEventController.add(PeerDisconnected(nodeId));
      case HandshakeFailed():
        // Not exposed as a peer event
        break;
    }
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
