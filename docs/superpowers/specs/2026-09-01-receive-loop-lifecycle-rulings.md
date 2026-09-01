# Receive-loop lifecycle batch — rulings for review

One kt batch covering three roadmap items:
[coordinator restart lifecycle](../../backlog/kt-coordinator-restart-lifecycle.md),
the Kotlin half of [retiring indirect probing](../../backlog/kt-retire-indirect-probing.md)
(absorbed here per the [retirement ruling](2026-09-01-swim-slimdown-decision.md)), and
[swallowed cancellation](../../backlog/kt-cancellation-swallowed.md) (which its
own item says to fold in — the same call sites get restructured). Those
items carry the what/why; this page carries only the decisions that need the
owner's eye. The implementation plan
(`gossip-kt/docs/plans/2026-09-01-kt-receive-loop-lifecycle.md`) is execution
material for the agents — not for review.

Acceptance is fixed in advance: the **six Dart lifecycle scenarios withheld
during the scenario batch** (three restart/recovery, three
pause/resume/multi-cycle), translated as the batch's proof. The seventh
withheld scenario (relay reachability) is obsolete under the retirement
ruling — it pinned removed behavior.

## Rulings

1. **The single-collector invariant stays — untouched.** (Amended by the
   [retirement ruling](2026-09-01-swim-slimdown-decision.md): the original
   ruling here launched `PingReq` relaying off the collector, the sole
   handler that awaits a reply arriving through the collector it would
   block. With relaying retired, nothing needs to leave the collector at
   all — the batch instead *removes* `handlePingReq`, intermediary
   selection, and the relay timeout, and an inbound `PingReq` is decoded
   and ignored for mixed-fleet compatibility.)
2. **The detector's ping bookkeeping gets a monitor guard anyway.** The
   races it closes *pre-date and outlive* relaying: the sequence counter,
   pending-ping map, probing-hold map, and RTT tracker are touched from
   both the probe timer and the receive loop today. Follows the recorded
   "monitor-guarded kt domain services" rule.
3. **Lifecycle contract = Dart parity.** `stop()` cancels the receive loop;
   `pause()` keeps it and gates *ingestion* engine-side (a paused node
   serves digests, entries, and pings but absorbs nothing, catching up via
   anti-entropy after resume); serving a delta request stays ungated. kt
   **gains `resume()`** (owner ruling, 2026-09-01, reversing a drafted
   exemption): it delegates to the start path, so the pause/resume
   vocabulary matches Dart's; `start()` from paused keeps working and must
   reuse the live collector either way.
4. **One kt improvement over Dart:** `start()` waits out a still-unwinding
   cancelled collector before relaunching (free, since kt's `start()`
   suspends); Dart's cancel is fire-and-forget. Goes to the divergence
   register as a flow-back candidate.
5. **Injectable dispatcher, not injectable scope**, on `Coordinator.create` —
   tests gain deterministic control (and the subscribe-before-return pin the
   scenario batch had to defer) while the coordinator keeps sole ownership of
   its scope, so `dispose()` stays unambiguous.
6. **Cancellation carve-outs at nine sites, not the recorded six** — closer
   inspection found seven suspend-carrying catch-alls (including the
   compaction pass, whose swallow currently defeats the scheduler's correct
   rethrow one frame up) plus two codec decode catches taken along for idiom
   uniformity. Wire bytes untouched; golden vectors must stay byte-identical.
7. **Not in this batch:** Dart's lifecycle-epoch guard (kt's `start()` has
   no awaited gap that needs it). *(The former first half of this ruling —
   porting Dart's adaptive relay timeout — is void: the relay is retired.)*
8. **This batch is not KT-E.** The legacy sweep (entry insertion total order,
   HLC ceiling naming, etc.) keeps that name and follows separately.

Estimated suite growth: 938 → ~950 (net of tests deleted with the relay),
on a branch off gossip-kt `main` @ 33772f7.

## Review outcome

_Pending owner review. Record rulings changes here; the plan follows the
record, not the other way around._

- 2026-09-01: ruling 3 amended by the owner's review of the parity
  exemption register — kt gains `resume()` rather than exempting its
  absence. Remaining rulings still pending.
- 2026-09-01 (later the same day): the
  [indirect-probing retirement](2026-09-01-swim-slimdown-decision.md) was
  **ruled B, final** — rulings 1, 2, and 7 above are amended in place to
  their post-retirement form, the acceptance suite is six scenarios, and
  this batch absorbs the Kotlin-side removal.
