# Make the two timing-sensitive Kotlin tests immune to parallel load

**Track:** Kotlin port   **Depends on:** nothing

## What this is

Two tests in the Kotlin library's suite occasionally fail when the whole
suite runs in parallel on a busy machine, and pass every time on their own
or on a rerun: one checks that reactive pushes skip a congested peer, the
other that the hybrid logical clock's physical component advances with
simulated time. Both rely on real wall-clock timeouts, so a scheduling
hiccup under load can make a wait expire before the thing it waits for
happens. Neither test's subject was changed by the batch that first saw
the flakes (the domain purification, which moved locks without touching
timing), so these are pre-existing sensitivities, not regressions.

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

- Recorded during the
  [Kotlin domain purification](../superpowers/specs/2026-09-02-kt-domain-purification-rulings.md)
  batch (its ledger lists both occurrences).
- The Dart side's adverse-network harness is the model for
  simulated-time-driven tests:
  [Simulate adverse network conditions in the test harness](testing-network-condition-simulation.md).
