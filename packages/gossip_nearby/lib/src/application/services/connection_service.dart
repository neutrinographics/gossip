import 'dart:async' show StreamController, StreamSubscription, unawaited;
import 'dart:convert';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

import '../../domain/aggregates/connection_registry.dart';
import '../../domain/events/connection_event.dart';
import '../../domain/interfaces/nearby_port.dart';
import '../../domain/value_objects/endpoint.dart';
import '../../domain/value_objects/endpoint_id.dart';

/// Callback for receiving gossip messages.
typedef GossipMessageCallback = void Function(NodeId sender, Uint8List bytes);

/// Application service coordinating connection lifecycle and handshakes.
///
/// Responsibilities:
/// - Listens to NearbyPort events and orchestrates responses
/// - Manages handshake protocol (send/receive NodeIds)
/// - Forwards gossip messages to/from the domain
/// - Emits domain events for connection state changes
class ConnectionService {
  final NodeId _localNodeId;
  final NearbyPort _nearbyPort;
  final ConnectionRegistry _registry;

  final _eventController = StreamController<ConnectionEvent>.broadcast();
  StreamSubscription<NearbyEvent>? _nearbySubscription;

  /// Callback invoked when a gossip message is received from a connected peer.
  GossipMessageCallback? onGossipMessage;

  ConnectionService({
    required NodeId localNodeId,
    required NearbyPort nearbyPort,
    required ConnectionRegistry registry,
  }) : _localNodeId = localNodeId,
       _nearbyPort = nearbyPort,
       _registry = registry {
    _nearbySubscription = _nearbyPort.events.listen(_handleNearbyEvent);
  }

  /// Stream of connection events (HandshakeCompleted, ConnectionClosed, etc.)
  Stream<ConnectionEvent> get events => _eventController.stream;

  /// Sends a gossip message to the specified peer.
  Future<void> sendGossipMessage(NodeId destination, Uint8List bytes) async {
    final endpointId = _registry.getEndpointIdForNodeId(destination);
    if (endpointId == null) {
      return; // Connection not found - silently ignore per MessagePort contract
    }

    final wrapped = _wrapGossipMessage(bytes);
    await _nearbyPort.sendPayload(endpointId, wrapped);
  }

  /// Disposes resources.
  Future<void> dispose() async {
    await _nearbySubscription?.cancel();
    await _eventController.close();
  }

  void _handleNearbyEvent(NearbyEvent event) {
    switch (event) {
      case EndpointDiscovered(:final id, :final displayName):
        _onEndpointDiscovered(id, displayName);
      case ConnectionEstablished(:final id):
        _onConnectionEstablished(id);
      case PayloadReceived(:final id, :final bytes):
        _onPayloadReceived(id, bytes);
      case Disconnected(:final id):
        _onDisconnected(id);
    }
  }

  void _onEndpointDiscovered(EndpointId id, String displayName) {
    // Automatically request connection to discovered endpoints
    unawaited(_nearbyPort.requestConnection(id));
  }

  void _onConnectionEstablished(EndpointId id) {
    // Register pending handshake and send our NodeId
    _registry.registerPendingHandshake(id);
    final handshakeBytes = _encodeHandshake(_localNodeId);
    unawaited(_nearbyPort.sendPayload(id, handshakeBytes));
  }

  void _onPayloadReceived(EndpointId id, Uint8List bytes) {
    if (bytes.isEmpty) return;

    final messageType = bytes[0];

    if (messageType == 0x01) {
      // Handshake message
      _handleHandshakeMessage(id, bytes);
    } else if (messageType == 0x02) {
      // Gossip message
      _handleGossipMessage(id, bytes);
    }
  }

  void _handleHandshakeMessage(EndpointId id, Uint8List bytes) {
    final remoteNodeId = _decodeHandshake(bytes);
    if (remoteNodeId == null) {
      // Invalid handshake - could emit HandshakeFailed
      return;
    }

    final endpoint = Endpoint(id: id, displayName: '');
    final event = _registry.completeHandshake(endpoint, remoteNodeId);
    _eventController.add(event);
  }

  void _handleGossipMessage(EndpointId id, Uint8List bytes) {
    final nodeId = _registry.getNodeIdForEndpoint(id);
    if (nodeId == null) return; // Not connected yet

    // Unwrap the gossip message (remove 0x02 prefix)
    final payload = bytes.sublist(1);
    onGossipMessage?.call(nodeId, payload);
  }

  void _onDisconnected(EndpointId id) {
    final event = _registry.removeConnection(id, 'Disconnected');
    if (event != null) {
      _eventController.add(event);
    }
  }

  // --- Handshake Codec ---

  /// Encodes a handshake message.
  /// Format: [0x01][length:4 bytes][nodeId:UTF-8 bytes]
  Uint8List _encodeHandshake(NodeId nodeId) {
    final nodeIdBytes = utf8.encode(nodeId.value);
    final buffer = ByteData(5 + nodeIdBytes.length);
    buffer.setUint8(0, 0x01);
    buffer.setUint32(1, nodeIdBytes.length, Endian.big);
    final result = buffer.buffer.asUint8List();
    result.setRange(5, 5 + nodeIdBytes.length, nodeIdBytes);
    return result;
  }

  /// Decodes a handshake message.
  /// Returns null if invalid.
  NodeId? _decodeHandshake(Uint8List bytes) {
    if (bytes.length < 5) return null;
    if (bytes[0] != 0x01) return null;

    final buffer = ByteData.sublistView(bytes);
    final length = buffer.getUint32(1, Endian.big);
    if (bytes.length < 5 + length) return null;

    final nodeIdBytes = bytes.sublist(5, 5 + length);
    final nodeIdValue = utf8.decode(nodeIdBytes);
    return NodeId(nodeIdValue);
  }

  /// Wraps a gossip payload with message type prefix.
  Uint8List _wrapGossipMessage(Uint8List payload) {
    final result = Uint8List(1 + payload.length);
    result[0] = 0x02;
    result.setRange(1, 1 + payload.length, payload);
    return result;
  }
}
