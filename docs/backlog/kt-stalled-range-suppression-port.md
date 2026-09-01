# Port stalled-range suppression to the Kotlin library

**Track:** Kotlin port   **Depends on:** Suppress pulling an author's range a peer has already failed to supply

## What this is

Once the Dart library learns to stop re-pulling an author's range a peer has
already failed to supply (see the item this depends on), the Kotlin twin needs
the same behavior. The Kotlin library is the one that exhibited the problem in
production: the server, syncing presence against phones whose early history is
gone, re-requested and re-received the same unusable range continuously, and
the resulting churn pushed the process past its memory quota for a full day
(the 2026-08-31 R14 incident). The heap cap shipped in opendoor-api contains
the damage; this port removes the waste itself.

## Why it matters

The server talks to the whole phone fleet, so it pairs with every not-yet-
upgraded device at once — it feels the mixed-fleet cost first and hardest, and
the fleet migration window is open-ended. Every day without the port, the
server spends bandwidth, CPU, and allocations re-receiving data it must throw
away.

## Rough approach

A translation, not a redesign: port the Dart reference implementation and its
test suite, in the campaign's established direction (Dart tests become Kotlin
tests). The Dart design is a pure, dependency-free domain aggregate (time
passed in as data), so the platform adaptation is the Kotlin library's
existing registry pattern: keep the aggregate pure and wrap it in a
synchronized shell — the same shape as its peer registry — rather than
locking internally or reaching for a coroutine mutex. Ships to production
with an opendoor-api submodule bump and deploy.

## Related

- Depends on: [Suppress pulling an author's range a peer has already failed to supply](engine-stalled-range-request-backoff.md)
  and its spec (`docs/superpowers/specs/2026-08-31-stalled-range-suppression-design.md`).
- The incident and the shared gap are recorded as the "Stalled-range
  re-request cadence" row in
  [the twin-divergence register](kt-normalize-twin-divergences.md).
- Thread-safety pattern for the tracker: the register's "Thread-safety
  posture" row.
