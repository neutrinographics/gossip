import 'dart:async';

import 'package:gossip/gossip.dart';

import '../application/services/connection_service.dart';
import '../domain/aggregates/connection_registry.dart';
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

/// High-level facade for Nearby Connections transport.
///
/// This is the main entry point for using gossip_nearby. It manages
/// the complete lifecycle of peer discovery, connection management,
/// and message delivery over Nearby Connections.
///
/// ## Usage
///
/// ```dart
/// // Create transport
/// final transport = NearbyTransport(
///   localNodeId: NodeId('device-uuid'),
///   serviceId: ServiceId('com.example.app'),
///   displayName: 'My Device',
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
class NearbyTransport {
  final NodeId localNodeId;
  final ServiceId _serviceId;
  final String _displayName;

  final ConnectionRegistry _registry;
  final ConnectionService _connectionService;
  final NearbyMessagePort _messagePort;
  final NearbyPort _nearbyPort;

  final _peerEventController = StreamController<PeerEvent>.broadcast();
  StreamSubscription<ConnectionEvent>? _eventSubscription;

  NearbyTransport._({
    required this.localNodeId,
    required ServiceId serviceId,
    required String displayName,
    required ConnectionRegistry registry,
    required ConnectionService connectionService,
    required NearbyMessagePort messagePort,
    required NearbyPort nearbyPort,
  }) : _serviceId = serviceId,
       _displayName = displayName,
       _registry = registry,
       _connectionService = connectionService,
       _messagePort = messagePort,
       _nearbyPort = nearbyPort {
    _eventSubscription = _connectionService.events.listen(_onConnectionEvent);
  }

  /// Creates a new Nearby transport with the real Nearby Connections adapter.
  factory NearbyTransport({
    required NodeId localNodeId,
    required ServiceId serviceId,
    required String displayName,
  }) {
    final nearbyPort = NearbyAdapter();
    return NearbyTransport.withPort(
      localNodeId: localNodeId,
      serviceId: serviceId,
      displayName: displayName,
      nearbyPort: nearbyPort,
    );
  }

  /// Creates a transport with a custom NearbyPort (for testing).
  factory NearbyTransport.withPort({
    required NodeId localNodeId,
    required ServiceId serviceId,
    required String displayName,
    required NearbyPort nearbyPort,
  }) {
    final registry = ConnectionRegistry();
    final connectionService = ConnectionService(
      localNodeId: localNodeId,
      nearbyPort: nearbyPort,
      registry: registry,
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
    );
  }

  /// The [MessagePort] to pass to gossip's [Coordinator].
  MessagePort get messagePort => _messagePort;

  /// Stream of peer connection events.
  Stream<PeerEvent> get peerEvents => _peerEventController.stream;

  /// Currently connected peer NodeIds.
  Set<NodeId> get connectedPeers =>
      _registry.connections.map((c) => c.nodeId).toSet();

  /// Number of currently connected peers.
  int get connectedPeerCount => _registry.connectionCount;

  /// Starts advertising this device to nearby peers.
  Future<void> startAdvertising() async {
    await _nearbyPort.startAdvertising(_serviceId, _displayName);
  }

  /// Stops advertising.
  Future<void> stopAdvertising() async {
    await _nearbyPort.stopAdvertising();
  }

  /// Starts discovering nearby peers.
  Future<void> startDiscovery() async {
    await _nearbyPort.startDiscovery(_serviceId);
  }

  /// Stops discovery.
  Future<void> stopDiscovery() async {
    await _nearbyPort.stopDiscovery();
  }

  /// Disposes all resources.
  Future<void> dispose() async {
    await _eventSubscription?.cancel();
    await _peerEventController.close();
    await _messagePort.close();
    await _connectionService.dispose();
    if (_nearbyPort case final NearbyAdapter adapter) {
      await adapter.dispose();
    }
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
}
