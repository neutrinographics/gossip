/// A Dart library for synchronizing event streams across devices using gossip protocols.
///
/// This library provides a mobile-first, offline-capable event stream synchronization
/// system with sub-second convergence using gossip protocols and SWIM failure detection.
///
/// ## Quick Start
///
/// ```dart
/// import 'package:gossip/gossip.dart';
///
/// void main() async {
///   // 1. Create repositories (use in-memory for testing)
///   final channelRepo = InMemoryChannelRepository();
///   final peerRepo = InMemoryPeerRepository();
///   final entryRepo = InMemoryEntryRepository();
///
///   // 2. Create coordinator
///   final coordinator = await Coordinator.create(
///     localNode: NodeId('my-device'),
///     channelRepository: channelRepo,
///     peerRepository: peerRepo,
///     entryRepository: entryRepo,
///   );
///
///   // 3. Create a channel and stream
///   final channel = await coordinator.createChannel(ChannelId('my-channel'));
///   final stream = await channel.getOrCreateStream(StreamId('messages'));
///
///   // 4. Write and read entries
///   await stream.append(Uint8List.fromList(utf8.encode('Hello, World!')));
///   final entries = await stream.getAll();
///   print('Entries: ${entries.length}');
///
///   // 5. Clean up
///   await coordinator.dispose();
/// }
/// ```
///
/// ## Network Synchronization
///
/// To enable sync across devices, provide transport implementations:
///
/// ```dart
/// final coordinator = await Coordinator.create(
///   localNode: NodeId('device-1'),
///   channelRepository: channelRepo,
///   peerRepository: peerRepo,
///   entryRepository: entryRepo,
///   messagePort: MyBluetoothPort(),  // Your transport implementation
///   timerPort: RealTimePort(),        // Real time for production
/// );
///
/// // Add peers discovered via your transport
/// await coordinator.addPeer(NodeId('device-2'));
///
/// // Start synchronization
/// await coordinator.start();
/// ```
///
/// ## Key Concepts
///
/// - **[Coordinator]**: Main entry point managing sync lifecycle
/// - **[Channel]**: Logical grouping of streams with membership
/// - **[EventStream]**: Append-only log of entries
/// - **[LogEntry]**: Immutable entry with payload and HLC timestamp
///
/// ## Architecture
///
/// The library uses:
/// - **Gossip Protocol**: Anti-entropy sync with digest/delta exchange
/// - **SWIM Protocol**: Failure detection for peer health
/// - **Hybrid Logical Clocks**: Causally consistent timestamps
/// - **Version Vectors**: Efficient sync state tracking
///
/// See the `docs/adr/` directory for Architecture Decision Records explaining
/// the design rationale.
///
/// ## Threading Model
///
/// **Important**: All [Coordinator] operations must run in the same Dart isolate.
/// The library uses no locks - accessing from multiple isolates causes corruption.
library;

// Facade layer (main public API)
export 'src/facade/adaptive_timing_status.dart';
export 'src/facade/coordinator.dart';
export 'src/facade/coordinator_config.dart';
export 'src/facade/channel.dart';
export 'src/facade/event_stream.dart';
export 'src/facade/health_status.dart';
export 'src/facade/resource_usage.dart';
export 'src/facade/sync_state.dart';

// Domain value objects
export 'src/domain/value_objects/node_id.dart';
export 'src/domain/value_objects/channel_id.dart';
export 'src/domain/value_objects/stream_id.dart';
export 'src/domain/value_objects/log_entry.dart';
export 'src/domain/value_objects/log_entry_id.dart';
export 'src/domain/value_objects/hlc.dart';
export 'src/domain/value_objects/version_vector.dart';

// Domain entities
export 'src/domain/entities/peer.dart';
export 'src/domain/entities/peer_metrics.dart';
export 'src/domain/entities/stream_config.dart';

// Domain events
export 'src/domain/events/domain_event.dart';

// Domain errors
export 'src/domain/errors/sync_error.dart';
export 'src/domain/errors/domain_exception.dart';

// Domain interfaces (for custom implementations)
export 'src/domain/interfaces/retention_policy.dart';
export 'src/domain/interfaces/state_materializer.dart';
export 'src/domain/interfaces/channel_repository.dart';
export 'src/domain/interfaces/local_node_repository.dart';
export 'src/domain/interfaces/peer_repository.dart';
export 'src/domain/interfaces/entry_repository.dart';

// Infrastructure ports (for custom implementations)
export 'src/infrastructure/ports/message_port.dart';
export 'src/infrastructure/ports/time_port.dart';

// In-memory implementations (for testing and simple use cases)
export 'src/infrastructure/repositories/in_memory_channel_repository.dart';
export 'src/infrastructure/repositories/in_memory_local_node_repository.dart';
export 'src/infrastructure/repositories/in_memory_peer_repository.dart';
export 'src/infrastructure/stores/in_memory_entry_repository.dart';
export 'src/infrastructure/ports/in_memory_message_port.dart';
export 'src/infrastructure/ports/in_memory_time_port.dart';

// Production implementations
export 'src/infrastructure/ports/real_time_port.dart';

// Domain services
export 'src/domain/value_objects/rtt_estimate.dart';

// Observability
export 'src/application/observability/log_level.dart';
