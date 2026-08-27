import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';

/// Repository abstraction for persisting log entries separately from aggregates.
///
/// [EntryRepository] manages the persistent storage of log entries outside of
/// domain aggregates. This separation prevents memory exhaustion when streams
/// contain many entries. The `ChannelAggregate` holds membership and stream
/// metadata; version vectors are this repository's responsibility, not the
/// aggregate's (see [getVersionVector]).
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
/// - [getAll] and [entriesSince] MUST return entries in the full
///   [LogEntry.compareTo] total order: timestamp, then author, then
///   sequence. Sorting by timestamp alone is NOT sufficient — HLC ties
///   would then be ordered by arrival, which differs across peers, and
///   non-commutative materializers would converge to different states on
///   different devices.
///
/// ## Critical Invariants (violating these corrupts sync)
///
/// 1. **[getVersionVector] and [latestSequence] are monotonic high-water
///    marks over everything EVER appended.** They must never regress —
///    not on [removeEntries] (compaction) and not across process restarts.
///    Deriving them from surviving rows (e.g. `SELECT MAX(sequence)`)
///    reintroduces two data-corruption bugs: compacted entries are
///    re-fetched from peers every round (resurrection), and after all of
///    an author's entries are pruned the author re-issues already-used
///    sequence numbers — making its new entries permanently invisible to
///    peers whose version vectors already cover them. Persist the marks
///    separately from the entries themselves.
/// 2. **Duplicate (author, sequence) pairs must throw [StateError].**
///    Silently dropping a duplicate is how a sequence-allocation race
///    loses an entry with no trace. Callers (the sync engine) filter
///    duplicates before appending; a duplicate reaching the repository is
///    a bug that must surface.
/// 3. **[appendAll] is all-or-nothing.** If any entry of the batch is
///    invalid (duplicate against the store or within the batch), the
///    whole batch must be rejected atomically with [StateError] — partial
///    application leaves entries the version vector covers but the
///    application never saw.
///
/// ## Implementation Guidance
///
/// **Testing:** Use `InMemoryEntryRepository` for unit and integration tests:
///
/// ```dart
/// final entryRepo = InMemoryEntryRepository();
/// final coordinator = await Coordinator.create(
///   localNodeRepository: InMemoryLocalNodeRepository(),
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
/// - `InMemoryEntryRepository` for the reference implementation
/// - `ChannelRepository` for channel metadata storage
abstract interface class EntryRepository {
  /// Appends a locally-authored entry to a stream.
  ///
  /// The entry must have the next sequence number for its author.
  /// Throws [StateError] if an entry with the same (author, sequence)
  /// already exists — never silently skip it (see Critical Invariants).
  ///
  /// Used when: The local node creates a new entry.
  Future<void> append(ChannelId channel, StreamId stream, LogEntry entry);

  /// Appends multiple entries atomically during synchronization.
  ///
  /// All-or-nothing: if any entry is a duplicate — against the store or
  /// within the batch — the whole batch must be rejected with [StateError]
  /// and nothing applied. Skip-and-continue semantics are NOT permitted
  /// (see Critical Invariants). Implementations should use transactions.
  ///
  /// Used when: Merging entries received from a peer during anti-entropy.
  Future<void> appendAll(
    ChannelId channel,
    StreamId stream,
    List<LogEntry> entries,
  );

  /// Returns all entries for a stream.
  ///
  /// Returns entries in the full [LogEntry.compareTo] total order —
  /// timestamp, then author, then sequence. Timestamp alone is not
  /// sufficient: HLC ties ordered by arrival diverge across peers (see
  /// Ordering Guarantees above). For large streams (10K+ entries),
  /// implementations should consider pagination or streaming results.
  ///
  /// Used when: Computing version vectors, applying retention policies.
  Future<List<LogEntry>> getAll(ChannelId channel, StreamId stream);

  /// Returns entries missing from the given version vector.
  ///
  /// For each author, returns entries where `sequence > since[author]`.
  /// This efficiently identifies which entries to send during anti-entropy
  /// without transmitting the entire log.
  ///
  /// Returns entries in the full [LogEntry.compareTo] total order —
  /// timestamp, then author, then sequence. Timestamp alone is not
  /// sufficient: HLC ties ordered by arrival diverge across peers (see
  /// Ordering Guarantees above).
  ///
  /// Used when: Responding to delta requests during gossip.
  Future<List<LogEntry>> entriesSince(
    ChannelId channel,
    StreamId stream,
    VersionVector since,
  );

