# Coalesce wire traffic into fewer radio wakeups

**Track:** Sync engine   **Depends on:** nothing

## What this is

Several small messages that leave within a short window could travel as
one. This item is the coalescing tier the wire-scheduling audit sketched:
a brief transport-level hold-and-batch (a "Nagle" delay) so back-to-back
sends share one link transaction, batched delta forms so multiple streams'
entries ride one message, completing the push-pull exchange so one round
trip does the work of two, and scaling the reactive-push debounce with the
measured link latency instead of a fixed 150 ms.

## Why it matters

On Bluetooth, each message costs a radio wakeup and per-write overhead that
dwarfs a few extra payload bytes. Fewer, fuller messages directly extend
battery life — the point of the whole wire-efficiency effort.

## Rough approach

In pay-off order: SRTT-scaled push debounce (smallest), batched delta
forms, push-pull completion, then the transport-level hold window (largest,
and only worthwhile now that MTU negotiation and quiescence pacing exist).

## Related

- Findings WIRE4-12, WIRE4-13, WIRE4-25, WIRE4-27 (recommendation R7) in
  [audits/2026-08-20-wire-scheduling-audit.md](../audits/2026-08-20-wire-scheduling-audit.md).
- Sibling: [Send reactive pushes only to peers that share the data](engine-push-scoping.md).
