import '../value_objects/channel_id.dart';
import '../value_objects/log_entry.dart';
import '../value_objects/log_entry_id.dart';
import '../value_objects/node_id.dart';
import '../value_objects/stream_id.dart';
import '../value_objects/version_vector.dart';

/// Repository abstraction for persisting log entries separately from aggregates.
///
/// [EntryRepository] manages the persistent storage of log entries outside of
/// domain aggregates. This separation prevents memory exhaustion when streams
/// contain many entries. The [ChannelAggregate] maintains only metadata
/// (version vectors, stream IDs), while actual entries live in the repository.
///
/// ## Why Separate Entry Storage?
///
/// In event-sourced systems, streams can grow unbounded. Storing entries
/// in-memory with aggregates would:
/// - Exhaust memory with long-lived streams
/// - Make aggregate serialization slow
/// - Prevent efficient pagination
///
/// See ADR-002 for the full design rationale.
///
/// ## Storage Key Structure
/// Entries are uniquely identified by:
/// - Channel ID
/// - Stream ID
/// - Author (NodeId)
/// - Sequence number
///
/// ## Ordering Guarantees
/// - [getAll] returns entries sorted by HLC timestamp (causally ordered)
/// - [entriesSince] maintains timestamp ordering
/// - [entriesForAuthorAfter] returns entries in sequence order
///
/// ## Implementation Guidance
///
/// **Testing:** Use [InMemoryEntryRepository] for unit and integration tests:
///
/// ```dart
/// final entryRepo = InMemoryEntryRepository();
/// final coordinator = await Coordinator.create(
///   localNode: NodeId('test'),
///   channelRepository: InMemoryChannelRepository(),
///   peerRepository: InMemoryPeerRepository(),
///   entryRepository: entryRepo,
/// );
/// ```
///
/// **Production:** Implement with persistent storage:
/// - SQLite for mobile/desktop apps
/// - IndexedDB for web apps
/// - Add indexes on (channel, stream, author, sequence) for fast lookups
/// - Use transactions for atomic operations ([appendAll], [removeEntries])
/// - Consider pagination for [getAll] with streams containing 10K+ entries
///
/// **Concurrency:** If accessed from multiple isolates, implementations must
/// handle synchronization to prevent race conditions.
///
/// See also:
/// - [InMemoryEntryRepository] for the reference implementation
/// - [ChannelRepository] for channel metadata storage
abstract interface class EntryRepository {
  /// Appends a locally-authored entry to a stream.
  ///
  /// The entry must have the next sequence number for its author.
  /// Throws if the sequence number is invalid or if the entry already exists.
  ///
  /// Used when: The local node creates a new entry.
  void append(ChannelId channel, StreamId stream, LogEntry entry);

  /// Appends multiple entries atomically during synchronization.
  ///
  /// All entries are added in a single operation. If any entry fails
  /// validation, none are added. Implementations should use transactions
  /// to ensure atomicity.
  ///
  /// Used when: Merging entries received from a peer during anti-entropy.
  void appendAll(ChannelId channel, StreamId stream, List<LogEntry> entries);

  /// Returns all entries for a stream, ordered by timestamp.
  ///
  /// Entries are sorted by HLC timestamp to preserve causal ordering.
  /// For large streams (10K+ entries), implementations should consider
  /// pagination or streaming results.
  ///
  /// Used when: Computing version vectors, applying retention policies.
  List<LogEntry> getAll(ChannelId channel, StreamId stream);

  /// Returns entries missing from the given version vector.
  ///
  /// For each author, returns entries where sequence > since[author].
  /// This efficiently identifies which entries to send during anti-entropy
  /// without transmitting the entire log.
  ///
  /// Returns entries in timestamp order.
  ///
  /// Used when: Responding to delta requests during gossip.
  List<LogEntry> entriesSince(
    ChannelId channel,
    StreamId stream,
    VersionVector since,
  );

  /// Returns entries from a specific author after a sequence number.
  ///
  /// Returns entries where author matches and sequence > afterSequence.
  /// Results are in sequence order.
  ///
  /// Used when: Resolving out-of-order entry gaps for a specific author.
  List<LogEntry> entriesForAuthorAfter(
    ChannelId channel,
    StreamId stream,
    NodeId author,
    int afterSequence,
  );

  /// Returns the highest sequence number for an author, or 0 if none exist.
  ///
  /// Used when: Determining the next sequence number for a local entry.
  int latestSequence(ChannelId channel, StreamId stream, NodeId author);

  /// Returns the number of entries in a stream.
  ///
  /// Used when: Monitoring storage usage, enforcing quotas.
  int entryCount(ChannelId channel, StreamId stream);

  /// Returns the total storage size of a stream in bytes.
  ///
  /// Sums the [LogEntry.sizeBytes] for all entries in the stream.
  ///
  /// Used when: Monitoring storage usage, triggering compaction.
  int sizeBytes(ChannelId channel, StreamId stream);

  /// Removes specific entries during compaction.
  ///
  /// Deletes entries identified by their IDs. Implementations should use
  /// transactions to ensure atomicity when removing multiple entries.
  ///
  /// Used when: Applying retention policies to reclaim storage.
  void removeEntries(ChannelId channel, StreamId stream, List<LogEntryId> ids);

  /// Removes all entries from a stream.
  ///
  /// Used when: Deleting a stream or clearing data for testing.
  void clearStream(ChannelId channel, StreamId stream);

  /// Removes all entries from all streams in a channel.
  ///
  /// Used when: Deleting a channel or clearing data for testing.
  void clearChannel(ChannelId channel);

  /// Returns the version vector for a stream.
  ///
  /// The version vector maps each author to their highest sequence number.
  /// Returns an empty version vector if the stream has no entries.
  ///
  /// This method should be O(1) for implementations that cache the version
  /// vector, avoiding the need to iterate all entries.
  ///
  /// Used when: Computing stream digests for anti-entropy gossip protocol.
  VersionVector getVersionVector(ChannelId channel, StreamId stream);
}
