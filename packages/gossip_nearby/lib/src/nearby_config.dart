import 'package:nearby_connections/nearby_connections.dart';

/// Configuration for Nearby Connections transport.
class NearbyConfig {
  /// Unique identifier for your app's Nearby service.
  ///
  /// This should be a reverse-domain identifier (e.g., 'com.example.myapp').
  /// Only devices advertising/discovering the same service ID can connect.
  final String serviceId;

  /// Connection strategy to use.
  ///
  /// For gossip sync, [Strategy.P2P_CLUSTER] is recommended as it supports
  /// many-to-many connections in a mesh topology.
  final Strategy strategy;

  /// Human-readable name to advertise to nearby devices.
  ///
  /// This is shown during discovery. If null, a default name is used.
  final String? displayName;

  /// Whether to automatically accept incoming connection requests.
  ///
  /// If false, you must handle connection requests manually via
  /// [NearbyTransport.connectionRequests].
  final bool autoAcceptConnections;

  /// Timeout for the handshake protocol after connection is established.
  ///
  /// If the NodeId exchange doesn't complete within this duration,
  /// the connection is dropped.
  final Duration handshakeTimeout;

  const NearbyConfig({
    required this.serviceId,
    this.strategy = Strategy.P2P_CLUSTER,
    this.displayName,
    this.autoAcceptConnections = true,
    this.handshakeTimeout = const Duration(seconds: 5),
  });
}
