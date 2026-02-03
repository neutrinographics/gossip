# ADR-012: Adaptive Timing for Transport-Agnostic Stability

## Status

Proposed

## Context

Testing with 6 devices over BLE revealed significant performance issues compared to WiFi:

| Metric | WiFi | BLE |
|--------|------|-----|
| Failed probe count (max) | 4 | 10 |
| Suspected peer occurrences | 0 | 25 |
| "Cannot send" warnings | 7 | 263 |
| Message gaps > 5s | 1 | 8 |
| Reachable peers at session end | 5/5 | 0-3/5 |

### Root Cause Analysis

The current timing defaults are tuned for WiFi (~10ms latency):

```dart
gossipInterval: 200ms      // 5 rounds/sec
probeInterval: 1000ms      // 1 probe/sec
pingTimeout: 500ms         // Direct ping timeout
indirectPingTimeout: 500ms // Indirect ping timeout
suspicionThreshold: 3      // Failures before suspected
```

BLE has 100-500ms typical latency with significant jitter. The logs showed message gaps of 5-21 seconds. With a 500ms ping timeout, most pings timeout even when peers are healthy, causing:

1. **False positives**: Healthy peers marked as suspected
2. **Message loss**: 263 "Cannot send" warnings from race conditions
3. **Poor connectivity**: Devices showing 0-3 reachable peers despite 5 connections

### Design Considerations

**Option A: Static configuration per transport type**
- Provide BLE vs WiFi presets
- Simple but requires user to know transport type
- Doesn't handle mixed networks or changing conditions

**Option B: User-configurable timing**
- Current approach - expose all timing parameters
- Configuration is a liability - users shouldn't need SWIM expertise
- Easy to misconfigure

**Option C: RTT-adaptive timing**
- Library measures round-trip time from ping/ack pairs
- Timeouts computed from observed latency
- Self-tuning, works on any transport
- No user configuration needed

## Decision

Implement RTT-adaptive timing (Option C) with a phased approach:

1. **Phase 0**: Validate hypothesis with manual BLE-friendly defaults
2. **Phases 1-3**: Implement RTT tracking and adaptive timeouts
3. **Phase 4**: Add backpressure signaling for congestion control
4. **Phase 5**: Optional priority queues for SWIM messages
5. **Phase 6**: Remove timing configuration, simplify API

### Key Design Decisions

1. **No timing configuration exposed** - RTT adaptation handles it automatically
2. **Hardcoded bounds** - Prevent extreme values (min 200ms, max 10s for timeouts)
3. **Conservative initial values** - Start with 1 second timeout before RTT data available
4. **EWMA smoothing** - Exponentially weighted moving average prevents oscillation
5. **Suspicion threshold remains configurable** - It's policy, not timing

## Migration Plan

### Phase 0: Manual BLE Timing Validation

**Goal**: Confirm that adjusted timing fixes BLE performance issues before investing in RTT adaptation.

**Changes to `CoordinatorConfig` defaults**:

```dart
// Current defaults (WiFi-tuned)
gossipInterval: 200ms
probeInterval: 1000ms
pingTimeout: 500ms
indirectPingTimeout: 500ms
suspicionThreshold: 3

// New defaults (BLE-friendly)
gossipInterval: 500ms        // 2.5x slower - reduce message volume
probeInterval: 3000ms        // 3x slower - give time between probes
pingTimeout: 2000ms          // 4x longer - BLE needs more time
indirectPingTimeout: 2000ms  // 4x longer
suspicionThreshold: 5        // More forgiving - BLE is flaky
```

**Success criteria**:
- Failed probe counts stay below suspicion threshold
- Peers remain reachable during normal operation
- Significantly fewer "Cannot send" warnings

**Estimated effort**: 30 minutes

---

### Phase 1: RTT Tracking Infrastructure

**Goal**: Measure round-trip time from SWIM ping/ack pairs.

**New class `RttTracker`** (`packages/gossip/lib/src/protocol/rtt_tracker.dart`):
- Exponentially weighted moving average (EWMA) for smoothed RTT
- RTT variance tracking for timeout margin calculation
- Hardcoded bounds: min 50ms, max 30 seconds
- Initial value: 1 second (safe for both WiFi and BLE)

**Modify `FailureDetector`**:
- Inject `RttTracker` instance
- On sending Ping: record `(sequence, timestamp)`
- On receiving Ack: compute RTT, feed to tracker

**Files modified**:
- `protocol/rtt_tracker.dart` (new)
- `protocol/failure_detector.dart`
- `domain/aggregates/peer_registry.dart` (optional: per-peer RTT)

**Estimated effort**: 2 days

---

### Phase 2: RTT-Adaptive SWIM Timeouts

**Goal**: Replace fixed ping timeouts with RTT-derived values.

**Modify `FailureDetector`**:
```dart
Duration get _effectivePingTimeout {
  final rtt = _rttTracker.smoothedRtt;
  final variance = _rttTracker.rttVariance;
  // Timeout = RTT + 4 standard deviations (covers 99.99% of cases)
  final computed = rtt + (variance * 4);
  return computed.clamp(_minTimeout, _maxTimeout);
}
```

**Hardcoded bounds** (not configurable):
- `_minTimeout`: 200ms (network physics floor)
- `_maxTimeout`: 10 seconds (reasonable upper limit)
- `_minProbeInterval`: 500ms
- `_maxProbeInterval`: 30 seconds

**Remove from `CoordinatorConfig`**:
- `pingTimeout`
- `indirectPingTimeout`
- `probeInterval`

