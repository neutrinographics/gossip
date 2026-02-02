# ADR-012: SWIM Late-Ack Handling

## Status

Accepted

## Context

The SWIM failure detection protocol (ADR-004) uses direct pings with a timeout, falling back to indirect pings through intermediaries when the direct ping times out. However, in real-world mobile network conditions, Acks sometimes arrive slightly after the direct ping timeout expires.

Observed behavior in production logs showed a pattern:
```
[14:21:42.788] SWIM: Probe FAILED for NodeId(...) (pings sent: 6, acks received: 5)
[14:21:42.963] SWIM: Received Ack seq=6
[14:21:42.964] SWIM: Ack seq=6 did NOT match any pending ping (pending sequences: [])
```

The Ack arrived ~175ms after the probe timeout, causing a spurious probe failure even though the peer was healthy. This creates unnecessary "suspected" transitions and noise in failure detection.

Two scenarios were identified:

1. **3+ devices**: The indirect ping phase provides natural delay, but the original pending ping was being cleaned up immediately on timeout, preventing late Ack matching.

2. **2-device scenario**: With only two devices, there are no intermediaries for indirect ping. The `_performIndirectPing` method returned immediately, giving no time for late Acks to arrive.

## Decision

**Keep pending pings alive during the indirect ping phase and add a grace period when no intermediaries exist.**

### Implementation

1. **Don't remove pending ping on timeout**: The `_awaitAckWithTimeout` method no longer removes the pending ping when timeout occurs. Late-arriving Acks can still be matched.

2. **Check for late Acks after indirect phase**: After both direct and indirect probes complete, check if the original Ack arrived late. Only record probe failure if neither direct, indirect, nor late Ack succeeded.

3. **Grace period for 2-device scenario**: When no intermediaries are available, wait for `indirectPingTimeout` duration as a grace period before declaring failure. This gives late Acks time to arrive even without indirect probing.

```dart
Future<bool> _performIndirectPing(NodeId target, int sequence) async {
  final intermediaries = _selectRandomIntermediaries(target, 3);

  if (intermediaries.isEmpty) {
    // No intermediaries - wait grace period for late Acks
    await timePort.delay(_indirectPingTimeout);
    return false;
  }
  // ... indirect ping logic
}
```

4. **Cleanup after probe round**: Pending pings are cleaned up only after the entire probe round completes (both direct and indirect phases).

## Rationale

1. **Matches real-world network behavior**: Mobile networks often have variable latency. An Ack arriving 100-200ms late shouldn't trigger failure detection.

2. **No protocol changes**: This is an implementation improvement within the existing SWIM protocol. No new message types or peer coordination required.

3. **Consistent behavior**: Both 2-device and multi-device scenarios now handle late Acks the same way - by waiting for the indirect ping timeout duration.

4. **Minimal overhead**: The grace period is only the `indirectPingTimeout` (default 500ms), same as what would be spent on indirect probing anyway.

## Consequences

### Positive

- Reduces spurious probe failures from network latency spikes
- More stable peer status in 2-device scenarios
- Cleaner logs without "did NOT match any pending ping" warnings
- No false suspicions from transient delays

### Negative

- Slightly longer time to detect actual failures in 2-device scenario (adds grace period)
- More complex probe round logic with deferred cleanup
- Pending ping map holds entries slightly longer

### Trade-offs

The grace period in 2-device scenarios adds latency to failure detection. With default settings:
- Direct timeout: 500ms
- Grace period: 500ms
- Total: 1000ms per probe round

This is acceptable because:
- Real failures will still be detected within 3 seconds (3 failed probes)
- False positives are more disruptive than slightly slower detection
- Mobile networks commonly have latency spikes in this range

## Alternatives Considered

### Increase Direct Ping Timeout

Simply increase `pingTimeout` to account for latency:
- Simpler implementation
- But delays detection for all probes, not just edge cases
- Doesn't solve the fundamental timing issue

### Adaptive Timeout (Phi Accrual)

Track Ack latency history and adapt timeout:
- More sophisticated
- But adds significant complexity
- Overkill for small device networks
- Still doesn't handle the cleanup timing issue

### Ignore Late Acks Entirely

Let late Acks be discarded as before:
- Simplest approach
- But causes unnecessary probe failures
- Poor UX with frequent status changes
- Wastes indirect ping bandwidth on healthy peers
