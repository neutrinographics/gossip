import 'dart:async';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';
import 'package:meta/meta.dart';
import 'package:nearby_connections/nearby_connections.dart';

import 'handshake_codec.dart';
import 'nearby_config.dart';
import 'peer_event.dart';

/// Manages Nearby Connections discovery, advertising, and connection lifecycle.
///
/// This class handles:
/// - Starting/stopping advertising and discovery
/// - Accepting/rejecting connection requests
/// - Performing the NodeId handshake after connection
/// - Tracking connected peers and their endpoint mappings
class NearbyConnectionManager {
  final NodeId _localNodeId;
  final NearbyConfig _config;
  final Nearby _nearby;

  final _peerEvents = StreamController<PeerEvent>.broadcast();
  final _incomingPayloads = StreamController<(NodeId, Uint8List)>.broadcast();

  /// Maps Nearby endpoint IDs to gossip NodeIds (after handshake completes).
  final Map<String, NodeId> _endpointToNodeId = {};

  /// Maps gossip NodeIds to Nearby endpoint IDs.
  final Map<NodeId, String> _nodeIdToEndpoint = {};

  /// Endpoints that are connected but haven't completed handshake yet.
  final Map<String, _PendingConnection> _pendingConnections = {};

  bool _isAdvertising = false;
  bool _isDiscovering = false;

  NearbyConnectionManager({
    required NodeId localNodeId,
    required NearbyConfig config,
    @visibleForTesting Nearby? nearby,
  }) : _localNodeId = localNodeId,
       _config = config,
       _nearby = nearby ?? Nearby();

  /// Stream of peer connection events.
  ///
  /// Listen to this to add/remove peers from the gossip coordinator.
  Stream<PeerEvent> get peerEvents => _peerEvents.stream;

  /// Stream of incoming payloads from connected peers.
  ///
  /// Only includes gossip protocol messages (not handshake messages).
  Stream<(NodeId, Uint8List)> get incomingPayloads => _incomingPayloads.stream;

  /// Currently connected peers (handshake completed).
  Set<NodeId> get connectedPeers => Set.unmodifiable(_nodeIdToEndpoint.keys);

  /// Whether advertising is currently active.
  bool get isAdvertising => _isAdvertising;

  /// Whether discovery is currently active.
  bool get isDiscovering => _isDiscovering;

  /// Starts advertising this device to nearby peers.
  Future<void> startAdvertising() async {
    if (_isAdvertising) return;

    final started = await _nearby.startAdvertising(
      _config.displayName ?? _localNodeId.value,
      _config.strategy,
      onConnectionInitiated: _onConnectionInitiated,
      onConnectionResult: _onConnectionResult,
      onDisconnected: _onDisconnected,
      serviceId: _config.serviceId,
    );

    if (started) {
      _isAdvertising = true;
    }
  }

  /// Stops advertising.
  Future<void> stopAdvertising() async {
    if (!_isAdvertising) return;
    await _nearby.stopAdvertising();
    _isAdvertising = false;
  }

  /// Starts discovering nearby peers.
  Future<void> startDiscovery() async {
    if (_isDiscovering) return;

    final started = await _nearby.startDiscovery(
      _config.displayName ?? _localNodeId.value,
      _config.strategy,
      onEndpointFound: _onEndpointFound,
      onEndpointLost: _onEndpointLost,
      serviceId: _config.serviceId,
    );

    if (started) {
      _isDiscovering = true;
    }
  }

  /// Stops discovery.
  Future<void> stopDiscovery() async {
    if (!_isDiscovering) return;
    await _nearby.stopDiscovery();
    _isDiscovering = false;
  }

  /// Sends bytes to a connected peer.
  ///
  /// Returns true if the message was sent, false if the peer is not connected.
  Future<bool> sendTo(NodeId destination, Uint8List bytes) async {
    final endpointId = _nodeIdToEndpoint[destination];
    if (endpointId == null) return false;

    final wrapped = HandshakeCodec.wrapGossipMessage(bytes);
    await _nearby.sendBytesPayload(endpointId, wrapped);
    return true;
  }

  /// Disconnects from a specific peer.
  Future<void> disconnect(NodeId nodeId) async {
    final endpointId = _nodeIdToEndpoint[nodeId];
    if (endpointId == null) return;

    await _nearby.disconnectFromEndpoint(endpointId);
    _removeConnection(endpointId, DisconnectReason.localDisconnect);
  }

