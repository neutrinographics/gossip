# Cursor-Based Pagination for Entry Streams

This document describes how to add paginated access to entries in your
`EntryRepository` implementation. The gossip library's `getAll()` method
loads every entry in a stream at once, which is fine for the internal
sync protocol but unsuitable for application UIs with large streams.
Pagination is intentionally left out of the library interface — implement
it directly on your concrete repository subclass.

## Design

Use **cursor-based pagination** with `LogEntry? after` as the cursor.

```dart
class EntryPage {
  final List<LogEntry> entries;
  final bool hasMore;
  const EntryPage({required this.entries, required this.hasMore});
}

// Add to your EntryRepository subclass:
Future<EntryPage> getEntries(
  ChannelId channel,
  StreamId stream, {
  LogEntry? after,
  required int limit,
});
```

### Why cursor-based?

Offset-based pagination (`OFFSET n`) is fragile when entries are inserted
concurrently (gossip merges happen in the background). A cursor anchored
to a specific entry is stable — new entries before or after the cursor
don't shift the page window.

## Ordering

Entries are ordered by `LogEntry.compareTo`, which compares:

1. **HLC physical time** (`timestamp.physicalMs`) — milliseconds since epoch
2. **HLC logical counter** (`timestamp.logical`) — tiebreaker within the same millisecond
3. **Author** (`author.value`) — string comparison of the NodeId UUID
4. **Sequence number** (`sequence`) — per-author monotonic counter

This four-part key is fully deterministic: no two distinct entries compare
equal, even when concurrent writes on different devices produce identical
HLC timestamps.

## Consumer usage

```dart
// First page
var page = await myRepo.getEntries(channel, stream, limit: 50);
process(page.entries);

// Subsequent pages — pass the last entry as the cursor
while (page.hasMore) {
  page = await myRepo.getEntries(
    channel, stream,
    after: page.entries.last,
    limit: 50,
  );
  process(page.entries);
}
```

## Implementation guidance

### Detecting `hasMore` efficiently

Fetch `limit + 1` rows, then return only `limit`. If you got the extra
row, set `hasMore = true`. This avoids a separate `COUNT(*)` query.

```dart
final rows = await fetchRows(limit + 1, ...);
final hasMore = rows.length > limit;
final entries = hasMore ? rows.sublist(0, limit) : rows;
return EntryPage(entries: entries, hasMore: hasMore);
```

### SQLite / SQL databases

Add a composite index for the sort key:

```sql
CREATE INDEX idx_entries_cursor ON entries (
  channel_id, stream_id,
  hlc_physical, hlc_logical, author, sequence
);
```

Query with a row-value comparison for the cursor:

```sql
-- First page (after is null)
SELECT * FROM entries
WHERE channel_id = ? AND stream_id = ?
ORDER BY hlc_physical, hlc_logical, author, sequence
LIMIT ?;

-- Subsequent pages (after is set)
SELECT * FROM entries
WHERE channel_id = ? AND stream_id = ?
  AND (hlc_physical, hlc_logical, author, sequence) > (?, ?, ?, ?)
ORDER BY hlc_physical, hlc_logical, author, sequence
LIMIT ?;
```

The four cursor bind values come from the last entry of the previous page:

| Bind value      | Source                       |
|-----------------|------------------------------|
| `hlc_physical`  | `after.timestamp.physicalMs` |
| `hlc_logical`   | `after.timestamp.logical`    |
| `author`        | `after.author.value`         |
| `sequence`      | `after.sequence`             |

### Hive

Hive has no server-side query support, so maintain a separate sorted index:

1. Store entries in a primary `Box<LogEntry>` keyed by entry ID.
2. Keep a companion `Box<List<String>>` mapping each `(channel, stream)`
   to a sorted list of entry IDs (sorted by `LogEntry.compareTo`).
3. To paginate, binary-search the index list for the cursor position,
   then read the next `limit` entries from the primary box.
4. Update the sorted index on `append`/`appendAll` using insertion sort.
   Entries typically arrive in near-sorted HLC order, so insertion is
   O(1) amortized for in-order appends.

This keeps memory usage low — only the lightweight ID index is loaded,
and full entry objects are fetched on demand.

### Isar

Isar supports composite indexes and efficient cursor queries natively:

```dart
@Collection()
class EntryModel {
  Id id = Isar.autoIncrement;

  @Index(composite: [
    CompositeIndex('streamId'),
    CompositeIndex('hlcPhysical'),
    CompositeIndex('hlcLogical'),
    CompositeIndex('author'),
    CompositeIndex('sequence'),
  ])
  late String channelId;
  late String streamId;
  late int hlcPhysical;
  late int hlcLogical;
  late String author;
  late int sequence;
  late List<int> payload;
}
```

Query using Isar's filter and sort:

```dart
final query = isar.entryModels
    .where()
    .channelIdStreamIdHlcPhysicalHlcLogicalAuthorSequenceGreaterThan(
      channelId, streamId,
      after.timestamp.physicalMs,
      after.timestamp.logical,
      after.author.value,
      after.sequence,
    )
    .sortByHlcPhysical()
    .thenByHlcLogical()
    .thenByAuthor()
    .thenBySequence()
    .limit(limit + 1)
    .findAll();
```
