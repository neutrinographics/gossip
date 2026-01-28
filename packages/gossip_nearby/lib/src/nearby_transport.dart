import 'dart:async';

import 'package:gossip/gossip.dart';

import 'nearby_config.dart';
import 'nearby_connection_manager.dart';
import 'nearby_message_port.dart';
import 'peer_event.dart';

/// High-level facade for Nearby Connections transport.
///
/// [NearbyTransport] manages the complete lifecycle of peer discovery,
/// connection management, and message delivery over Nearby Connections.
///
/// ## Usage
///
/// ```dart
/// // Create transport
/// final transport = NearbyTransport(
///   localNodeId: NodeId('device-uuid'),
///   config: NearbyConfig(serviceId: 'com.example.app'),
/// );
///
/// // Get the message port for gossip
/// final messagePort = transport.messagePort;
///
/// // Listen for peer events
/// transport.peerEvents.listen((event) {
///   switch (event) {
///     case PeerConnected(:final nodeId):
///       print('Connected: $nodeId');
///     case PeerDisconnected(:final nodeId):
///       print('Disconnected: $nodeId');
///   }
/// });
///
/// // Start advertising and discovery
/// await transport.start();
///
/// // ... app runs ...
///
/// // Clean up
/// await transport.stop();
/// ```
class NearbyTransport {
  final NearbyConnectionManager _connectionManager;
  final NearbyMessagePort _messagePort;

  bool _isStarted = false;

  NearbyTransport._({
    required NearbyConnectionManager connectionManager,
    required NearbyMessagePort messagePort,
  }) : _connectionManager = connectionManager,
       _messagePort = messagePort;

  /// Creates a new Nearby transport.
  ///
  /// - [localNodeId]: The stable NodeId for this device (provided by your app)
  /// - [config]: Configuration for Nearby Connections
  factory NearbyTransport({
    required NodeId localNodeId,
    required NearbyConfig config,
  }) {
    final connectionManager = NearbyConnectionManager(
      localNodeId: localNodeId,
      config: config,
    );
    final messagePort = NearbyMessagePort(connectionManager);

    return NearbyTransport._(
      connectionManager: connectionManager,
      messagePort: messagePort,
    );
  }

  /// The [MessagePort] to pass to gossip's [Coordinator].
  MessagePort get messagePort => _messagePort;

  /// Stream of peer connection events.
  ///
  /// Listen to this to add/remove peers from the gossip [Coordinator].
  Stream<PeerEvent> get peerEvents => _connectionManager.peerEvents;

  /// Currently connected peers.
  Set<NodeId> get connectedPeers => _connectionManager.connectedPeers;

  /// Whether the transport is currently running (advertising and discovering).
  bool get isRunning => _isStarted;

  /// Starts advertising and discovery.
  ///
  /// After calling this, the transport will:
  /// - Advertise this device to nearby peers
  /// - Discover nearby peers
  /// - Automatically connect to discovered peers
  /// - Perform handshake to exchange NodeIds
  /// - Emit [PeerConnected] events when peers are ready
  Future<void> start() async {
    if (_isStarted) return;

    await _connectionManager.startAdvertising();
    await _connectionManager.startDiscovery();
    _isStarted = true;
  }

  /// Stops advertising and discovery, but keeps existing connections.
  Future<void> pause() async {
    await _connectionManager.stopAdvertising();
    await _connectionManager.stopDiscovery();
  }

  /// Resumes advertising and discovery.
  Future<void> resume() async {
    if (!_isStarted) return;
    await _connectionManager.startAdvertising();
    await _connectionManager.startDiscovery();
  }

  /// Stops the transport and disconnects all peers.
  Future<void> stop() async {
    _isStarted = false;
    await _connectionManager.dispose();
    await _messagePort.close();
  }

  /// Disconnects from a specific peer.
  Future<void> disconnectPeer(NodeId nodeId) async {
    await _connectionManager.disconnect(nodeId);
  }
}
