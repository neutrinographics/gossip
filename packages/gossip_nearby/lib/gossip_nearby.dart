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
///   final nearby = NearbyTransport(
///     localNodeId: NodeId('my-device-uuid'),
///     serviceId: 'com.example.myapp',
///     strategy: Strategy.cluster,
///   );
///
///   // 2. Create gossip coordinator with nearby transport
///   final coordinator = await Coordinator.create(
///     localNode: NodeId('my-device-uuid'),
///     channelRepository: channelRepo,
///     peerRepository: peerRepo,
///     entryRepository: entryRepo,
///     messagePort: nearby.messagePort,
///   );
///
///   // 3. Start discovery and advertising
///   await nearby.start();
///
///   // 4. Listen for peer events
///   nearby.peerEvents.listen((event) {
///     switch (event) {
///       case PeerConnected(:final nodeId):
///         coordinator.addPeer(nodeId);
///       case PeerDisconnected(:final nodeId):
///         coordinator.removePeer(nodeId);
///     }
///   });
///
///   // 5. Start sync
///   await coordinator.start();
/// }
/// ```
///
/// ## Architecture
///
/// - **[NearbyTransport]**: Main entry point managing the full lifecycle
/// - **[NearbyMessagePort]**: Implements gossip's [MessagePort] interface
/// - **[NearbyConnectionManager]**: Handles discovery, advertising, and connections
/// - **[PeerEvent]**: Events emitted when peers connect/disconnect
///
/// ## Handshake Protocol
///
/// When a Nearby connection is established, the package performs a handshake
/// to exchange application-provided [NodeId]s. This decouples gossip peer
/// identity from Nearby endpoint IDs (which can change between sessions).
library;

export 'src/nearby_transport.dart';
export 'src/nearby_message_port.dart';
export 'src/nearby_connection_manager.dart';
export 'src/peer_event.dart';
export 'src/nearby_config.dart';
