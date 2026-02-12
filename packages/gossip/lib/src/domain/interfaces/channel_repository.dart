import '../value_objects/channel_id.dart';
import '../aggregates/channel_aggregate.dart';

/// Repository for persisting ChannelAggregate state.
///
/// [ChannelRepository] stores only channel metadata (membership, stream IDs,
/// version vectors). Log entries are stored separately via [EntryRepository] to
/// prevent memory exhaustion.
///
/// ## Persistence Scope
/// Each [ChannelAggregate] aggregate includes:
/// - Channel ID
/// - Member node IDs
/// - Stream IDs and configurations
/// - Version vectors per stream (sync state)
///
/// ## Usage
///
/// ```dart
/// // For testing
/// final channelRepo = InMemoryChannelRepository();
///
/// // Create coordinator with the repository
/// final coordinator = await Coordinator.create(
///   localNodeRepository: InMemoryLocalNodeRepository(),
///   channelRepository: channelRepo,
///   peerRepository: InMemoryPeerRepository(),
///   entryRepository: InMemoryEntryRepository(),
/// );
/// ```
///
/// ## Implementation Guidance
/// - Use key-value storage (SharedPreferences, localStorage) for simple cases
/// - Use relational storage (SQLite) for complex queries
/// - Serialize channels to JSON for persistence
/// - Consider caching frequently accessed channels in memory
///
/// See also:
/// - [InMemoryChannelRepository] for the reference implementation
/// - [EntryRepository] for log entry storage
abstract interface class ChannelRepository {
  /// Retrieves a channel by ID, or null if not found.
  Future<ChannelAggregate?> findById(ChannelId id);

  /// Persists a channel, creating or updating it.
  ///
  /// Overwrites any existing channel with the same ID.
  Future<void> save(ChannelAggregate channel);

  /// Deletes a channel by ID.
  ///
  /// No-op if the channel doesn't exist.
  Future<void> delete(ChannelId id);

  /// Returns IDs of all persisted channels.
  Future<List<ChannelId>> listIds();

  /// Returns true if a channel with the given ID exists.
  Future<bool> exists(ChannelId id);

  /// Returns the total number of persisted channels.
  Future<int> get count;
}