  /// Returns the highest sequence number ever appended by an author, or 0
  /// if the author never appended to this stream.
  ///
  /// This is a monotonic high-water mark: it must reflect entries that
  /// have since been removed by [removeEntries], and it must survive
  /// process restarts (see Critical Invariants). "No surviving entries"
  /// does NOT mean 0.
  ///
  /// Used when: Determining the next sequence number for a local entry.
  Future<int> latestSequence(ChannelId channel, StreamId stream, NodeId author);

  /// Returns the number of entries in a stream.
  ///
  /// Used when: Monitoring storage usage, enforcing quotas.
  Future<int> entryCount(ChannelId channel, StreamId stream);

  /// Returns the total storage size of a stream in bytes.
  ///
  /// Sums the [LogEntry.sizeBytes] for all entries in the stream.
  ///
  /// Used when: Monitoring storage usage, triggering compaction.
  Future<int> sizeBytes(ChannelId channel, StreamId stream);

  /// Removes specific entries during compaction.
  ///
  /// Deletes entries identified by their IDs. Implementations should use
  /// transactions to ensure atomicity when removing multiple entries.
  ///
  /// MUST NOT regress [getVersionVector] or [latestSequence]: the
  /// high-water marks reflect everything ever appended, including the
  /// entries removed here (see Critical Invariants).
  ///
  /// Used when: Applying retention policies to reclaim storage.
  Future<void> removeEntries(
    ChannelId channel,
    StreamId stream,
    List<LogEntryId> ids,
  );

  /// Removes all entries from a stream, including its high-water marks.
  ///
  /// Unlike [removeEntries], this resets [getVersionVector] and
  /// [latestSequence] for the stream — correct only when the stream
  /// identity is being retired. WARNING: clearing a stream that still
  /// exists on peers (or recreating one under the same channel/stream IDs)
  /// restarts sequence allocation at 1 while peers' version vectors still
  /// cover the old numbers — new local entries become permanently
  /// invisible to them.
  ///
  /// Used when: Deleting a stream or clearing data for testing.
  Future<void> clearStream(ChannelId channel, StreamId stream);

  /// Removes all entries from all streams in a channel.
  ///
  /// Used when: Deleting a channel or clearing data for testing.
  Future<void> clearChannel(ChannelId channel);

  /// Returns the version vector for a stream.
  ///
  /// Maps each author to the highest sequence number they EVER appended —
  /// a monotonic high-water mark that must survive [removeEntries] and
  /// process restarts, NOT a summary of surviving rows (see Critical
  /// Invariants). Returns an empty version vector only if nothing was
  /// ever appended.
  ///
  /// This method should be O(1) for implementations that cache the version
  /// vector, avoiding the need to iterate all entries.
  ///
  /// Used when: Computing stream digests for anti-entropy gossip protocol.
  Future<VersionVector> getVersionVector(ChannelId channel, StreamId stream);

  /// Returns the compaction floor for a stream.
  ///
  /// Maps each author to the highest sequence number no longer obtainable
  /// from this node — removed by [removeEntries] (compaction) or adopted
  /// as truncated history via [adoptVersionFloor]. Empty for authors that
  /// were never compacted.
  ///
  /// Like [getVersionVector] this is a monotonic high-water mark: it must
  /// survive process restarts and is reset only when the stream identity
  /// is retired ([clearStream], [clearChannel], [clearAll]).
  ///
  /// Used when: Serving delta requests — a requester positioned below the
  /// floor is told so, letting it adopt truncated history instead of
  /// waiting forever for entries nobody can provide.
  Future<VersionVector> getCompactionFloor(ChannelId channel, StreamId stream);

  /// Accepts truncated history: for each author in [floor], raises both
  /// the compaction floor and the version-vector high-water mark
  /// ([getVersionVector], [latestSequence]) to the floor's sequence.
  ///
  /// Called when a peer's delta response reports that entries below its
  /// floor were compacted away. The range up to the floor becomes
  /// covered-but-unavailable: entries above it merge contiguously, and the
  /// range is never re-requested — the retention policy that pruned it
  /// declared it disposable.
  ///
  /// Monotonic: authors whose floor is at or below the current high-water
  /// mark are ignored (we hold those entries).
  Future<void> adoptVersionFloor(
    ChannelId channel,
    StreamId stream,
    VersionVector floor,
  );

  /// Removes all entries from all channels and streams.
  ///
  /// Used when resetting all sync state (e.g., user logout).
  Future<void> clearAll();

  /// Returns the HLC timestamp of the last (tail) entry in the stream,
  /// or null if the stream has no entries.
  ///
  /// O(1) for implementations that maintain sorted entry lists in memory.
  ///
  /// Used when: Detecting out-of-order entry insertion during merge.
  Future<Hlc?> getTailTimestamp(ChannelId channel, StreamId stream);
}
