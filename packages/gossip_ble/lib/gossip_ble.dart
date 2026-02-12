/// Bluetooth Low Energy transport for gossip.
///
/// This package provides BLE-based peer discovery, connection management,
/// and message delivery for the gossip protocol.
///
/// ## Quick Start
///
/// ```dart
/// import 'package:gossip/gossip.dart';
/// import 'package:gossip_ble/gossip_ble.dart';
///
/// // Create transport (resolves node ID automatically)
/// final localNodeRepo = InMemoryLocalNodeRepository();
/// final transport = await BleTransport.create(
///   localNodeRepository: localNodeRepo,
///   serviceId: ServiceId('com.example.app'),
///   displayName: 'My Device',
/// );
///
/// // Create gossip coordinator (same repo guarantees same node ID)
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
/// // Start BLE advertising and discovery
/// await transport.startAdvertising();
/// await transport.startDiscovery();
/// ```
library;

// Facade - main entry point
export 'src/facade/ble_transport.dart'
    show BleTransport, PeerEvent, PeerConnected, PeerDisconnected;

// Domain - value objects
export 'src/domain/value_objects/device_id.dart' show DeviceId;
export 'src/domain/value_objects/service_id.dart' show ServiceId;

// Domain - events
export 'src/domain/events/connection_event.dart'
    show ConnectionEvent, HandshakeCompleted, HandshakeFailed, ConnectionClosed;

// Application - observability
export 'src/application/observability/log_level.dart'
    show LogLevel, LogCallback;
export 'src/application/observability/ble_metrics.dart' show BleMetrics;

// Domain - errors
export 'src/domain/errors/connection_error.dart'
    show
        ConnectionError,
        ConnectionErrorType,
        ConnectionNotFoundError,
        HandshakeTimeoutError,
        HandshakeInvalidError,
        SendFailedError,
        ConnectionLostError;
