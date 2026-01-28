/// Nearby Connections transport for gossip.
///
/// This package provides peer discovery, connection management, and message
/// delivery over Android/iOS Nearby Connections for the gossip sync library.
///
/// ## Quick Start
///
/// ```dart
/// import 'package:gossip/gossip.dart';
/// import 'package:gossip_nearby/gossip_nearby.dart';
///
/// void main() async {
///   // 1. Create the nearby transport
///   final transport = NearbyTransport(
///     localNodeId: NodeId('my-device-uuid'),
///     serviceId: ServiceId('com.example.myapp'),
///     displayName: 'My Device',
///   );
///
///   // 2. Create gossip coordinator with nearby transport
///   final coordinator = await Coordinator.create(
///     localNode: NodeId('my-device-uuid'),
///     channelRepository: channelRepo,
///     peerRepository: peerRepo,
///     entryRepository: entryRepo,
///     messagePort: transport.messagePort,
///   );
///
///   // 3. Listen for peer events
///   transport.peerEvents.listen((event) {
///     switch (event) {
///       case PeerConnected(:final nodeId):
///         coordinator.addPeer(nodeId);
///       case PeerDisconnected(:final nodeId):
///         coordinator.removePeer(nodeId);
///     }
///   });
///
///   // 4. Start advertising and discovery
///   await transport.startAdvertising();
///   await transport.startDiscovery();
///
///   // 5. Start sync
///   await coordinator.start();
/// }
/// ```
///
/// ## Architecture
///
/// - `NearbyTransport`: Main entry point managing the full lifecycle
/// - `PeerEvent`: Events emitted when peers connect/disconnect
/// - `ServiceId`: Identifier for your app's Nearby service
///
/// ## Handshake Protocol
///
/// When a Nearby connection is established, the package performs a handshake
/// to exchange application-provided `NodeId`s. This decouples gossip peer
/// identity from Nearby endpoint IDs (which can change between sessions).
library;

// Facade (main public API)
export 'src/facade/nearby_transport.dart'
    show NearbyTransport, PeerEvent, PeerConnected, PeerDisconnected;

// Domain value objects (needed for configuration)
export 'src/domain/value_objects/service_id.dart';

// Domain events (for observability)
export 'src/domain/events/connection_event.dart';

// Domain errors (for error handling)
export 'src/domain/errors/connection_error.dart';

// Observability (logging and metrics)
export 'src/application/observability/log_level.dart';
export 'src/application/observability/nearby_metrics.dart';
