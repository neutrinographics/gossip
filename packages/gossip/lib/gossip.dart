/// A Dart library for synchronizing event streams across devices using gossip protocols.
///
/// This library provides a mobile-first, offline-capable event stream synchronization
/// system with fast, eventually-consistent convergence (O(log n) rounds) using
/// gossip protocols and SWIM failure detection.
///
/// ## Quick Start
///
/// ```dart
/// import 'dart:convert';
/// import 'dart:typed_data';
///
/// import 'package:gossip/gossip.dart';
///
/// void main() async {
///   // 1. Create repositories (use in-memory for testing)
///   final channelRepo = InMemoryChannelRepository();
///   final peerRepo = InMemoryPeerRepository();
///   final entryRepo = InMemoryEntryRepository();
///
///   final localNodeRepo = InMemoryLocalNodeRepository();
///
///   // 2. Create coordinator
///   final coordinator = await Coordinator.create(
///     localNodeRepository: localNodeRepo,
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
///   localNodeRepository: localNodeRepo,
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

import 'package:gossip/src/coordinator/coordinator.dart';
import 'package:gossip/src/coordinator/channel.dart';
import 'package:gossip/src/coordinator/event_stream.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';

// Coordinator layer (main public API; composition root)
export 'package:gossip/src/coordinator/adaptive_timing_status.dart';
export 'package:gossip/src/coordinator/coordinator.dart';
export 'package:gossip/src/coordinator/coordinator_config.dart';
export 'package:gossip/src/coordinator/channel.dart';
export 'package:gossip/src/coordinator/event_stream.dart';
export 'package:gossip/src/coordinator/gossip_sync_activity.dart';
export 'package:gossip/src/coordinator/health_status.dart';
export 'package:gossip/src/coordinator/resource_usage.dart';
export 'package:gossip/src/coordinator/sync_state.dart';

// Domain value objects
export 'package:gossip/src/shared/domain/value_objects/node_id.dart';
export 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
export 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
export 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
export 'package:gossip/src/shared/domain/value_objects/log_entry_id.dart';
export 'package:gossip/src/shared/domain/value_objects/hlc.dart';
export 'package:gossip/src/shared/domain/value_objects/version_vector.dart';

// Domain aggregates
export 'package:gossip/src/sync/domain/aggregates/channel_aggregate.dart';

// Domain entities
export 'package:gossip/src/membership/domain/entities/peer.dart';
export 'package:gossip/src/membership/domain/entities/peer_metrics.dart';
export 'package:gossip/src/sync/domain/entities/stream_config.dart';

// Domain events
export 'package:gossip/src/shared/domain/events/domain_event.dart';
export 'package:gossip/src/sync/domain/events/sync_events.dart';
export 'package:gossip/src/membership/domain/events/membership_events.dart';
export 'package:gossip/src/membership/domain/value_objects/peer_status.dart';

// Domain errors
export 'package:gossip/src/shared/domain/errors/sync_error.dart';
export 'package:gossip/src/shared/domain/errors/domain_exception.dart';

// Domain results
export 'package:gossip/src/sync/domain/value_objects/compaction_result.dart';

// Domain interfaces (for custom implementations)
export 'package:gossip/src/sync/domain/interfaces/retention_policy.dart';
export 'package:gossip/src/sync/domain/interfaces/state_materializer.dart';
export 'package:gossip/src/sync/domain/interfaces/channel_repository.dart';
export 'package:gossip/src/shared/domain/interfaces/local_node_repository.dart';
export 'package:gossip/src/membership/domain/interfaces/peer_repository.dart';
export 'package:gossip/src/sync/domain/interfaces/entry_repository.dart';

// Infrastructure ports (for custom implementations)
export 'package:gossip/src/shared/domain/interfaces/message_port.dart';
export 'package:gossip/src/shared/domain/interfaces/time_port.dart';

// In-memory implementations (for testing and simple use cases)
export 'package:gossip/src/sync/infrastructure/caching_channel_repository.dart';
export 'package:gossip/src/sync/infrastructure/in_memory_channel_repository.dart';
export 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
export 'package:gossip/src/membership/infrastructure/in_memory_peer_repository.dart';
export 'package:gossip/src/sync/infrastructure/in_memory_entry_repository.dart';
export 'package:gossip/src/shared/infrastructure/in_memory_message_port.dart';
export 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';

// Production implementations
export 'package:gossip/src/shared/infrastructure/real_time_port.dart';

// Domain services
export 'package:gossip/src/shared/domain/value_objects/rtt_estimate.dart';

// Observability
export 'package:gossip/src/shared/domain/value_objects/log_level.dart';
