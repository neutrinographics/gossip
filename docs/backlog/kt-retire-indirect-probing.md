# Retire indirect health probing from both libraries

**Track:** Kotlin port   **Depends on:** nothing

## What this is

Both libraries carry a relay step in their health checking: before writing a
silent neighbour off, a device asks a third device to ping it on its behalf.
The owner ruled (2026-09-01) that this step is retired from both libraries
rather than kept — in the Kotlin library it never worked (the relay blocks
the very queue its answer must arrive through), and the decision record
establishes that fixing it would preserve machinery whose purpose cannot
occur here: relayed probing exists to stop one device's false "dead" verdict
from spreading through the group, and in this library verdicts never leave
the device that formed them.

What remains after retirement is the useful half of health checking: direct
probes as an idle keepalive, the graded reachable/suspected/unreachable
status that steers who gets gossiped with, the slow recovery probe for
unreachable peers, the grace window for slightly-late answers (generalized
to every probe), and the round-trip measurements that feed adaptive timing.

## Why it matters

Beyond deleting a defect instead of fixing it: on the server, every incoming
relay request today stalls the entire message-receiving loop for half a
second — head-of-line blocking on the one node that talks to everyone.
Retirement removes that stall class, a wire message type (eventually), and a
body of code both libraries would otherwise have to keep in lockstep.

## Rough approach

Dart first (it is the reference): remove the relay handler and the indirect
phase (the probe keeps its grace wait), adjust the asymmetric-partition
tests (the convergence-through-relay proof stays — data still flows
transitively; the relay-reachability pin goes), and revise the two affected
architecture decision records. The Kotlin removal rides the receive-loop
lifecycle batch, which already restructures the same component. On the wire,
the relay request follows the retirement shape: received and ignored
forever (the mixed fleet still sends it), never sent, encoder deleted at the
next dialect revision.

A one-way-deaf pair now degrades honestly — each side eventually marks the
other unreachable, data converges through any healthy third device, and the
pair recovers after the link heals. This is the behavior both test suites
already pin for the no-relay case.

## Related

- The ruling and full rationale: [decision record](../superpowers/specs/2026-09-01-swim-slimdown-decision.md).
- The Kotlin batch that absorbs the kt-side removal:
  [rulings page](../superpowers/specs/2026-09-01-receive-loop-lifecycle-rulings.md)
  and [Make stopping a Kotlin coordinator actually stop it](kt-coordinator-restart-lifecycle.md).
- History: this item replaces the former defect item "Make the Kotlin
  library's indirect health probing actually work" — the defect (found by
  Batch KT-D, 2026-08-30) is resolved by this removal, not by repair.
- Siblings: [Give the Kotlin library Dart's fair probe rotation and timing policies](kt-probe-selection-parity.md),
  [Sweep the remaining scenario coverage into the Kotlin library](kt-scenario-parity-sweep.md).
