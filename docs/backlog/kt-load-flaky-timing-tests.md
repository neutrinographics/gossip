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

The architecture remediation batches (September 2026) added a fourth: the
churn scenario test, which drives eight coordinators through joins and
departures on real timeouts and tripped three times across two batches on
a saturated machine, passing every isolated rerun. The same batches
produced a diagnosis for the reactive-push pair: each test launches the
coroutine that collects the peer's incoming messages and then appends the
entry without waiting for that collector to subscribe, and the flow it
collects keeps no history, so under load the push can be delivered before
anyone is listening and the assertion waits on a message that has already
gone by. The fix is the ordinary one: await the subscription (or collect
from a flow that replays) before acting.

A related hygiene gap surfaced in the same batch: a test method written as
an expression body that ends in a non-void assertion gets a non-void return
type, and the test runner silently skips it while still reporting a green
build; only counting the executed cases against the declared ones shows the
gap. A gate that does that count belongs with the architecture gates.

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

- During batch D (2026-09-24/25) the reactive-push pair tripped in three of
  five full-suite runs on one machine and never in isolation; the batch's
  ledger holds the tally. Its ten-second wall-clock timeouts are the
  suspect.
- `CoordinatorTest`'s log-forwarding test threw a concurrent-modification
  error (PR #12, round 3, and twice more during PR #13): it iterated a
  synchronized list without holding its monitor while the log callback
  appended from another thread. Fixed in PR #13 (f406d25) by making every
  recording list in that file copy-on-write, so iteration is a snapshot;
  batch D's own removal pin had the same defect and the same fix.
- `CausalityTest`'s "HLC physical time advances with simulated time" failed
  once during PR #12's review rounds (a sequence-hole protocol error from a
  compaction race), green in isolation and in the next two full runs; the
  unsolicited-delta reactive-push test tripped once more the same day.
- The burst-coalescing reactive-push engine test failed two of four
  full-suite runs during batch C (gossip-kt PR #12, 2026-09-24), green in
  isolation and at the base commit; it spins on a wall-clock timeout.
- Seen three more times during the architecture remediation batches A and B
  (gossip-kt PRs #10 and #11, September 2026), where the reactive-push
  diagnosis above was written down; the batch B ledger holds the runs.

- Seen twice more during the receive-loop lifecycle batch (gossip-kt PR #8,
  September 2026), whose other deferred findings live in
  [Tidy the loose ends the lifecycle batch left in the Kotlin library](kt-lifecycle-batch-follow-ups.md).
- Recorded during the
  [Kotlin domain purification](../superpowers/specs/2026-09-02-kt-domain-purification-rulings.md)
  batch (its ledger lists both occurrences).
- Seen during batch F (2026-09-26): `DeltaMergerTest`'s "two concurrent
  merges of one stream serialize — no partial batches, no spurious errors"
  failed once under full-suite load and passed three of three in isolation;
  the batch touched no merge code. A fifth member of the list.
- The Dart side's adverse-network harness is the model for
  simulated-time-driven tests:
  [Simulate adverse network conditions in the test harness](testing-network-condition-simulation.md).
