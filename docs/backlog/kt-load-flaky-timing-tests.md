# Make the timing-sensitive Kotlin tests immune to parallel load

**Track:** Kotlin port   **Depends on:** nothing

## What this is

Three tests in the Kotlin library's suite occasionally fail when the whole
suite runs in parallel on a busy machine, and pass every time on their own
or on a rerun: one checks that reactive pushes skip a congested peer, one
that the hybrid logical clock's physical component advances with simulated
time, and one that a local write reaches peers as an unsolicited push. All
three rely on real wall-clock timeouts, so a scheduling hiccup under load
can make a wait expire before the thing it waits for happens. None of the
tests' subjects was changed by the batches that saw the flakes (the domain
purification moved locks without touching timing; the lifecycle batch saw
the third test fail twice and pass six isolated runs), so these are
pre-existing sensitivities, not regressions.

The third test is the most fragile of the three: it busy-waits for the
simulated clock to hold a second parked sleeper before advancing time, and
a loaded machine can leave that sleeper unregistered for longer than the
wait allows.

## Why it matters

A flaky test trains people to rerun instead of read. Every future batch
that runs the full suite will trip over one of these sooner or later and
lose time deciding whether it is real. Two such tests are enough to
justify one fix rather than two shrugs.

## Rough approach

Drive each test from the simulated clock instead of a real timeout, or
give the real-timeout one a generous bound and a positive signal to wait
for rather than a fixed sleep. Confirm by running the full suite several
times under load.

## Related

- Seen twice more during the receive-loop lifecycle batch (gossip-kt PR #8,
  September 2026), whose other deferred findings live in
  [Tidy the loose ends the lifecycle batch left in the Kotlin library](kt-lifecycle-batch-follow-ups.md).
- Recorded during the
  [Kotlin domain purification](../superpowers/specs/2026-09-02-kt-domain-purification-rulings.md)
  batch (its ledger lists both occurrences).
- The Dart side's adverse-network harness is the model for
  simulated-time-driven tests:
  [Simulate adverse network conditions in the test harness](testing-network-condition-simulation.md).
