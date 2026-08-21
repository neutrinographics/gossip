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

### Timing Configuration Made Optional

Timing parameters are no longer *required*. They default to `null`, which
engages adaptive timing, but remain available as explicit overrides for
tests or unusual transports:

```dart
class CoordinatorConfig {
  // Adaptive by default (null); set only to override:
  final Duration? gossipInterval;
  final Duration? probeInterval;
  final Duration? pingTimeout;
  final bool adaptiveTimingEnabled;   // default: true

  // Policy configuration:
  final int suspicionThreshold;       // default: 5
  final int unreachableThreshold;     // default: 15
  // ... startupGracePeriod, maxDeltaResponseBytes, compactionInterval, etc.
}
```

Users no longer *need* to understand SWIM timing to use the library correctly,
but the knobs are still there when needed. Each knob gates independently: a
static `pingTimeout` or `probeInterval` overrides only that value — the others
stay adaptive.

### Hardcoded Bounds

To prevent extreme values while allowing adaptation:

| Parameter | Minimum | Maximum |
|-----------|---------|---------|
| Ping timeout | 500ms | 10s |
| Probe interval | 500ms | 30s |
| Gossip interval | 100ms | 5s |

(Ping-timeout minimum is 500ms — not 200ms — because BLE links routinely sit
at 100–500ms RTT, and a sub-500ms floor false-positives healthy peers.)

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

## Amendment (2026-08-20): Two-Tier Pacing

The original design adapted both intervals to LATENCY only, so a
healthier link produced more idle traffic and a converged network never
went quiet (audit WIRE4-2/4). Both loops now feed a pure
`QuiescencePacer` (domain service): rounds that carry no news stretch
the latency-derived base interval by 1.5x per quiet round toward a 30 s
ceiling; any news (local append, merge, delta traffic, membership
change, missed probe) snaps it back to base. Owner decisions: 30 s
ceiling, not configurable; time-based suppression only (no cached-VV
skipping); minutes-scale detection of half-open links in a deep-idle
mesh is accepted — hard disconnects surface via the transport instantly.
Static `gossipInterval`/`probeInterval` overrides bypass the pacer.

The worst-case repair bound for a lost push is **30 s + scheduling
jitter (±20%)**, not a flat 30 s: every scheduled round (gossip and
probe alike) is jittered before it fires (see `applyJitter`), so the
ceiling itself can take up to ~36 s to elapse in the worst case.

### Final-review refinements (2026-08-21)

Three deliberate refinements found during final review, kept because
they are the more correct behavior (not bugs to fix toward the
original wording above):

1. **News on delta receipt requires an actual merge, not just a
   non-empty response.** A `DeltaResponse` we *receive* only resets the
   gossip pacer when it actually merges at least one new entry — a
   response that is non-empty on the wire but resolves to zero accepted
   entries (all already held, or dropped by the per-author contiguity
   guard) is redundancy, not novelty. (Serving a puller — a non-empty
   response we *send* — is still news regardless of what the puller
   does with it.)
2. **Membership news is asymmetric between the two loops.** The gossip
   engine's pacer resets on both peer addition and peer removal. The
   failure detector's pacer resets on addition (via `probeNewPeer`) and
   on probe failure, but deliberately **not** on removal — a shrinking
   registry is self-evident and needs no immediate re-probe of the
   remaining peers.
3. **Probe suppression is capped.** Freshness-only suppression keys on
   INBOUND evidence (`lastContactMs`), which under asymmetric one-way
   loss (our probes to a peer die, but the peer's own traffic to us —
   e.g. its own unreachable-probing of us — keeps arriving) never stops,
   suppressing that peer forever with no detection. Every peer is now
   actually probed at least once per 2-minute cap window (4x the 30 s
   ceiling; not configurable) regardless of freshness, bounding
   half-open detection under one-way loss. `FailureDetector.start()`
   also now resets the pacer on restart, mirroring
   `GossipEngine.start()`'s existing "a restart is news" behavior — a
   paused/resumed detector must not resume mid-backoff into a stale
   world.
