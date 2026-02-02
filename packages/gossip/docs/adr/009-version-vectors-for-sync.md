# ADR-009: Version Vectors for Sync State Tracking

## Status

Accepted

## Context

The anti-entropy protocol (ADR-008) requires peers to determine which entries they're missing. This requires tracking "sync state" - what has been seen from each author.

Options for tracking sync state:

**Sequence numbers**: Single global counter
- Simple but doesn't handle multiple writers

**Lamport timestamps**: Single logical clock
- Tracks causality but not per-author progress

**Version vectors**: Map of author → sequence number
- Tracks per-author progress for efficient delta computation

**Interval tree clocks**: More advanced version vectors
- Handles dynamic actor sets but adds complexity

## Decision

**Use version vectors to track synchronization state per stream.** Each stream maintains a version vector mapping each author (NodeId) to the highest sequence number seen from that author.

```dart
class VersionVector {
  final Map<NodeId, int> _versions;
  
  // Get sequence for an author (0 if not present)
  int operator [](NodeId node) => _versions[node] ?? 0;
  
  // Increment author's sequence
  VersionVector increment(NodeId node);
  
  // Merge two vectors (pairwise max)
  VersionVector merge(VersionVector other);
  
  // Find what other has that we don't
  Map<NodeId, int> diff(VersionVector other);
  
  // Check if we've seen everything in other
  bool dominates(VersionVector other);
}
```

## Rationale

1. **Efficient delta computation**: Given two version vectors, we can immediately determine which entries need to be transferred without scanning the entry log.

2. **Multi-writer support**: Each author has independent sequence numbers. No coordination required between writers.

3. **Compact representation**: A version vector with 8 authors is approximately 80 bytes (8 × (NodeId + int)), compared to potentially megabytes of entries.

4. **Idempotent merge**: `merge(a, b) = merge(b, a)` and `merge(a, merge(b, c)) = merge(merge(a, b), c)`. Order doesn't matter.

5. **Causality detection**: `dominates(other)` tells us if we've seen all events the other peer has seen.

## Consequences

### Positive

- **O(1) staleness check**: Compare two vectors in O(authors) time
- **Precise delta identification**: Know exactly which entries are missing
- **No false positives**: Never request entries we already have
- **Scalable**: Vector size grows with authors, not entries

### Negative

- **Vector growth**: Vectors grow with number of unique authors
- **Storage per stream**: Each stream needs its own version vector
- **No entry pruning info**: Can't determine if entries were compacted (vs. never existed)

### Version Vector Operations

**Increment** (on local write):
```
Before: {A: 5, B: 3}
A writes entry with sequence 6
After:  {A: 6, B: 3}
```

**Merge** (on receiving entries):
```
Local:   {A: 5, B: 3}
Remote:  {A: 4, B: 7, C: 2}
Merged:  {A: 5, B: 7, C: 2}  // pairwise max
```

**Diff** (to find missing entries):
```
Ours:    {A: 5, B: 3}
Theirs:  {A: 7, B: 3, C: 2}
Missing: {A: 5, C: 0}  // We need A's entries 6-7, all of C's
```

**Dominates** (causality check):
```
{A: 5, B: 3}.dominates({A: 4, B: 2}) = true   // We've seen more
{A: 5, B: 3}.dominates({A: 4, B: 7}) = false  // They have B:4-7
```

### Integration with Protocol

**Digest generation** (Step 1-2):
```dart
ChannelDigest generateDigest(ChannelAggregate channel) {
  return ChannelDigest(
    channelId: channel.id,
    streams: channel.streamIds.map((streamId) {
      return StreamDigest(
        streamId: streamId,
        version: entryRepository.getVersionVector(channel.id, streamId),
      );
    }).toList(),
  );
}
```

**Delta computation** (Step 4):
```dart
List<LogEntry> computeDelta(ChannelId channelId, StreamId streamId, VersionVector peerVersion) {
  return entryRepository.entriesSince(channelId, streamId, peerVersion);
  // Returns entries where:
  //   entry.author not in peerVersion, OR
  //   entry.sequence > peerVersion[entry.author]
}
```

### Why Not Just Timestamps?

HLC timestamps (ADR-005) provide ordering, but not sync state:

```
Entry 1: author=A, seq=1, hlc=100
Entry 2: author=B, seq=1, hlc=150
Entry 3: author=A, seq=2, hlc=120  // HLC < 150 but written later by A
```

If we only tracked "highest HLC seen = 150", we'd miss Entry 3.

Version vectors track per-author progress, so we know:
- Seen A up to seq 2
- Seen B up to seq 1

### Scaling Considerations

For the target use case (≤8 peers, ≤8 authors per stream):
- Version vector size: ~80-160 bytes
- Acceptable for digest messages
- Acceptable for per-stream storage

For larger scales, consider:
- **Probabilistic summaries**: Bloom filters for approximate membership
- **Interval tree clocks**: Dynamic actor addition/removal
- **Digest compression**: Run-length encoding for sparse vectors

## Alternatives Considered

### Bloom Filters

Use Bloom filters to approximate set membership:
- Compact fixed-size representation
- But has false positives (request entries we have)
- Tuning filter size is complex

### Merkle DAGs

Track entry hashes in a Merkle structure:
- Can verify integrity
- But doesn't map to author sequences
- More complex to compute deltas

### Log Sequence Numbers

Single global sequence per stream:
- Simpler than version vectors
- But requires coordination for writes
- Single writer bottleneck

### Causal Histories

Track full causal history per entry:
- Complete causality information
- But grows unbounded
- Impractical for long-lived streams
