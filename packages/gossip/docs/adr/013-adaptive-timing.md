# ADR-013: Adaptive Timing for Transport-Agnostic Stability

## Status

Accepted

## Context

Testing with 6 devices over BLE revealed significant performance issues compared to WiFi:

| Metric | WiFi | BLE |
|--------|------|-----|
| Failed probe count (max) | 4 | 10 |
| Suspected peer occurrences | 0 | 25 |
| "Cannot send" warnings | 7 | 263 |
| Message gaps > 5s | 1 | 8 |
| Reachable peers at session end | 5/5 | 0-3/5 |

The original timing defaults were tuned for WiFi (~10ms latency):

```dart
gossipInterval: 200ms
probeInterval: 1000ms
pingTimeout: 500ms
suspicionThreshold: 3
```

BLE has 100-500ms typical latency with significant jitter. The logs showed message gaps of 5-21 seconds. With a 500ms ping timeout, most pings timeout even when peers are healthy, causing:

1. **False positives**: Healthy peers marked as suspected
2. **Message loss**: 263 "Cannot send" warnings from transport congestion
3. **Poor connectivity**: Devices showing 0-3 reachable peers despite 5 connections

Three options were considered:

1. **Static configuration per transport type**: Provide BLE vs WiFi presets. Simple but requires user to know transport type and doesn't handle mixed networks.

2. **User-configurable timing**: Expose all timing parameters. Configuration is a liability - users shouldn't need SWIM expertise to use the library.

3. **RTT-adaptive timing**: Library measures round-trip time from ping/ack pairs and computes timeouts from observed latency. Self-tuning, works on any transport.

## Decision

Implement RTT-adaptive timing (Option 3). The library automatically adapts to network conditions by:

1. **RTT tracking**: Measure round-trip time from SWIM ping/ack pairs using exponentially weighted moving average (EWMA) for smoothing
2. **Adaptive timeouts**: Compute ping timeout as `RTT + 4 * variance` (covers 99.99% of cases)
3. **Adaptive intervals**: Scale gossip and probe intervals based on observed RTT
4. **Backpressure signaling**: `MessagePort` exposes `pendingSendCount()` so the library can throttle when transport is congested
5. **Priority queues**: SWIM protocol messages (ping/ack) get high priority to prevent RTT measurement noise during gossip congestion

### Timing Configuration Removed

All timing parameters have been removed from `CoordinatorConfig`:

```dart
// Before: 5 timing parameters requiring SWIM expertise
class CoordinatorConfig {
  final Duration gossipInterval;
  final Duration probeInterval;
  final Duration pingTimeout;
  final Duration indirectPingTimeout;
  final int suspicionThreshold;
}

// After: Only policy configuration remains
class CoordinatorConfig {
  final int suspicionThreshold;  // Default: 5
}
```

Users no longer need to understand SWIM timing to use the library correctly.

### Hardcoded Bounds

To prevent extreme values while allowing adaptation:

| Parameter | Minimum | Maximum |
|-----------|---------|---------|
| Ping timeout | 200ms | 10s |
| Probe interval | 500ms | 30s |
| Gossip interval | 100ms | 5s |

### MessagePort Extensions

The `MessagePort` interface was extended for backpressure and priority:

```dart
abstract class MessagePort {
  Future<void> send(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  });

  int pendingSendCount(NodeId peer) => 0;
  int get totalPendingSendCount => 0;
}

enum MessagePriority { high, normal }
```

Default implementations ensure backward compatibility.

## Consequences

### Positive

- Library works on any transport without configuration
- No user expertise required for timing tuning
- Self-healing: adapts to changing network conditions
- Simpler API with fewer configuration options
- Eliminates false positive peer failures on high-latency transports

### Negative

- Breaking change removes timing configuration parameters
- More complex internal implementation
- RTT tracking adds small overhead (negligible)
- Users lose ability to override timing

### Mitigations

- Hardcoded bounds prevent extreme values
- Testing still works via `InMemoryMessagePort` (deterministic)
- `suspicionThreshold` remains configurable for policy decisions

## Alternatives Considered

### Keep User-Configurable Timing

Rejected because:
- Configuration is a liability for most users
- Requires SWIM expertise to set correctly
- Static values can't adapt to changing network conditions
- Different transports need different values

### Transport-Specific Presets

Rejected because:
- Requires user to know transport type at configuration time
- Doesn't handle mixed networks (WiFi + BLE)
- Doesn't adapt to changing conditions within a transport
- Still requires user to make choices they shouldn't need to make

## References

- TCP RTO calculation (RFC 6298): Similar EWMA approach for timeout computation
- SWIM paper: Scalable Weakly-consistent Infection-style Process Group Membership Protocol
