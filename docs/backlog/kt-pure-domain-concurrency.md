# Purify the Kotlin domain layer: locks move to infrastructure wrappers

**Track:** Kotlin port   **Depends on:** nothing (sequenced by the owner after the current deployment train)

## What this is

The Kotlin library needs thread safety the Dart library never will (Dart
runs single-isolate by decision; Kotlin runs on a real thread pool), and
today that safety lives in three different places. Two aggregates already
do it the clean way: a pure domain class with zero locks, wrapped by a
small synchronized shell in the infrastructure layer. But five domain
services carry locks *inside* themselves — the pull tracker, both timing
policies, the hybrid logical clock (whose lock is also why its methods
suspend where the Dart clock's don't), and the periodic scheduler — and
the two engines guard several pieces of state in place.

This item moves every lock out of the domain layer into infrastructure
wrappers, the shape the peer registry and stalled-range registry already
prove: the five domain services become pure classes plus `Synchronized*`
wrappers, and the engines' guarded state (the reported-gap dedup, the
detector's ping bookkeeping) is extracted into pure aggregates behind the
same kind of wrapper. Wrappers on anything cleared from a non-suspend
lifecycle method must be plain monitors, not coroutine mutexes — the
constraint the pull tracker documented, carried to the wrapper unchanged.

Deliberately out of scope, each platform-necessitated and documented: the
coroutine-scope parameters (structured concurrency needs a launch home;
Dart futures float), the volatile lifecycle flags, and the two application
services whose mutexes guard critical sections that *suspend* across
repository calls — moving those means changing the repository contract,
a joint twin design decision, not a refactor.

## Why it matters

Parity maintenance is the point: a pure Kotlin domain body diffs almost
line-for-line against its Dart twin, so every future port and every parity
review gets cheaper, and the entire Kotlin-only concurrency delta
concentrates in a handful of small, boring wrapper files instead of being
threaded through domain logic. It is also the house DDD standard applied
consistently — the owner's ruling that domain purity is the default and
in-codebase precedent is not a justification. This supersedes the earlier
recorded rule ("monitor-guarded Kotlin domain services"), and narrows the
parity program's exemption for Kotlin thread safety from "domain services
carry monitors" to "infrastructure wrappers only".

## Rough approach

Mechanical, behavior-preserving, no public API changes: one pure class +
one wrapper per service, existing tests as the harness, following the
stalled-range registry as the template. The detector's ping-bookkeeping
extraction should ride the already-planned receive-loop lifecycle batch,
which restructures exactly those fields. The clock's purification restores
non-suspending operations (a small parity bonus). The engines' volatile
flags and scopes stay put.

## Related

- **Done:** gossip-kt 26e5e24 (PR #7, 2026-09-02).
- **Rulings for review:**
  [Kotlin domain purification — rulings](../superpowers/specs/2026-09-02-kt-domain-purification-rulings.md)
  (2026-09-02) — the inventory of every lock outside `infrastructure/` and
  the ten decisions the batch executes.
- The template: the stalled-range registry and its wrapper (shipped in
  [the stalled-range port](kt-stalled-range-suppression-port.md)), and the
  peer registry pair that predates it.
- The Dart-side sibling reshape:
  [Reshape the runtime trackers into honest domain objects](health-pure-runtime-trackers.md)
  — the two together converge both twins on pure domain state.
- The detector portion's vehicle:
  [Make stopping a Kotlin coordinator actually stop it](kt-coordinator-restart-lifecycle.md).
- Supersedes the "Thread-safety posture" recorded rule in
  [the divergence register](kt-normalize-twin-divergences.md); narrows
  exemption E3 in the [twin parity program](../parity.md).
