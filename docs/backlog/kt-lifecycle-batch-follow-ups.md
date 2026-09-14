# Tidy the loose ends the lifecycle batch left in the Kotlin library

**Track:** Kotlin port   **Depends on:** nothing

## What this is

The receive-loop lifecycle batch (Kotlin, September 2026) shipped with every
reviewer finding either fixed or deliberately deferred. This item is the
list of the deferred ones, so they get done rather than forgotten. None of
them changes behaviour that a user of the library would notice; each is a
small hardening of the tests or the simulated clock the tests run on, or a
comment that still describes something the batch removed.

The pieces, roughly in the order they are worth doing:

- **Make the "one suspension point" promise a compile-time fact.** The
  coordinator's restart guard is only correct because starting the engines
  cannot pause midway. Today that is true by inspection; the cheap way to
  make it true by construction is to stop declaring the engine's start
  method as suspending, so any future pause on that path fails to compile.
  Needs a nod from the owner, since it is a small public-API change.
- **Give the engine unit-test harness a teardown.** Every engine the
  harness starts leaves a scheduling loop parked on the simulated clock.
  Harmless today, but one shared clock advance away from a background round
  landing in the middle of an assertion.
- **Let the simulated clock refuse late sleepers.** After the clock is
  closed, a new sleep on it parks forever; the clock's periodic timers
  already refuse loudly in that state, and sleeps should match. A cancelled
  sleep also leaves its bookkeeping entry behind, so the "how many sleepers"
  gauge overcounts.
- **Pin the one ingestion gate no scenario can reach.** A paused node never
  asks for a digest, so nothing exercises the rule that it ignores a digest
  answer if one arrives anyway. A ten-line engine unit test covers it.
- **Sharpen the mid-merge cancellation pin.** The test proves a stop during
  a merge still delivers the merged-entries event; it does not yet prove
  the append happened before the event. A test double that commits first
  and pauses second would pin the order too.
- **Trim comments that describe retired behaviour** in the kept metrics
  test, and drop the recovery path's duplicate contact recording (the ack
  handler already records it).
- **Sweep the old campaign labels** out of two coordinator test comments.
- **Decide what a dead scheduler should do to ingestion.** Both libraries
  gate ingestion on the same flag that says the periodic gossip loop is
  alive. If that loop ever dies from a scheduling failure (a clock whose
  sleep throws — none of the shipped clocks do), the node keeps reporting
  itself as running but stops both pulling and merging until it is stopped
  and started again. The failure is loud (an error is reported), the shape
  predates the lifecycle batch, and Dart has it too. Raised by the automated
  reviewer on the batch's pull request. Options: let a start call on a
  running node revive dead loops, surface loop health on the status
  snapshot, or document the restart as the recovery. Both twins, one
  decision.

## Why it matters

Deferred findings that live only in a review transcript are the ones that
come back as a surprise a year later. Each of these is a few minutes of
work; together they keep the lifecycle guarantees the batch established
from eroding quietly through test rot.

## Related

- The batch these came from: gossip-kt PR #8; rulings in
  [the lifecycle rulings page](../superpowers/specs/2026-09-01-receive-loop-lifecycle-rulings.md);
  the pre-execution audit in
  [the plan audit](../audits/2026-09-14-receive-loop-lifecycle-plan-audit.md).
- The flaky test seen twice during the batch is tracked separately, and
  first: [Make the timing-sensitive Kotlin tests immune to parallel load](kt-load-flaky-timing-tests.md).
- Sibling sweep on the Dart side:
  [Sweep the remaining minor audit findings](health-minor-findings-sweep.md).
