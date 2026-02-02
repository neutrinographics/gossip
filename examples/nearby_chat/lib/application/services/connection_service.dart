import 'dart:async';

import 'package:gossip/gossip.dart';
import 'package:gossip_nearby/gossip_nearby.dart';

/// Service for managing Nearby Connections peer connections.
///
/// This is an application layer service that bridges the NearbyTransport
/// (infrastructure) with the Coordinator (domain).
class ConnectionService {
  final NearbyTransport _transport;
  final Coordinator _coordinator;

  StreamSubscription<PeerEvent>? _peerSubscription;

  ConnectionService({
    required NearbyTransport transport,
    required Coordinator coordinator,
  }) : _transport = transport,
       _coordinator = coordinator {
    _setupPeerEventHandling();
  }

  void _setupPeerEventHandling() {
    _peerSubscription = _transport.peerEvents.listen((event) {
      switch (event) {
        case PeerConnected(:final nodeId):
          _coordinator.addPeer(nodeId);
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

  /// Starts discovering nearby peers.
  Future<void> startDiscovery() async {
    await _transport.startDiscovery();
  }

  /// Stops discovery.
  Future<void> stopDiscovery() async {
    await _transport.stopDiscovery();
  }

  /// Whether advertising is currently active.
  bool get isAdvertising => _transport.isAdvertising;

  /// Whether discovery is currently active.
  bool get isDiscovering => _transport.isDiscovering;

  /// Currently connected peer count.
  int get connectedPeerCount => _transport.connectedPeerCount;

  /// Stream of peer events from transport.
  Stream<PeerEvent> get peerEvents => _transport.peerEvents;

  /// Stream of connection errors for observability.
  Stream<ConnectionError> get errors => _transport.errors;

  /// Metrics for monitoring transport health and performance.
  NearbyMetrics get metrics => _transport.metrics;

  /// Disposes resources.
  Future<void> dispose() async {
    await _peerSubscription?.cancel();
  }
}
