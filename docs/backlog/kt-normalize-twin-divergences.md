# Record where the Dart library and its Kotlin twin diverge, with a verdict

**Track:** Kotlin port   **Depends on:** nothing

## What this is

The Dart library (`packages/gossip`) and its standalone Kotlin port
(`gossip-kt`) implement the same protocol twice, in two languages, by two
different hands at two different times. Every time a review of one
compares it against the other, it turns up a place where they made a
different choice — sometimes a deliberate, permanent one, sometimes an
accident nobody has revisited. This file is the durable register of those
differences: one row per divergence, a plain read of where each side
stands, a verdict on which is better (or that the difference is fine to
keep), and where the fix (if any) already lives.

The practice this register exists to support is bidirectional: when a
review of a Dart change surfaces a divergence, or a review of a Kotlin
change does, the divergence gets a row here before the conversation that
found it is forgotten. Adoption can flow either way — most of the time the
port is catching up to the original, but sometimes the port found the
better shape and the original should adopt it.

## Why it matters

Two implementations of one protocol drift apart silently unless someone
writes the drift down. A code review that spots a divergence and doesn't
record it is a fact that evaporates the moment the branch merges — the
next person to touch either side has no way to know the difference was
ever noticed, let alone judged. Recording it with a verdict turns a
one-time observation into something the other library can act on whenever
it's next convenient, and stops the same divergence from being
"rediscovered" and re-litigated in a future review.

## The register

| Divergence | Where each side stands | Which is better | Recommendation |
|---|---|---|---|
| Frame dispatch | kt chains membership→sync through one dispatch point: exactly one report per bad frame, and a `NotMine` result short-circuits before the other codec ever tries to parse. Dart runs both engines' codecs independently over the full incoming stream, so a byte neither codec recognizes throws in both and is reported twice per frame — a known flaw the wire-versioning spec's §5.2 rollout-ordering constraint has to work around rather than fix. | kt | Dart should adopt a single dispatch seam that tries one codec, only falls through to the other on a sibling (`NotMine`)-shaped result, and reports malformed frames exactly once. |
| Decode failure contract | kt's decode result is a sealed type with three cases — decoded, not-mine (sibling family, fall through), and malformed (with diagnostic detail). Dart represents the same three outcomes as: `null` return for "not mine", a thrown exception for an unrecognized type, and an `onError` callback catch at the call site to turn that exception into a report. | kt | kt's shape is more explicit and type-safe — the caller can't forget to handle a case the way it can forget to catch an exception. Candidate for Dart to adopt, most naturally alongside the single-dispatch-seam change above since both touch the same call sites. |
| Frame classifier | kt's frame classifier (`FrameFraming`) is a non-throwing sealed result carrying typed diagnostics for each way a frame can fail to classify. Dart's `frameTypeOffset` throws and otherwise returns a plain offset. | kt is richer | Optional. Dart already adopted the differentiated per-class marker diagnostics this classifier produces (the "unregistered wire version N" style messages); moving to a non-throwing sealed *shape* on top of that is a nice-to-have, not a gap that causes wrong behavior. |
| Version-vector explicit-zero handling | Dart drops explicit zero entries at construction (`VersionVector`'s normalization), on the rationale that keeping them lets structural and semantic equality diverge for what should be the same vector. kt preserves explicit zero entries as written. | Tolerated asymmetry | Absent and explicit-zero are semantically identical to both decoders, and both sides' decode paths are fine either way — this asymmetry is deliberate on the Dart side and likely permanent. Record it as a considered choice, not an open gap. |
| Delta batching | kt's original (pre-wire-versioning-batch) delta emission batched multiple messages into one envelope. That shape was the inspiration for the budget-aware batch-envelope wire-efficiency item, which already exists on the roadmap. | N/A — idea already captured | Don't duplicate; see [Coalesce wire traffic into fewer radio wakeups](engine-message-coalescing.md) ("batched delta forms"), which carries this forward for both libraries. |
| Entry insertion order | kt's `findInsertIndex` (`in_memory_entry_repository`-equivalent) orders entries by timestamp only when inserting. Dart orders by the full `(timestamp, author, sequence)` total order. | kt is worse | This is a real correctness gap, not a style difference: two peers whose materializers fold entries in different arrival order for an HLC tie will converge to different derived state. The fix is already routed — it's flagged as a KT-E candidate in the Kotlin port's batch sequence (`docs/superpowers/specs/2026-08-28-kt-port-dart-fix-inventory.md`, item 13 / "M3"). This row exists so the divergence has a home outside that plan file too. |
| Pending-request expiry | Dart uses an adaptive expiry window for pending delta requests, scaled between roughly 2 and 30 seconds based on measured round-trip time. kt uses a fixed 5-second expiry. | Dart, converging | Already being closed — kt's sync-path-depth batch (KT-B) is the vehicle; see `docs/plans/2026-08-29-kt-batch-b-sync-depth.md` in the gossip-kt repository. No separate action needed here beyond the record. |

## Related

- Source material: the wire-codec batch's ledger
  (`.superpowers/sdd/2026-08-29-wire-codec-batch/progress.md`) and the
  reviews it summarizes, plus the wire-versioning spec
  (`docs/superpowers/specs/2026-08-28-wire-versioning.md`, §5.2) and the
  Kotlin port fix inventory
  (`docs/superpowers/specs/2026-08-28-kt-port-dart-fix-inventory.md`, item
  13).
- Parent campaign: [Teach both libraries to speak versioned wire formats](kt-wire-versioning-campaign.md).
- Siblings: [Audit the Kotlin library for the bug classes fixed in Dart](kt-audit-legacy-bug-classes.md),
  [Port the wire-efficiency behaviors to the Kotlin library](kt-port-wire-efficiency.md),
  [Mirror the bounded-context structure in the Kotlin library](kt-mirror-bounded-contexts.md),
  [Coalesce wire traffic into fewer radio wakeups](engine-message-coalescing.md).
