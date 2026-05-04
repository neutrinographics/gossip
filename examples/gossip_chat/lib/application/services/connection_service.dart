import 'dart:async';

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

  /// Starts discovering nearby peers.
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
