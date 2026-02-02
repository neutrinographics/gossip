# ADR-002: Separate Entry Storage from Aggregates

## Status

Accepted

## Context

In Domain-Driven Design, aggregates typically contain all their data. For a Channel aggregate, this would mean storing all log entries in memory as part of the aggregate.

However, event streams can grow large:
- A chat channel might have thousands of messages
- A document might have thousands of edit operations
- Sync history accumulates over time

Storing all entries in the aggregate would:
- Consume excessive memory
- Make aggregate loading slow
- Limit scalability

## Decision

**Log entries are stored separately from aggregates via the EntryRepository interface.** The Channel aggregate maintains only metadata (stream IDs, version vectors, member lists), not the entries themselves.

```
┌─────────────────────┐     ┌─────────────────────┐
│  ChannelAggregate   │     │   EntryRepository   │
├─────────────────────┤     ├─────────────────────┤
│  - id               │     │  - entries by       │
│  - memberIds        │     │    (channel,stream) │
│  - streamIds        │     │  - indexed by       │
│  - versionVectors   │     │    author+sequence  │
└─────────────────────┘     └─────────────────────┘
        Metadata                   Data
      (always in memory)      (loaded on demand)
```

## Rationale

1. **Memory efficiency**: Only load entries when needed
2. **Fast aggregate loading**: Channel metadata is small and quick to load
3. **Scalability**: Supports streams with millions of entries
4. **Flexibility**: Different storage backends for metadata vs entries
5. **Pagination**: EntryRepository can implement pagination for large streams

## Consequences

### Positive

- Channels load instantly regardless of entry count
- Memory usage stays bounded
- Can use optimized storage for entries (SQLite, IndexedDB)
- Entries can be compacted/archived independently

### Negative

- Two repositories to implement instead of one
- Consistency between aggregate and entries must be managed
- Slightly more complex mental model

### Implementation Notes

- `ChannelRepository` stores aggregate metadata
- `EntryRepository` stores log entries
- Both are injected into Coordinator
- In-memory implementations provided for testing
- Applications implement persistent versions for production

## Alternatives Considered

### Entries in Aggregate

Store entries directly in Channel aggregate:
- Simpler model
- But doesn't scale beyond ~1000 entries
- Memory pressure on mobile devices

### Lazy Loading in Aggregate

Load entries on demand within aggregate:
- Keeps DDD purity
- But complicates aggregate interface
- Async methods in aggregate feel wrong

### Event Sourcing

Store only events, rebuild aggregate state:
- More pure event sourcing
- But we need entries for sync protocol
- Adds complexity without benefit