**Breaking change**: Yes - apps using custom timeouts will get compile errors.

**Migration**: Delete the parameters (adaptive is better).

**Estimated effort**: 2 days

---

### Phase 3: RTT-Adaptive Gossip Interval

**Goal**: Gossip at a rate the network can sustain.

**Modify `GossipEngine`**:
```dart
Duration get _effectiveGossipInterval {
  // Gossip interval = 2x RTT (time for request + response)
  final computed = _rttTracker.smoothedRtt * 2;
  return computed.clamp(_minInterval, _maxInterval);
}
```

**Hardcoded bounds**:
- `_minInterval`: 100ms (prevent CPU spin)
- `_maxInterval`: 5 seconds (ensure progress)

**Remove from `CoordinatorConfig`**:
- `gossipInterval`

**Estimated effort**: 1-2 days

---

### Phase 4: Backpressure Signaling

**Goal**: Prevent unbounded message queuing; let library throttle when transport is congested.

**Extend `MessagePort` interface**:
```dart
abstract class MessagePort {
  Future<void> send(NodeId destination, Uint8List bytes);
  Stream<IncomingMessage> get incoming;
  Future<void> close();

  // NEW: number of messages waiting to be sent to this peer
  int pendingSendCount(NodeId peer) => 0;  // Default: unknown

  // NEW: total pending across all peers
  int get totalPendingSendCount => 0;  // Default: unknown
}
```

**Modify `GossipEngine`**:
```dart
Future<void> performGossipRound() async {
  // Skip round if transport is congested
  if (messagePort.totalPendingSendCount > _congestionThreshold) {
    return;
  }
  // ... normal gossip
}
```

**Implement in `NearbyMessagePort`**:
- Track pending sends per peer
- Increment on send, decrement on completion/failure

**Breaking change**: No - new methods have default implementations.

**Estimated effort**: 3 days

---

### Phase 5: Priority Queues (Optional)

**Goal**: Ensure SWIM messages aren't delayed behind gossip during congestion.

**Extend `MessagePort.send()`**:
```dart
Future<void> send(
  NodeId destination,
  Uint8List bytes, {
  MessagePriority priority = MessagePriority.normal,
});

enum MessagePriority { high, normal }
```

**Implement in `NearbyMessagePort`**:
- Two queues: high priority, normal priority
- Process high queue completely before normal queue

**Modify `FailureDetector`**:
- Send pings/acks with `priority: MessagePriority.high`

**Breaking change**: No - priority parameter has default value.

**Estimated effort**: 2 days

---

### Phase 6: Cleanup & Documentation

**Goal**: Finalize API, update docs, release.

**Simplified `CoordinatorConfig`**:
```dart
class CoordinatorConfig {
  /// Number of consecutive probe failures before marking peer as suspected.
  /// Default: 3
  final int suspicionThreshold;

  const CoordinatorConfig({
    this.suspicionThreshold = 3,
  });
}
```

**Migration guide**:
```markdown
## Migrating to v2.0

### Removed: Timing configuration

The following `CoordinatorConfig` parameters have been removed:
- `gossipInterval`
- `probeInterval`
- `pingTimeout`
- `indirectPingTimeout`

The library now automatically adapts timing based on observed
network latency. Simply remove these parameters from your config.
```

**Estimated effort**: 1 day

---

## Summary

| Phase | Description | Breaking | Effort | Cumulative |
|-------|-------------|----------|--------|------------|
| 0 | Manual BLE timing validation | No | 30 min | 30 min |
| 1 | RTT tracking infrastructure | No | 2 days | 2.5 days |
| 2 | RTT-adaptive SWIM timeouts | Yes | 2 days | 4.5 days |
| 3 | RTT-adaptive gossip interval | Yes | 1-2 days | 6 days |
| 4 | Backpressure signaling | No | 3 days | 9 days |
| 5 | Priority queues (optional) | No | 2 days | 11 days |
| 6 | Cleanup & documentation | No | 1 day | 12 days |

**Phases 0-3** are the core fix. After Phase 3, the library self-tunes to any transport.

**Phase 4** prevents runaway queuing under sustained congestion.

**Phase 5** is optional polish - only needed if Phase 4 testing reveals RTT measurement noise under load.

## Rollout Strategy

1. **Phase 0**: Validate on feature branch, test with devices
2. **Phases 1-3**: Single PR with breaking changes, tagged as v2.0.0-beta.1
3. **Phase 4**: Separate PR, non-breaking
4. **Phase 5**: Separate PR if needed, non-breaking
5. **Phase 6**: Final PR, tag v2.0.0

## Consequences

### Positive

- Library works on any transport without configuration
- No user expertise required for timing tuning
- Self-healing: adapts to changing network conditions
- Simpler API with fewer configuration options
- Eliminates false positive peer failures on high-latency transports

### Negative

- Breaking change removes timing configuration (Phase 2-3)
- More complex internal implementation
- RTT tracking adds small overhead (negligible)
- Users lose ability to override timing (mitigated by hardcoded bounds)

### Neutral

- `suspicionThreshold` remains configurable (policy, not timing)
- Testing still works via `InMemoryTimePort` (deterministic)

## References

- BLE test logs (2026-02-03): 6 devices, 263 "Cannot send" warnings, 10 max failed probes
- WiFi test logs (2026-02-03): 6 devices, 7 warnings, 4 max failed probes
- TCP RTO calculation (RFC 6298): Similar EWMA approach for timeout computation
- SWIM paper: Scalable Weakly-consistent Infection-style Process Group Membership
