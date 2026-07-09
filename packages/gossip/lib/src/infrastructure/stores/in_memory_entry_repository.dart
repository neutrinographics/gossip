import '../../domain/interfaces/entry_repository.dart';
import '../../domain/value_objects/channel_id.dart';
import '../../domain/value_objects/hlc.dart';
import '../../domain/value_objects/log_entry.dart';
import '../../domain/value_objects/log_entry_id.dart';
import '../../domain/value_objects/node_id.dart';
import '../../domain/value_objects/stream_id.dart';
import '../../domain/value_objects/version_vector.dart';

/// In-memory implementation of [EntryRepository] for testing.
///
/// This implementation stores all entries in memory using a nested [Map]
/// structure. All data is lost when the application terminates.
///
/// **Use only for testing and prototyping.**
///
/// For production applications, implement [EntryRepository] with persistent storage:
/// - **SQLite** for mobile/desktop apps
///   - Create table: `entries(channel_id, stream_id, author, sequence, timestamp, payload)`
///   - Index on `(channel_id, stream_id, author, sequence)` for fast lookups
///   - Index on `(channel_id, stream_id, timestamp)` for ordering
/// - **IndexedDB** for web apps
///   - Similar indexing strategy for efficient queries
///
/// ## Storage Structure
/// Nested maps organize entries by channel and stream:
/// ```
/// Map<ChannelId, Map<StreamId, List<LogEntry>>>
/// ```
///
/// Entries within each stream list are kept sorted by HLC timestamp to
/// maintain causal ordering.
///
/// ## Performance Characteristics
/// - Append: O(n) with binary search for insertion position
/// - latestSequence: O(1) via cache
/// - Other queries: O(n) linear scan over entries
/// - Not suitable for production with large entry counts
class InMemoryEntryRepository implements EntryRepository {
  /// Storage: channelId → streamId → list of entries (sorted by timestamp)
  final Map<ChannelId, Map<StreamId, List<LogEntry>>> _storage = {};

  /// Monotonic high-water mark of the latest sequence per author per stream.
  /// Structure: channelId → streamId → author → maxSequence
  ///
  /// NEVER regresses on [removeEntries] (compaction): [latestSequence] and
  /// [getVersionVector] must reflect everything the stream has EVER held,
  /// or compaction would cause entry resurrection and sequence reuse.
  /// Persistent implementations must persist this separately from the
  /// entries themselves.
  final Map<ChannelId, Map<StreamId, Map<NodeId, int>>> _latestSequenceCache =
      {};

  /// Compaction floor per stream: the highest sequence per author removed
  /// by [removeEntries] or adopted via [adoptVersionFloor] — entries at or
  /// below it are no longer obtainable from this node.
  ///
  /// Monotonic like [_latestSequenceCache]; reset only when the stream
  /// identity is retired ([clearStream]/[clearChannel]/[clearAll]).
  /// Persistent implementations must persist this separately from the
  /// entries themselves.
  final Map<ChannelId, Map<StreamId, Map<NodeId, int>>> _compactionFloorCache =
      {};

  @override
  Future<void> append(
    ChannelId channel,
    StreamId stream,
    LogEntry entry,
  ) async {
    final channelMap = _storage.putIfAbsent(channel, () => {});
    final entries = channelMap.putIfAbsent(stream, () => []);

    // Duplicate (author, sequence) is a contract violation, not data to
    // drop: silently discarding it is how a sequence-allocation race
    // loses an entry with no trace.
    final isDuplicate = entries.any(
      (e) => e.author == entry.author && e.sequence == entry.sequence,
    );
    if (isDuplicate) {
      throw StateError(
        'Entry ${entry.author}#${entry.sequence} already exists in '
        '$channel/$stream',
      );
    }

    _insertSorted(entries, entry);
    _updateLatestSequenceCache(channel, stream, entry);
  }

  /// Inserts entry in sorted position using binary search. O(log n) search + O(n) insert.
  void _insertSorted(List<LogEntry> entries, LogEntry entry) {
    if (entries.isEmpty) {
      entries.add(entry);
      return;
    }

    final insertIndex = _findInsertIndex(entries, entry);
    entries.insert(insertIndex, entry);
  }

