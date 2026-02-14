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

- **Reachable**: Peer responds to probes normally
- **Suspected**: After `suspicionThreshold` (default 5) consecutive probe failures.
  Peer is still probed and can recover by responding.
- **Unreachable**: After `unreachableThreshold` (default 15) consecutive probe failures.
  Excluded from regular probing and gossip. Periodically probed every
  `unreachableProbeInterval` (default 5) rounds for recovery.

### Configuration

```dart
CoordinatorConfig(
  suspicionThreshold: 5,       // Failed probes before suspected (default: 5)
  unreachableThreshold: 15,    // Failed probes before unreachable (default: 15)
  unreachableProbeInterval: 5, // Probe unreachable peers every N rounds (default: 5)
  startupGracePeriod: Duration(seconds: 10), // Grace period for new peers
)
```

Timing parameters (ping timeout, probe interval, gossip interval) are
RTT-adaptive and not directly configurable — see ADR-013.

### Incarnation Numbers

Each node maintains an incarnation number that increments when refuting false suspicions. This prevents stale failure information from propagating.

### Tuning Guide

All parameters are set via `CoordinatorConfig` and passed to `Coordinator.create()`.
Timing values (ping timeout, probe interval) are RTT-adaptive and not directly
configurable — only the policy thresholds below are tunable.

| Parameter | Default | Effect of raising | Effect of lowering |
|-----------|---------|-------------------|--------------------|
| `suspicionThreshold` | 5 | Slower to suspect, fewer false positives | Faster detection, more false positives on flaky networks |
| `unreachableThreshold` | 15 | Longer recovery window for suspected peers | Faster eviction, less chance to recover |
| `unreachableProbeInterval` | 5 | Less overhead probing dead peers, slower deadlock recovery | Faster deadlock recovery, negligible extra bandwidth (~66 bytes/probe) |
| `startupGracePeriod` | 10s | More time for transport to stabilize | Faster initial failure detection |

#### Failure detection timeline (defaults, ~1.5s probe interval)

1. **0–7.5s**: First 5 probes fail → peer becomes **suspected**
2. **7.5–22.5s**: 10 more probes fail → peer becomes **unreachable**
3. **Every ~7.5s thereafter**: One unreachable probe fires. If the peer responds
   (directly or via an intermediary), it recovers to **reachable** immediately.

#### Recovery paths

- **Suspected → Reachable**: Peer responds to any regular probe
- **Unreachable → Reachable**: Three ways:
  1. Periodic unreachable probe gets a response (direct or indirect via intermediary)
  2. Peer sends an incoming Ping (handled by `_handleIncomingPing`)
  3. Transport reconnection triggers `addPeer()` (e.g., BLE reconnect)

#### Bandwidth cost of unreachable probing

A SWIM Ping is ~66 bytes. At `unreachableProbeInterval: 5` with ~1.5s probe
intervals, that's one 66-byte message every ~7.5s per unreachable peer — roughly
9 bytes/second, or 0.06% of typical gossip traffic. Lowering the interval to 1
(probe every round) costs ~44 bytes/second, still negligible.

## Consequences

### Positive

- Fast detection of actual failures (~7.5s to suspected, ~22.5s to unreachable)
- Low false positive rate with indirect probes and two-tier thresholds
- Works well with unreliable mobile networks
- Automatic recovery from mutual-unreachable deadlocks via periodic probing
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
