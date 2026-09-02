# Reshape the runtime trackers into honest domain objects

**Track:** Code health   **Depends on:** [Suppress pulling an author's range a peer has already failed to supply](engine-stalled-range-request-backoff.md) (sets the pattern)

## What this is

The library keeps a few pieces of runtime bookkeeping — which pulls are
pending, which round-trip times were seen — in classes filed as "domain
services" that hold mutable state, read the clock through an injected port,
and sometimes mutate while answering a question. The owner ruled (2026-09-01,
during the stalled-range spec review) that this shape is a code smell: a
domain service is stateless, a query doesn't change anything, and "an
existing class already does it this way" is not a justification. Pure DDD is
the house standard because it keeps the code easy to read and reason about;
any deviation needs a genuinely good reason.

The stalled-range work establishes the honest shape: a small domain
*aggregate* — entries with identity and lifecycle behind one root that owns
the invariants — that is fully deterministic, takes time as an argument
instead of holding a clock, and separates commands from queries strictly.
This item brings the existing trackers in line with it: the pending-pull
tracker first, and an audit of its siblings (the round-trip-time tracker,
and any similar stateful helper filed under domain services) for the same
smell.

## Why it matters

Readability is the stated reason, but there are mechanical ones too: a
dependency-free deterministic object needs no fakes to test, its Kotlin
translation becomes a pattern match for the twin's pure-registry-plus-
synchronized-wrapper shape (instead of internal locking decisions made case
by case), and strict command/query separation makes call sites self-evident
about what changes state. Every class that follows the smell instead makes
the next one look normal.

## Rough approach

Once the stalled-range aggregate lands, reshape the pending-pull tracker to
match: aggregate (or entity set behind a root) in the aggregates sublayer,
time passed in, commands and queries split. Sweep the domain-services
sublayers of both contexts for other stateful residents and either reshape
or justify each in writing. Behavior-preserving throughout — this is a
structural refactor with the existing tests as the harness.

## Related

- The Kotlin twin's `PendingPullTracker` keeps today's port-holding shape
  behind its wrapper (purification batch, gossip-kt PR #7, 2026-09-02)
  until this item reshapes the Dart original; kt follows Dart there.
- The ruling and the pattern-setter:
  [stalled-range suppression design](../superpowers/specs/2026-08-31-stalled-range-suppression-design.md)
  (its "Decisions from the owner's review" section).
- The Kotlin twin already models its peer state this way (pure registry
  aggregate + synchronized wrapper) — the twin's port items assume it.
- Sibling sweep: [Adopt the Kotlin twin's recorded improvements into the Dart library](health-adopt-kt-flow-backs.md).
