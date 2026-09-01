# Sweep the remaining scenario coverage into the Kotlin library

**Track:** Kotlin port   **Depends on:** nothing

## What this is

The Dart library has a large suite of end-to-end scenario tests — whole
simulated networks of devices, run against awkward conditions: clocks that
disagree, links that drop or duplicate messages, devices that vanish and
come back. The Kotlin library had none of this until a dedicated batch
built the test harness for it and translated the coverage that carries the
most correctness weight: causality and clock skew, network topologies,
partitions and healing, congestion, message loss and duplication, churn
and restarts, membership, and message integrity.

What is left is the mechanical remainder — the scenario groups that are
valuable but that no longer teach us anything new about the harness:
notably the scale group (larger networks), the multi-channel group, and
the rest of the edge-case and lifecycle rows. This item is that sweep.

## Why it matters

The two libraries are meant to behave identically as two halves of one
system, and scenario tests are the only place that claim is checked
end-to-end rather than one unit at a time. Every Dart scenario without a
Kotlin counterpart is a behaviour that is pinned on one side of the system
and unpinned on the other — so a Kotlin regression there is invisible until
it shows up in the field.

The expensive part is already paid for: the harness, the network DSL, and
the link-condition primitives all exist and are proven. What remains is
translation work, which is why it is a sweep rather than a design task.

## Rough approach

Work through the untranslated Dart scenario files one group at a time,
carrying each test's *proof* rather than its letter — exact round counts and
timing assumptions are artifacts of Dart's single-threaded execution and do
not survive translation, but every behavioural assertion must. Each
translated test cites the Dart file it came from, and each scenario ends by
asserting no errors were reported. Where a translation is blocked by a real
behavioural difference rather than a harness gap, that difference gets a row
in the divergence register instead of a weakened test.

Two groups are blocked rather than merely pending: the relay-based health
scenarios cannot pass until the indirect-probing defect is fixed, and six
restart, pause, and multi-cycle scenarios cannot pass until stopping a
coordinator actually stops it.

## Related

- The harness this builds on, and the coverage already translated, shipped
  in the correctness-and-scenarios batch of
  [Teach both libraries to speak versioned wire formats](kt-wire-versioning-campaign.md).
- Formerly blocked groups: the relay-reachability scenario is **obsolete** —
  indirect probing is being retired on both sides
  ([Retire indirect health probing from both libraries](kt-retire-indirect-probing.md)),
  so that Dart test pins removed behavior and will not be translated. Still
  blocked: the six lifecycle scenarios, on
  [Make stopping a Kotlin coordinator actually stop it](kt-coordinator-restart-lifecycle.md).
- Test-strength differences found while translating are recorded in
  [Record where the Dart library and its Kotlin twin diverge, with a verdict](kt-normalize-twin-divergences.md).
