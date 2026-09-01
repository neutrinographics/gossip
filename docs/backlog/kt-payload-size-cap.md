# Give the Kotlin library the payload size cap the Dart library enforces

**Track:** Kotlin port   **Depends on:** nothing

## What this is

The Dart library refuses an oversized payload at write time: an application
that tries to store a blob too large to ever fit in a transport frame gets an
immediate error, instead of an entry that poisons sync later. The budget is
derived from the wire format's own arithmetic (the legacy dialect affords
about 7.5 KB per entry, the current one about 22 KB), so the refusal happens
at the earliest possible moment with the clearest possible blame.

The Kotlin library has no such cap anywhere. Nothing refuses an oversized
write, and the server's frame limit is effectively infinite — so an entry too
big for a phone to accept can be created on the server, replicate nowhere,
and stall the stream it lives in. The compaction rollout survey noted this
exact asymmetry: the server accepts what the fleet cannot carry.

## Why it matters

A single oversized entry is the worst kind of failure: written successfully,
visible locally, and silently unshippable. On a mixed fleet the server is the
node most likely to receive large payloads (it fronts application features),
which makes it the node that most needs the guard. Parity here is also what
keeps the two libraries' *promises* identical — an application developer must
get the same answer to "how big can an entry be?" on both sides.

## Rough approach

Port the Dart cap: a configuration value with the same wire-derived defaults,
enforced at the append path with a typed error, plus the matching frame-size
ceiling on the server transport. Adopt the same budget arithmetic the wire
spec records so the two libraries can never disagree about the limit.

## Related

- Found untracked by the 2026-09-01 parity survey; recorded in the
  [twin parity program](../parity.md).
- The budget arithmetic lives in the
  [wire versioning spec](../superpowers/specs/2026-08-28-wire-versioning.md).
- The mixed-fleet consequence is described in the
  [compaction rollout survey](../superpowers/specs/2026-08-31-compaction-rollout-survey.md).
- Sibling: [Teach both libraries to speak versioned wire formats](kt-wire-versioning-campaign.md)
  (carries the related but distinct "fit digests/deltas to a size budget" scope).
