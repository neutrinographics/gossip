# Give the Kotlin library Dart's fair probe rotation and timing policies

**Track:** Kotlin port   **Depends on:** nothing

## What this is

When a device checks its neighbours' health, *which* neighbour it checks next
matters. The Dart library rotates through peers fairly (a shuffled cursor, so
every peer is probed on a predictable cadence and none is starved), holds off
re-probing a peer that is already being probed, and keeps the timing rules in
small named policy objects. The Kotlin library picks a random peer each round
— statistically similar, but a peer can go unprobed for a long unlucky
stretch — and inlines its timing logic in the detector.

This item ports the fair rotation and the policy extraction, and folds in two
small adjacent parity gaps in the same area: the detector's own note that it
should receive incoming messages the way Dart's does, and the handful of
small shared helpers Dart factored out (jitter, duration clamping) that the
Kotlin side open-codes.

## Why it matters

Random selection makes failure detection latency a lottery: the unlucky peer
is exactly the one whose failure is noticed late. Beyond behavior, the two
detectors currently *read* differently — Dart's timing rules have names, the
Kotlin ones are inline arithmetic — which makes every future port in this
area harder to verify. The parity program's structural goal (same concepts,
same names, both sides) applies to services, not just packages.

## Rough approach

Port the selector and the timing-policy objects as they exist in Dart's
membership context, translating the concurrency posture per the recorded rule
(monitor-guarded services on the Kotlin side). Behavior first, extraction
with it — the extraction is what makes the behavior reviewable.

## Related

- Found untracked by the 2026-09-01 parity survey; recorded in the
  [twin parity program](../parity.md).
- Distinct from (but adjacent to) the *suppression* behaviors — probing a
  recently-heard-from peer less — which belong to
  [Port the wire-efficiency behaviors to the Kotlin library](kt-port-wire-efficiency.md).
- Sibling: [Retire indirect health probing from both libraries](kt-retire-indirect-probing.md).