  /// Binary search for the insertion index using the full [LogEntry]
  /// ordering (timestamp → author → sequence).
  ///
  /// Comparing timestamps alone would order HLC ties by arrival, which
  /// differs across peers — non-commutative materializers would then
  /// converge to different states on different devices.
  int _findInsertIndex(List<LogEntry> entries, LogEntry entry) {
    int low = 0;
    int high = entries.length;

    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (entries[mid].compareTo(entry) <= 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  /// Updates the latest sequence cache for the entry's author.
  void _updateLatestSequenceCache(
    ChannelId channel,
    StreamId stream,
    LogEntry entry,
  ) {
    final channelCache = _latestSequenceCache.putIfAbsent(channel, () => {});
    final streamCache = channelCache.putIfAbsent(stream, () => {});
    final currentMax = streamCache[entry.author] ?? 0;
    if (entry.sequence > currentMax) {
      streamCache[entry.author] = entry.sequence;
    }
  }

  @override
  Future<void> appendAll(
    ChannelId channel,
    StreamId stream,
    List<LogEntry> entries,
  ) async {
    // Validate the whole batch first (against the store AND within the
    // batch) so the operation is all-or-nothing per the interface
    // contract.
    final stored = _storage
        .putIfAbsent(channel, () => {})
        .putIfAbsent(stream, () => []);
    final seen = <(NodeId, int)>{for (final e in stored) (e.author, e.sequence)};
    for (final entry in entries) {
      if (!seen.add((entry.author, entry.sequence))) {
        throw StateError(
          'Entry ${entry.author}#${entry.sequence} already exists in '
          '$channel/$stream (appendAll is all-or-nothing)',
        );
      }
    }

    // Insert without yielding: an await per entry would open interleaving
    // windows in which a concurrent overlapping merge passes its own
    // validation and the batch is only partially applied — despite the
    // all-or-nothing contract. The set above already proved uniqueness,
    // so the per-entry duplicate scan is skipped too.
    for (final entry in entries) {
      _insertSorted(stored, entry);
      _updateLatestSequenceCache(channel, stream, entry);
    }
  }

  @override
  Future<List<LogEntry>> getAll(ChannelId channel, StreamId stream) async {
    return _storage[channel]?[stream]?.toList() ?? [];
  }

  @override
  Future<List<LogEntry>> entriesSince(
    ChannelId channel,
    StreamId stream,
    VersionVector since,
  ) async {
    final entries = await getAll(channel, stream);
    return entries.where((entry) {
      final authorSeq = since[entry.author];
      return entry.sequence > authorSeq;
    }).toList();
  }

  @override
  Future<List<LogEntry>> entriesForAuthorAfter(
    ChannelId channel,
    StreamId stream,
    NodeId author,
    int afterSequence,
  ) async {
    final entries = await getAll(channel, stream);
    return entries
        .where((e) => e.author == author && e.sequence > afterSequence)
        .toList();
  }

  @override
  Future<int> latestSequence(
    ChannelId channel,
    StreamId stream,
    NodeId author,
  ) async {
    return _latestSequenceCache[channel]?[stream]?[author] ?? 0;
  }

  @override
  Future<int> entryCount(ChannelId channel, StreamId stream) async {
    return _storage[channel]?[stream]?.length ?? 0;
  }

  @override
  Future<int> sizeBytes(ChannelId channel, StreamId stream) async {
    final entries = await getAll(channel, stream);
    return entries.fold<int>(0, (sum, entry) => sum + entry.sizeBytes);
  }

  @override
  Future<void> removeEntries(
    ChannelId channel,
    StreamId stream,
    List<LogEntryId> ids,
  ) async {
    final entries = _storage[channel]?[stream];
    if (entries == null) return;

    final idsSet = ids.toSet();
    final floor = _compactionFloorCache
        .putIfAbsent(channel, () => {})
        .putIfAbsent(stream, () => {});
    entries.removeWhere((entry) {
      if (!idsSet.contains(entry.id)) return false;
      // Removed by compaction: raise the floor so delta responses can tell
      // requesters positioned below it that the range is unobtainable.
      if (entry.sequence > (floor[entry.author] ?? 0)) {
        floor[entry.author] = entry.sequence;
      }
      return true;
    });

    // Deliberately do NOT rebuild _latestSequenceCache from survivors:
    // it is a monotonic high-water mark. Regressing it after compaction
    // would (a) advertise a lower version vector, making peers re-send
    // pruned entries every round, and (b) re-issue already-used sequence
    // numbers, making new local entries permanently invisible to peers
    // whose version vector already covers them.
  }

  @override
  Future<void> clearStream(ChannelId channel, StreamId stream) async {
    _storage[channel]?[stream]?.clear();
    _latestSequenceCache[channel]?.remove(stream);
    _compactionFloorCache[channel]?.remove(stream);
  }

  @override
  Future<void> clearChannel(ChannelId channel) async {
    _storage.remove(channel);
    _latestSequenceCache.remove(channel);
    _compactionFloorCache.remove(channel);
  }

  @override
  Future<VersionVector> getVersionVector(
    ChannelId channel,
    StreamId stream,
  ) async {
    final streamCache = _latestSequenceCache[channel]?[stream];
    if (streamCache == null || streamCache.isEmpty) {
      return VersionVector.empty;
    }
    return VersionVector(Map<NodeId, int>.from(streamCache));
  }

  @override
  Future<void> clearAll() async {
    _storage.clear();
    _latestSequenceCache.clear();
    _compactionFloorCache.clear();
  }

  @override
  Future<VersionVector> getCompactionFloor(
    ChannelId channel,
    StreamId stream,
  ) async {
    final streamFloor = _compactionFloorCache[channel]?[stream];
    if (streamFloor == null || streamFloor.isEmpty) {
      return VersionVector.empty;
    }
    return VersionVector(Map<NodeId, int>.from(streamFloor));
  }

  @override
  Future<void> adoptVersionFloor(
    ChannelId channel,
    StreamId stream,
    VersionVector floor,
  ) async {
    final streamCache = _latestSequenceCache
        .putIfAbsent(channel, () => {})
        .putIfAbsent(stream, () => {});
    final streamFloor = _compactionFloorCache
        .putIfAbsent(channel, () => {})
        .putIfAbsent(stream, () => {});
    for (final adopted in floor.entries.entries) {
      final author = adopted.key;
      final seq = adopted.value;
      // Only ranges beyond our high-water mark are truncated history; at
      // or below it we hold (or already adopted) the entries.
      if (seq <= (streamCache[author] ?? 0)) continue;
      streamCache[author] = seq;
      streamFloor[author] = seq;
    }
  }

  @override
  Future<Hlc?> getTailTimestamp(ChannelId channel, StreamId stream) async {
    final entries = _storage[channel]?[stream];
    return (entries != null && entries.isNotEmpty)
        ? entries.last.timestamp
        : null;
  }

}
