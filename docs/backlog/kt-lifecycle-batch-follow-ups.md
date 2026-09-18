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
- **Stop the simulated clock's sleeper gauge from overcounting.** A sleep
  that is cancelled from outside leaves its bookkeeping entry behind, so
  the "how many sleepers are parked" count the tests wait on can read high.
  (A sleep requested after the clock is closed is already refused, since
  the batch's second automated-review pass.)
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
- **Make the coordinator safe against a lifecycle call from inside its
  own error callback.** While the collector is being attached, it can
  run the application's error callback on the calling thread before the
  coordinator has finished recording the new state. A stop issued from
  inside that callback is then partly overwritten when the start call
  completes. Nobody does this today, the hazard predates the lifecycle
  batch, and the fix is small (finish the state transition before any
  frame can be routed, or defer the callback).
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
  decision. The same item should decide whether a loop ended by shutdown
  (its clock closed or its scope cancelled) should still report itself
  as running, which it does today.

Three more came out of the Dart relay retirement's review (2026-09-18),
where the Dart detector ended up ahead of the Kotlin one it was matching:

- **One probe path, cleaned up in a `finally`.** The Kotlin detector spells
  out the probe sequence twice (the regular round and the recovery probe)
  and removes the pending ping outside any `finally`, so a round cancelled
  mid-wait leaves its entry behind for the detector's lifetime — a small
  leak. Dart now has one shared probe routine with a flag for the bootstrap
  probe, and the cleanup cannot be skipped. Port that shape; while there,
  drop the second contact write on a late acknowledgement (the Ack handler
  already recorded it) and add the sequence number to the late-Ack log
  line so it correlates with the send line.
- **Give an ignored relay request ordinary proof-of-life credit.** Dart
  stamps contact for every inbound frame before decoding it, so a relay
  request from an older peer refreshes that peer's last-contact time like
  any other frame; Kotlin stamps only sync frames, so on the server the
  same frame earns nothing. Stamp per frame at the routing point.
- **Stop calling it SWIM.** The Kotlin detector's class doc, README and
  CLAUDE.md still describe the mechanism as SWIM and log with a `[SWIM]`
  prefix; Dart renamed to failure detection and `[FailureDetector]`. Same
  words on both sides, plus the Dart caveat that the probe interval is only
  nominally three timeouts and a slow peer can overrun it.

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
