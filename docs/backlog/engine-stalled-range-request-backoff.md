# Suppress pulling an author's range a peer has already failed to supply

**Track:** Sync engine   **Depends on:** nothing

## What this is

When a device asks a peer for entries it is missing and the peer's answer starts
above the requested point (a "sequence hole" — the peer no longer has the early
entries and does not say the range is gone for good), the sync engine correctly
refuses the gapped data and reports the stall once. But it does not remember the
failure: because the device's record of that author never advances, every later
exchange with that peer re-ships the author's entire unusable range — which
grows forever — alongside whatever useful data the exchange carries, and the
device rejects it every time. Both libraries (Dart and Kotlin) share this
shape.

The fix is per-author, not per-request: remember "this peer cannot supply this
author's early range" and shape later requests to that peer so it stops sending
that author at all, while every other author keeps syncing normally. Re-probe
the stalled range occasionally (a growing pause with a ceiling), and drop the
suppression the moment the range becomes obtainable — the peer announces the
range is gone for good, the range arrives from someone else, or the peer
reconnects. A whole-stream pause would not work here: streams with live traffic
(presence heartbeats) make progress on every exchange, so only the author-level
view can tell the stalled part from the healthy part.

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

The engine already detects the gap per author and records it to deduplicate
the warning — that same knowledge can shape the next request. Track stalls per
(peer, stream, author); when building a request to that peer, raise the
request's starting point for suppressed authors to what the peer has already
advertised, so the peer sends nothing for them. Everything is cleaned lazily
at request-building time — no timers: re-probe when the pause expires
(a failed probe doubles it, up to a ceiling), evict when the device's own
record of the author advances (the range arrived from elsewhere, or the peer's
"gone for good" announcement was adopted), and clear a peer's entries when it
disconnects. The stall warning stays exactly as visible as today; only the
wasted traffic stops. Full design: see the spec linked below.

## Related

- Spec: `docs/superpowers/specs/2026-08-31-stalled-range-suppression-design.md`
  (this is the Dart reference implementation; the Kotlin port follows it).
- Follow-on: [Port stalled-range suppression to the Kotlin library](kt-stalled-range-suppression-port.md)
  — ends the live server↔old-phone waste.
- Rollout: reaches the phone fleet in the app's next gossip pin bump *after*
  OpenDoorApp PR #486 merges (decided 2026-08-31 — #486 stays as verified for
  its device session).
- Found during the 2026-08-31 server memory incident (opendoor-api R14s); the
  Kotlin library exhibited it in production, and the Dart engine shares the
  request-on-every-mismatch shape. Recorded as the
  "Stalled-range re-request cadence" row in
  [the twin-divergence register](kt-normalize-twin-divergences.md).
- [Port the wire-efficiency behaviors to the Kotlin library](kt-port-wire-efficiency.md)
  — same theme of not chatting at full cadence forever.
- [Coalesce wire traffic into fewer radio wakeups](engine-message-coalescing.md)
  — sibling cadence-reduction work on the Dart side.
