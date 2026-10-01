# Report an oversized digest once, not every round

**Track:** Sync engine   **Depends on:** nothing

## What this is

When a single stream's summary is too large to fit one message at all — a
stream with hundreds of authors — the library cannot send it, and says so
through the error callback. It says so on every request and every response
to every peer, every round, for as long as the condition lasts. The same
holds for an announcement whose name alone exceeds the announce budget,
which is logged as a warning each time.

This item makes each such report fire once per stream (or channel) and again
only when the condition changes, the way the library already reports a
sequence gap once per position rather than on every probe.

## Why it matters

A permanently oversized stream on a server with many peers floods the error
callback and the log at the gossip floor — hundreds of identical reports a
minute — which trains operators to ignore the channel that should carry real
faults. No production stream is near the limit today; this is recorded so
the first one is not a surprise.

## Rough approach

A per-position record of what has been reported, re-armed when the stream
compacts or the budget changes, consulted before emitting. Both twins; the
Kotlin side inherited the every-round shape from Dart with the digest
budgeter port.

## Related

- Recorded by the [digest-scoping rulings](../superpowers/specs/2026-09-30-digest-scoping-rulings.md) review of gossip-kt PR #20; register row "Unannounceable announcements".
- The once-per-position precedent: the reported-gap registry in the merge path.
