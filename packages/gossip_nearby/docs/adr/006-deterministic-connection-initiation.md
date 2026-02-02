# ADR-006: Deterministic Connection Initiation via NodeId Comparison

## Status

Accepted

## Context

When two devices discover each other via Nearby Connections, both devices receive a discovery event simultaneously. If both devices attempt to initiate a connection at the same time, this creates a race condition that can result in:

1. **Duplicate connections**: Both connection requests succeed, creating two connections between the same pair of devices
2. **Connection failures**: The platform may reject one or both requests due to the conflict
3. **Resource waste**: Bandwidth and battery consumed by redundant connection attempts
4. **Unpredictable behavior**: Different outcomes depending on timing and platform implementation

The Nearby Connections API doesn't provide built-in coordination for this scenario.

## Decision

**Use lexicographic comparison of NodeIds to deterministically decide which device initiates the connection.**

When a device discovers another endpoint:
- Parse the remote NodeId from the advertised name (format: `nodeId|displayName`)
- Compare local NodeId with remote NodeId lexicographically
- Only the device with the smaller NodeId initiates the connection
- The other device waits for the incoming connection request

```dart
bool _shouldInitiateConnection(String advertisedName) {
  final remoteNodeId = _parseNodeId(advertisedName);
  if (remoteNodeId == null) {
    return true; // Fall back to initiating if parsing fails
  }
  return _localNodeId.value.compareTo(remoteNodeId) < 0;
}
```

The NodeId is encoded in the advertised service name to make it available at discovery time, before any connection is established.

## Rationale

1. **Deterministic**: Given two NodeIds, the outcome is always the same regardless of timing or which device discovers first.

2. **No coordination required**: Each device can independently compute the same decision without exchanging messages.

3. **Symmetric**: Both devices use the same algorithm, guaranteeing exactly one will initiate.

4. **Leverages existing identity**: NodeId is already a UUID that uniquely identifies each device in the gossip network.

5. **Available at discovery**: By encoding NodeId in the advertised name, the decision can be made immediately upon discovery without waiting for connection establishment.

## Consequences

### Positive

- Eliminates race conditions in connection establishment
- Exactly one connection attempt per device pair
- No wasted resources from duplicate connection attempts
- Predictable, debuggable behavior
- Works without any protocol-level coordination

### Negative

- Advertised name must include NodeId, limiting space for display name
- If NodeId parsing fails, falls back to always initiating (could cause races with legacy devices)
- Slightly asymmetric load: devices with "smaller" NodeIds do more initiating

### Advertised Name Format

The advertised name format is: `{nodeId}|{displayName}`

Example: `a1b2c3d4-e5f6-7890-abcd-ef1234567890|Alice's Phone`

This limits display name length but ensures the NodeId is always available for comparison.

## Alternatives Considered

### Random Backoff

Each device waits a random delay before initiating:
- Simple to implement
- But still has collision probability
- Adds latency to connection establishment
- Non-deterministic behavior makes debugging harder

### First-Discoverer Initiates

The device that discovers first initiates:
- Intuitive approach
- But discovery timing is non-deterministic
- Both may discover "first" from their perspective
- Doesn't solve the fundamental race condition

### Central Coordinator

A designated device coordinates all connections:
- Eliminates races completely
- But requires electing a coordinator
- Single point of failure
- Adds complexity and latency
- Doesn't fit P2P architecture

### Platform-Level Deduplication

Rely on Nearby Connections to handle duplicates:
- Simplest from our perspective
- But behavior varies across platforms
- May result in failed connections
- Less control over the outcome
