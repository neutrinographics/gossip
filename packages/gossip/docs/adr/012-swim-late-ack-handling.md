# ADR-012: Late-Ack Grace Window

## Status

Accepted; **amended 2026-09-18** — the grace window is now the
shape of every verdict-bearing probe, not a special case.

## Context

Failure detection (ADR-004) sends a direct Ping and waits a per-peer
RTT-adaptive timeout for the Ack. In real mobile network conditions, Acks
sometimes arrive slightly after that timeout.

Observed behavior in production logs showed the pattern:
```
Probe FAILED for NodeId(...) (pings sent: 6, acks received: 5)
Received Ack seq=6
Ack seq=6 did NOT match any pending ping (pending sequences: [])
```

The Ack arrived ~175ms after the probe timeout, causing a spurious probe
failure even though the peer was healthy — unnecessary "suspected"
transitions and noise.

Originally the only wait after a direct timeout was the indirect probe
phase, so a two-device pair (no intermediaries) had no window at all, and a
larger group's window was an accident of relaying. The original decision
added an explicit equal-length wait for the no-intermediary case. The
2026-09 retirement of indirect probing (ADR-004 history) left that wait as
the only path.

## Decision

**Every verdict-bearing probe holds its pending ping open for one more
per-peer timeout after the direct timeout — the grace window — and counts
a failure only if the window closes empty.** The window races the still-
open pending ping, so it ends the instant a late Ack lands rather than
sleeping its full length.

Applies to the regular probe round and the unreachable-recovery probe.
Does not apply to the new-peer RTT bootstrap probe: it records no failure,
so there is no verdict to protect, and a late first sample is simply the
next probe's.

The window's length is the same per-peer adaptive timeout as the direct
wait, re-read when the window opens so a fresh RTT sample is honored. It
has no configuration knob of its own.

## Rationale

1. **Matches real-world network behavior**: an Ack 100–200ms late is a
   healthy peer, not a failure.
2. **No protocol change**: no new message types, no peer coordination.
3. **One shape**: two-device pairs and larger groups behave identically,
   and both libraries read the same probe line for line.
4. **Bounded cost**: worst case a failed probe takes two timeouts; the probe
   interval is sized at three (room for both, plus slack).

## Consequences

### Positive

- No spurious probe failures from latency spikes
- Stable peer status in two-device pairs
- No "did NOT match any pending ping" noise for merely-late Acks
- The late-Ack case is logged distinctly, which is the signal that a
  timeout is running tight

### Negative

- Detecting a real failure takes up to two timeouts per probe instead of
  one
- The pending-ping map holds entries slightly longer

### Trade-offs

At the 500 ms floor a failed probe costs 1000 ms (direct 500 ms + grace
500 ms); at the 10 s ceiling it costs 20 s. Real failures are still
detected within a few probe rounds, and false positives are more
disruptive than slightly slower detection.

## Alternatives Considered

### Increase the direct ping timeout

Simpler, but delays detection for all probes, not just the edge cases, and
still drops an Ack that lands just after the longer timeout.

### Ignore late Acks entirely

Simplest, but causes the spurious failures this record exists to remove.

### Sleep the full window, then check

The pre-2026-09 Dart shape. Same verdicts, but a late Ack at +100ms still
cost the remaining 400ms of the round. The Kotlin twin raced the window
from the start; Dart adopted the race with the retirement.
