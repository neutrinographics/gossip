# ADR-004: SWIM Protocol for Failure Detection

## Status

Accepted

## Context

In a distributed system, nodes need to detect when peers become unreachable. This is essential for:
- Avoiding wasted sync attempts to dead nodes
- Maintaining accurate peer status for the application
- Efficient gossip peer selection

Common failure detection approaches:
1. **Heartbeat**: Periodic "I'm alive" messages from each peer
2. **Ping-Pong**: Direct probes to each peer
3. **SWIM**: Scalable Weakly-consistent Infection-style Membership protocol
4. **Phi Accrual**: Adaptive failure detection based on heartbeat history

The library targets small networks (up to 8 devices) with potentially unreliable connections (mobile, P2P).

## Decision

**Use the SWIM protocol for failure detection.** SWIM combines direct probes with indirect probes through other peers to reduce false positives.

```
Direct Probe:
  A ──ping──> B
  A <──ack─── B

Indirect Probe (when direct fails):
  A ──ping-req──> C ──ping──> B
  A <──────ack─────── C <──ack─── B
```

## Rationale

1. **Reduces false positives**: Indirect probes catch transient network issues
2. **Scalable**: O(1) message overhead per node per protocol period
3. **Battle-tested**: Used in production systems (HashiCorp Serf, Consul)
4. **Configurable**: Suspicion threshold tunable for different environments
5. **Simple state machine**: reachable → suspected → unreachable

## Protocol Details

### States

- **Reachable**: Peer responds to probes
- **Suspected**: Direct probe failed, indirect probe in progress
- **Unreachable**: Confirmed failed after threshold exceeded

### Configuration

```dart
CoordinatorConfig(
  probeInterval: Duration(milliseconds: 1000),    // How often to probe
  pingTimeout: Duration(milliseconds: 500),        // Direct probe timeout
  indirectPingTimeout: Duration(milliseconds: 500), // Indirect probe timeout
  suspicionThreshold: 3,                           // Failures before unreachable
)
```

### Incarnation Numbers

Each node maintains an incarnation number that increments when refuting false suspicions. This prevents stale failure information from propagating.

## Consequences

### Positive

- Fast detection of actual failures (~2-3 seconds)
- Low false positive rate with indirect probes
- Works well with unreliable mobile networks
- Minimal bandwidth overhead

### Negative

- More complex than simple heartbeats
- Requires peers to relay ping-req messages
- Small delay before declaring node unreachable

### Integration

- FailureDetector runs alongside GossipEngine
- Shares MessagePort for network communication
- Updates PeerRegistry with status changes
- Emits PeerStatusChanged events

## Alternatives Considered

### Simple Heartbeat

Each peer broadcasts "I'm alive" periodically:
- Simpler to implement
- But O(n) messages per period
- Higher false positive rate
- Doesn't scale well

### Phi Accrual Detector

Adaptive threshold based on heartbeat history:
- More accurate for stable networks
- But complex to tune
- Assumes regular heartbeats
- Overkill for small networks

### No Failure Detection

Let gossip timeout handle failures:
- Simplest option
- But wastes bandwidth on dead peers
- No status visibility for application
- Slow to detect failures
