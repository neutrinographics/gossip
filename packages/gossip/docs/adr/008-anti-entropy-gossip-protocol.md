# ADR-008: Anti-Entropy Gossip Protocol

## Status

Accepted

## Context

The library needs to synchronize event streams across multiple peers in a distributed system. Key requirements:

1. **Eventual consistency**: All peers should converge to the same state
2. **Efficient bandwidth**: Minimize data transfer, especially for large streams
3. **Resilience**: Handle message loss, peer failures, network partitions
4. **Scalability**: Work with varying peer counts (1-8 devices typical)

Common approaches to distributed sync:

**Full state transfer**: Send complete state on every sync
- Simple but inefficient for large datasets

**Operation-based CRDT**: Broadcast every operation
- Efficient for small ops but unreliable delivery causes issues

**Anti-entropy**: Periodically compare summaries and exchange deltas
- Efficient and resilient to message loss

## Decision

**Use a 4-step anti-entropy gossip protocol with digest-based sync.** Peers periodically exchange compact digests (version vectors) and only transfer entries the other peer is missing.

### Protocol Steps

```
Step 1: Digest Request (initiator → peer)
┌─────────────────────────────────────────────┐
│ DigestRequest                               │
│   sender: NodeId                            │
│   digests: [ChannelDigest...]               │
│     └─ channelId + [StreamDigest...]        │
│          └─ streamId + VersionVector        │
└─────────────────────────────────────────────┘

Step 2: Digest Response (peer → initiator)
┌─────────────────────────────────────────────┐
│ DigestResponse                              │
│   sender: NodeId                            │
│   digests: [ChannelDigest...]               │
└─────────────────────────────────────────────┘

Step 3: Delta Request (initiator → peer)
┌─────────────────────────────────────────────┐
│ DeltaRequest                                │
│   sender: NodeId                            │
│   channelId: ChannelId                      │
│   streamId: StreamId                        │
│   since: VersionVector                      │
└─────────────────────────────────────────────┘

Step 4: Delta Response (peer → initiator)
┌─────────────────────────────────────────────┐
│ DeltaResponse                               │
│   sender: NodeId                            │
│   channelId: ChannelId                      │
│   streamId: StreamId                        │
│   entries: [LogEntry...]                    │
└─────────────────────────────────────────────┘
```

### Gossip Round Timing

- **Gossip interval**: 200ms (configurable)
- **Peer selection**: Random reachable peer each round
- **Bidirectional**: Each round can sync in both directions

## Rationale

1. **Digest efficiency**: Version vectors are compact (tens of bytes) compared to full entry sets (potentially megabytes). Only deltas are transferred.

2. **Idempotent operations**: Receiving the same entry multiple times has no effect. This makes the protocol resilient to retransmission and duplicate delivery.

3. **Probabilistic convergence**: Random peer selection ensures all pairs eventually sync. Expected convergence time is O(log n) rounds.

4. **Resilience to loss**: If any message is lost, the next gossip round will retry. No complex acknowledgment or retry logic needed.

5. **No central coordinator**: All peers are equal. No leader election, no single point of failure.

## Consequences

### Positive

- **Sub-second convergence**: Typically 150ms for small networks (< 8 peers)
- **Bandwidth efficient**: Only missing entries are transferred
- **Resilient**: Handles message loss, peer failures gracefully
- **Simple**: No complex coordination or consensus protocols
- **Scalable**: Works for any peer count (linear message complexity per round)

### Negative

- **Probabilistic**: No guaranteed sync time (only probabilistic bounds)
- **Periodic overhead**: Gossip rounds run even when nothing changes
- **No ordering guarantee**: Entries may arrive out of timestamp order
- **Digest overhead**: Digests grow with number of authors per stream

### Message Flow Example

```
Node A                              Node B
   │                                   │
   │──── DigestRequest ───────────────>│  Step 1
   │     {channels: [{ch1, streams}]}  │
   │                                   │
   │<─── DigestResponse ──────────────│  Step 2
   │     {channels: [{ch1, streams}]}  │
   │                                   │
   │──── DeltaRequest ────────────────>│  Step 3
   │     {ch1, stream1, since: VV}     │
   │                                   │
   │<─── DeltaResponse ───────────────│  Step 4
   │     {ch1, stream1, entries: [...]}│
   │                                   │
```

### Why 4 Steps Instead of 2?

A simpler protocol might just exchange entries directly:

```
// Simpler but wasteful
Node A: "Here are my entries: [...]"
Node B: "Here are my entries: [...]"
```

Problems with 2-step:
- Sends ALL entries, not just missing ones
- Bandwidth grows with data size, not delta size
- Inefficient for long-lived channels

The 4-step protocol ensures:
- Only metadata (digests) sent initially
- Only missing entries (deltas) sent subsequently
- Bandwidth proportional to staleness, not total size

## Alternatives Considered

### Merkle Tree Sync

Use Merkle trees to identify differences:
- More efficient for very large datasets
- But adds complexity (tree maintenance)
- Overkill for target scale (< 8 peers, < 10K entries)

### Push-Based Replication

Push entries immediately on write:
- Lower latency for new entries
- But requires reliable delivery
- Complex retry and ordering logic

### Gossip-on-Write

Only gossip when new entries exist:
- Eliminates idle gossip overhead
- But adds state tracking complexity
- May miss sync opportunities after failures

### Vector Clock Comparison Only

Skip delta exchange, just compare clocks:
- Simpler protocol
- But requires separate entry fetch mechanism
- Loses the batching benefits of delta responses
