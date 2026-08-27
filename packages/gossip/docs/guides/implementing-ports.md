# Implementing Ports and Repositories

This guide covers the interfaces consumers must implement for production
use of the gossip library. It highlights performance constraints, ordering
invariants, and non-obvious gotchas that aren't captured by the type
signatures alone.

## How the gossip round works (context)

Every 200-500ms the gossip engine runs a round:

1. Select a random reachable peer (filtered by backpressure)
2. Generate a **digest** for each channel (calls `getVersionVector()` per stream)
3. Send digest to peer
4. Peer computes **delta** (calls `entriesSince()` per stream)
5. Peer sends delta entries back
6. Receiver calls `getTailTimestamp()`, then `appendAll()`, then detects
   out-of-order entries

Methods called during this loop are on the **hot path** and must be fast.

---

## EntryRepository

The most performance-sensitive interface. Three methods are on the gossip
hot path.

### Hot path methods

**`getVersionVector(channel, stream)`** — Called once per stream per
gossip round to generate digests. Must be O(1). Do not compute by
iterating all entries; cache the vector and update it incrementally
in `append()`/`appendAll()`. The in-memory implementation maintains
a `Map<NodeId, int>` cache per stream.

**`entriesSince(channel, stream, versionVector)`** — Called to compute
deltas for a peer. For each author, returns entries where
`sequence > versionVector[author]`. Index on `(channel, stream, author,
sequence)` so this is a range scan, not a full table scan.

**`getTailTimestamp(channel, stream)`** — Called before every
`appendAll()` to snapshot the current tail HLC. Used to detect
out-of-order entry insertion (which triggers a full materializer
rebuild). Must be O(1); return the last entry's timestamp from a
cached value or sorted index.

### Ordering invariants

- `getAll()` **must** return entries sorted by HLC timestamp
- `entriesSince()` **must** return entries sorted by HLC timestamp

Violating these causes silent data corruption in materializers that
depend on fold order.

### Atomicity

`appendAll()` must be atomic. If any entry fails validation, none
should be persisted. Use a database transaction.

### Recommended indexes (SQL)

```sql
-- Primary lookups and entriesSince()
CREATE INDEX idx_entries_author ON entries (
  channel_id, stream_id, author, sequence
);

-- getAll() and timestamp ordering
CREATE INDEX idx_entries_timestamp ON entries (
  channel_id, stream_id, hlc_physical, hlc_logical
);
```

---

## ChannelRepository

Stores channel aggregates (membership, stream metadata).

### Object identity requirement

The gossip engine mutates channel aggregates in-place during rounds.
If your repository deserializes from storage, each `findById()` call
returns a new object — breaking in-place mutation.

You do **not** need to solve this yourself. `Coordinator.create()`
automatically wraps your repository in a `CachingChannelRepository`
that maintains an identity map. Just implement straightforward
load/save/delete semantics.

### Performance

`findById()` is called during gossip rounds (once per channel), but
since it's behind the caching layer, your backing implementation is
only hit on cache misses (startup, first access).

---

## PeerRepository

Stores peer state (health, metrics, incarnation numbers).

### Write volume

`save()` is called after **every protocol message** sent or received,
because each message updates peer metrics (RTT, throughput, timestamps).
In an active 5-peer network this can mean 50+ saves per second.

Consider:
- Batching or debouncing writes (peer state is eventually consistent;
  stale reads are acceptable)
- Writing only changed fields instead of full object replacement
- Using an in-memory buffer with periodic flush

---

## LocalNodeRepository

Stores the node's identity and clock state. All methods are
initialization-time except `saveClockState()`.

### generateNodeId() must be globally unique

This is the single most important contract. `generateNodeId()` is
called when `getNodeId()` returns null (first launch or after storage
wipe). It **must** return a new unique ID every time.

```dart
// WRONG - same ID after storage wipe
Future<NodeId> generateNodeId() async {
  return NodeId('device-${await getDeviceId()}');
}

// CORRECT - unique on every call
Future<NodeId> generateNodeId() async {
  return NodeId(const Uuid().v4());
}
```

If a wiped device reuses its old NodeId, peers will assume it still
has its old entries, skip sending them, and synchronization silently
breaks.

If you need to map NodeIds to stable external identities (user accounts,
device IDs), maintain a separate mapping table outside the repository.

### saveClockState() is fire-and-forget

During gossip merges, `saveClockState()` is called **without await**
for performance. Your implementation must tolerate being called
frequently without blocking. On the local-append path
(`ChannelService.appendEntry`) it is awaited, so durability is
guaranteed for locally authored entries.

---

## MessagePort

Transport abstraction for sending/receiving protocol messages.

### Best-effort delivery

The library handles reliability itself via version vectors and SWIM
protocol. Your transport should **not** retry failed sends. Just
deliver once and move on. Lost messages are detected and recovered
at the protocol layer.

### Backpressure

The gossip engine checks `pendingSendCount(peerId)` before each round
and skips congested peers (threshold: 3 pending messages). If all peers
are congested, the round is skipped entirely. Override
`pendingSendCount()` if your transport can report queue depth;
otherwise the default (0) disables backpressure.

### Priority

`send()` receives a `MessagePriority` parameter. SWIM health-check
messages use `high` priority; gossip data uses `normal`. If your
transport supports priority queuing, process high-priority messages
first to keep failure detection responsive.

### Performance

- `send()` should queue asynchronously and return in < 1ms
- Must support payloads up to 32KB (Android Nearby Connections limit)
- Must not throw on network errors; log them internally

---

## TimePort

Clock and timer abstraction. Used for gossip scheduling, RTT
measurement, and metrics windows.

### nowMs must be O(1)

The `nowMs` getter is called for **every received message** to record
metrics. It must return milliseconds since epoch with no allocation
or expensive syscalls. `DateTime.now().millisecondsSinceEpoch` is
fine on most platforms.

### Testing

Use `InMemoryTimePort` for deterministic tests. It supports manual
time advancement:

```dart
final timePort = InMemoryTimePort();
await timePort.advance(Duration(seconds: 1));
```

Production should use the provided `RealTimePort()`.

---

## StateMaterializer

Folds log entries into application-defined state.

### fold() is on the hot path

`fold()` is called for every entry during:
- Initialization (all historical entries on first access)
- Incremental updates (new entries after each gossip merge)
- Full rebuilds (when out-of-order entries are detected)

Keep it O(1). Do not allocate collections, make network calls, or
perform I/O inside `fold()`.

### Out-of-order entry rebuilds

When merged entries have timestamps older than the stream's current
tail, the library detects this and triggers a full rebuild: it calls
`initial(isReset: true)`, ignores any cached cursor, and re-folds
all entries from the beginning. Your materializer must handle this
gracefully.

This happens when peers sync entries that were created offline and
have older HLC timestamps than entries already in the stream.

### Cursor contract

The `String?` cursor returned from `initial()` and passed to `save()`
is opaque to the library. Use it to track which entries have already
been folded so you can resume incrementally after restart instead of
replaying the entire log.

---

## RetentionPolicy

Compaction strategy for pruning old entries.

The library **never calls** `compact()` automatically. Applications
must invoke it on their own schedule (e.g., periodic background task)
and call `removeEntries()` with the pruned entry IDs.

Built-in policies: `KeepAllRetention`, `TimeBasedRetention`,
`CountBasedRetention`, `CompositeRetention`.

Custom implementations must:
- Return a subset of the input (no new entries)
- Preserve timestamp ordering
- Be deterministic (same inputs produce same output)
