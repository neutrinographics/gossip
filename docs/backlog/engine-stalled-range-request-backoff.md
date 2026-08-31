# Back off delta requests for a range a peer has already failed to supply

**Track:** Sync engine   **Depends on:** nothing

## What this is

When a device asks a peer for entries it is missing and the peer's answer starts
above the requested point (a "sequence hole" — the peer no longer has the early
entries and does not say the range is gone for good), the sync engine correctly
refuses the gapped data and reports the stall once. But it does not remember the
failure: on the very next round it asks the same peer for the same range again,
the peer sends the same unusable answer, and the cycle repeats at full gossip
cadence for as long as the two are connected. Both libraries (Dart and Kotlin)
share this shape. The engine should remember "this peer just failed to supply
this range" and retry it with a growing pause instead of every round.

## Why it matters

The loop is pure waste — bandwidth, battery, CPU, and allocation churn — and it
runs forever whenever a mixed fleet pairs a floor-aware node with an older peer
whose history is truncated but who cannot say so. This is not hypothetical: the
day the server started syncing presence (2026-08-31), two phones with truncated
presence logs put the server into exactly this loop, and the resulting
allocation pressure pushed the process past its 512MB memory quota within
minutes and kept it there all day. Floors end the loop only when the *peer* can
send them; a backoff makes the engine cheap even when it cannot.

## Rough approach

The engine already detects the gap and records it to deduplicate the warning —
that same knowledge can gate the next request. Track recent gap outcomes per
(peer, stream, author range) and skip or delay re-requests against a growing
backoff window, reset when the peer's advertised state for that range actually
changes (or the peer reconnects). The stall stays visible and recovery stays
automatic; only the retry cadence changes.

## Related

- Found during the 2026-08-31 server memory incident (opendoor-api R14s); the
  Kotlin library exhibited it in production, and the Dart engine shares the
  request-on-every-mismatch shape — fix both in step. Recorded as the
  "Stalled-range re-request cadence" row in
  [the twin-divergence register](kt-normalize-twin-divergences.md).
- [Port the wire-efficiency behaviors to the Kotlin library](kt-port-wire-efficiency.md)
  — same theme of not chatting at full cadence forever.
- [Coalesce wire traffic into fewer radio wakeups](engine-message-coalescing.md)
  — sibling cadence-reduction work on the Dart side.