  /// Disconnects from all peers and stops advertising/discovery.
  Future<void> dispose() async {
    await stopAdvertising();
    await stopDiscovery();

    for (final endpointId in _endpointToNodeId.keys.toList()) {
      await _nearby.disconnectFromEndpoint(endpointId);
    }

    _endpointToNodeId.clear();
    _nodeIdToEndpoint.clear();
    _pendingConnections.clear();

    await _peerEvents.close();
    await _incomingPayloads.close();
  }

  // --- Nearby Callbacks ---

  void _onEndpointFound(
    String endpointId,
    String endpointName,
    String serviceId,
  ) {
    // Request connection to discovered endpoint
    _nearby.requestConnection(
      _config.displayName ?? _localNodeId.value,
      endpointId,
      onConnectionInitiated: _onConnectionInitiated,
      onConnectionResult: _onConnectionResult,
      onDisconnected: _onDisconnected,
    );
  }

  void _onEndpointLost(String? endpointId) {
    // Endpoint lost during discovery - not yet connected, so nothing to clean up
  }

  void _onConnectionInitiated(String endpointId, ConnectionInfo info) {
    if (_config.autoAcceptConnections) {
      _nearby.acceptConnection(
        endpointId,
        onPayLoadRecieved: (endpointId, payload) =>
            _onPayloadReceived(endpointId, payload),
        onPayloadTransferUpdate: (endpointId, update) {},
      );
    }
  }

  void _onConnectionResult(String endpointId, Status status) {
    if (status == Status.CONNECTED) {
      _startHandshake(endpointId);
    }
  }

  void _onDisconnected(String endpointId) {
    _removeConnection(endpointId, DisconnectReason.connectionLost);
  }

  void _onPayloadReceived(String endpointId, Payload payload) {
    if (payload.type != PayloadType.BYTES || payload.bytes == null) return;

    final bytes = payload.bytes!;

    // Check if this is from a pending connection (handshake in progress)
    final pending = _pendingConnections[endpointId];
    if (pending != null) {
      _handleHandshakeMessage(endpointId, bytes, pending);
      return;
    }

    // Otherwise, it's a gossip message from a connected peer
    final nodeId = _endpointToNodeId[endpointId];
    if (nodeId == null) return;

    final unwrapped = HandshakeCodec.unwrapGossipMessage(bytes);
    if (unwrapped != null) {
      _incomingPayloads.add((nodeId, unwrapped));
    }
  }

  // --- Handshake Protocol ---

  void _startHandshake(String endpointId) {
    final pending = _PendingConnection(
      endpointId: endpointId,
      startedAt: DateTime.now(),
    );
    _pendingConnections[endpointId] = pending;

    // Send our NodeId
    final handshakeBytes = HandshakeCodec.encodeHandshake(_localNodeId);
    _nearby.sendBytesPayload(endpointId, handshakeBytes);

    // Set up timeout
    pending.timeoutTimer = Timer(_config.handshakeTimeout, () {
      if (_pendingConnections.containsKey(endpointId)) {
        _pendingConnections.remove(endpointId);
        _nearby.disconnectFromEndpoint(endpointId);
      }
    });
  }

  void _handleHandshakeMessage(
    String endpointId,
    Uint8List bytes,
    _PendingConnection pending,
  ) {
    if (!HandshakeCodec.isHandshake(bytes)) {
      // Unexpected message during handshake - ignore
      return;
    }

    final remoteNodeId = HandshakeCodec.decodeHandshake(bytes);
    if (remoteNodeId == null) {
      // Invalid handshake - disconnect
      _pendingConnections.remove(endpointId);
      pending.timeoutTimer?.cancel();
      _nearby.disconnectFromEndpoint(endpointId);
      return;
    }

    // Handshake complete!
    _pendingConnections.remove(endpointId);
    pending.timeoutTimer?.cancel();

    _endpointToNodeId[endpointId] = remoteNodeId;
    _nodeIdToEndpoint[remoteNodeId] = endpointId;

    _peerEvents.add(PeerConnected(remoteNodeId));
  }

  void _removeConnection(String endpointId, DisconnectReason reason) {
    // Clean up pending connection if handshake was in progress
    final pending = _pendingConnections.remove(endpointId);
    if (pending != null) {
      pending.timeoutTimer?.cancel();
      return;
    }

    // Clean up established connection
    final nodeId = _endpointToNodeId.remove(endpointId);
    if (nodeId != null) {
      _nodeIdToEndpoint.remove(nodeId);
      _peerEvents.add(PeerDisconnected(nodeId, reason: reason));
    }
  }
}

class _PendingConnection {
  final String endpointId;
  final DateTime startedAt;
  Timer? timeoutTimer;

  _PendingConnection({required this.endpointId, required this.startedAt});
}
