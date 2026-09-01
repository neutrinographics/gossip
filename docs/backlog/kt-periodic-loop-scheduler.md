# Move the Kotlin library's periodic loops onto the restartable scheduler

**Track:** Kotlin port   **Depends on:** nothing

## What this is

The Dart library's periodic work (gossip rounds, health probes) runs on a
scheduler that recomputes its delay *every cycle*, so adaptive timing — back
off when the network is slow, speed up when it's healthy — actually takes
effect continuously. The Kotlin library ported that scheduler for its
compaction loop, but its gossip and probe loops still run on a fixed-interval
timer that freezes the adaptive interval at whatever it was when the loop
started.

## Why it matters

The Kotlin library *has* adaptive timing and *reports* it, but two of its
three periodic loops don't honor it after startup — the interval a dashboard
shows is not the interval the loop uses. It also carries a failure-handling
asymmetry the Dart scheduler was specifically built to fix: a scheduling
error on the fixed timer can die silently while the loop still claims to be
running.

## Rough approach

Migrate the gossip and probe loops onto the already-ported scheduler, keeping
Dart's failure contract (a work error is reported and the loop continues; a
scheduling error stops the loop first, then reports). This was explicitly
scoped out of the compaction batch as a follow-up normalization; this item is
that follow-up's home.

## Related

- Recorded (previously unhomed) in the
  [divergence register](kt-normalize-twin-divergences.md), row
  "Per-cycle interval recomputation".
- The scheduler itself was ported by the auto-compaction batch of
  [Teach both libraries to speak versioned wire formats](kt-wire-versioning-campaign.md).
- See the [twin parity program](../parity.md).
