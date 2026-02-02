import '../../domain/interfaces/entry_repository.dart';
import '../../domain/value_objects/channel_id.dart';
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

  /// Cache for latest sequence per author per stream.
  /// Structure: channelId → streamId → author → maxSequence
  final Map<ChannelId, Map<StreamId, Map<NodeId, int>>> _latestSequenceCache =
      {};

  @override
  void append(ChannelId channel, StreamId stream, LogEntry entry) {
    final channelMap = _storage.putIfAbsent(channel, () => {});
    final entries = channelMap.putIfAbsent(stream, () => []);

    // Check for duplicate entry (same author and sequence)
    final isDuplicate = entries.any(
      (e) => e.author == entry.author && e.sequence == entry.sequence,
    );
    if (isDuplicate) return;

    _insertSorted(entries, entry);
    _updateLatestSequenceCache(channel, stream, entry);
  }

  /// Inserts entry in sorted position using binary search. O(log n) search + O(n) insert.
  void _insertSorted(List<LogEntry> entries, LogEntry entry) {
    if (entries.isEmpty) {
      entries.add(entry);
      return;
    }

    final insertIndex = _findInsertIndex(entries, entry.timestamp);
    entries.insert(insertIndex, entry);
  }

  /// Binary search to find insertion index for maintaining timestamp order.
  int _findInsertIndex(List<LogEntry> entries, dynamic timestamp) {
    int low = 0;
    int high = entries.length;

    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (entries[mid].timestamp.compareTo(timestamp) <= 0) {
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
  void appendAll(ChannelId channel, StreamId stream, List<LogEntry> entries) {
    for (final entry in entries) {
      append(channel, stream, entry);
    }
  }

  @override
  List<LogEntry> getAll(ChannelId channel, StreamId stream) {
    return _storage[channel]?[stream]?.toList() ?? [];
  }

  @override
  List<LogEntry> entriesSince(
    ChannelId channel,
    StreamId stream,
    VersionVector since,
  ) {
    final entries = getAll(channel, stream);
    return entries.where((entry) {
      final authorSeq = since[entry.author];
      return entry.sequence > authorSeq;
    }).toList();
  }

  @override
  List<LogEntry> entriesForAuthorAfter(
    ChannelId channel,
    StreamId stream,
    NodeId author,
    int afterSequence,
  ) {
    final entries = getAll(channel, stream);
    return entries
        .where((e) => e.author == author && e.sequence > afterSequence)
        .toList();
  }

  @override
  int latestSequence(ChannelId channel, StreamId stream, NodeId author) {
    return _latestSequenceCache[channel]?[stream]?[author] ?? 0;
  }

  @override
  int entryCount(ChannelId channel, StreamId stream) {
    return _storage[channel]?[stream]?.length ?? 0;
  }

  @override
  int sizeBytes(ChannelId channel, StreamId stream) {
    final entries = getAll(channel, stream);
    return entries.fold(0, (sum, entry) => sum + entry.sizeBytes);
  }

  @override
  void removeEntries(ChannelId channel, StreamId stream, List<LogEntryId> ids) {
    final entries = _storage[channel]?[stream];
    if (entries == null) return;

    final idsSet = ids.toSet();
    entries.removeWhere((entry) => idsSet.contains(entry.id));

    _rebuildLatestSequenceCache(channel, stream, entries);
  }

  @override
  void clearStream(ChannelId channel, StreamId stream) {
    _storage[channel]?[stream]?.clear();
    _latestSequenceCache[channel]?.remove(stream);
  }

  @override
  void clearChannel(ChannelId channel) {
    _storage.remove(channel);
    _latestSequenceCache.remove(channel);
  }

  @override
  VersionVector getVersionVector(ChannelId channel, StreamId stream) {
    final streamCache = _latestSequenceCache[channel]?[stream];
    if (streamCache == null || streamCache.isEmpty) {
      return VersionVector.empty;
    }
    return VersionVector(Map<NodeId, int>.from(streamCache));
  }

  /// Rebuilds the latest sequence cache for a stream after entries are removed.
  void _rebuildLatestSequenceCache(
    ChannelId channel,
    StreamId stream,
    List<LogEntry> entries,
  ) {
    final channelCache = _latestSequenceCache.putIfAbsent(channel, () => {});
    final streamCache = <NodeId, int>{};

    for (final entry in entries) {
      final currentMax = streamCache[entry.author] ?? 0;
      if (entry.sequence > currentMax) {
        streamCache[entry.author] = entry.sequence;
      }
    }

    channelCache[stream] = streamCache;
  }
}
