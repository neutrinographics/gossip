# Receive-loop lifecycle batch — rulings for review

One kt batch covering three roadmap items:
[coordinator restart lifecycle](../../backlog/kt-coordinator-restart-lifecycle.md),
[inert indirect probing](../../backlog/kt-swim-indirect-probing-inert.md), and
[swallowed cancellation](../../backlog/kt-cancellation-swallowed.md) (which its
own item says to fold in — the same call sites get restructured). Those three
items carry the what/why; this page carries only the decisions that need the
owner's eye. The implementation plan
(`gossip-kt/docs/plans/2026-09-01-kt-receive-loop-lifecycle.md`) is execution
material for the agents — not for review.

Acceptance is fixed in advance: the **seven Dart scenarios withheld during the
scenario batch** (three restart/recovery, three pause/resume/multi-cycle, one
relay-keeps-both-views-reachable), translated as the batch's proof.

## Rulings

1. **The single-collector invariant stays.** Only `PingReq` relaying leaves
   the collector (a child coroutine) — it is the sole handler that awaits a
   reply which must arrive *through* the collector it would otherwise block.
   Rejected: making all detection dispatch concurrent (Dart's effective
   shape) — a bigger invariant change than the defect requires.
2. **The detector's ping bookkeeping gets a monitor guard.** Required by
   ruling 1 — and it closes confirmed *pre-existing* races: the sequence
   counter, pending-ping map, probing-hold map, and RTT tracker are already
   touched from both the probe timer and the receive loop today. Follows the
   recorded "monitor-guarded kt domain services" rule.
3. **Lifecycle contract = Dart parity.** `stop()` cancels the receive loop;
   `pause()` keeps it and gates *ingestion* engine-side (a paused node
   serves digests, entries, and pings but absorbs nothing, catching up via
   anti-entropy after resume); serving a delta request stays ungated. kt
   keeps no `resume()` — `start()` doubles as resume and must reuse the live
   collector. (Proposed exemption E5 in the [parity program](../../parity.md).)
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
7. **Not in this batch:** Dart's adaptive per-target relay timeout (kt keeps
   the fixed 500 ms; register row — Dart's is better on BLE) and Dart's
   lifecycle-epoch guard (kt's `start()` has no awaited gap that needs it).
8. **This batch is not KT-E.** The legacy sweep (entry insertion total order,
   HLC ceiling naming, etc.) keeps that name and follows separately.

Estimated suite growth: 938 → ~953, on a branch off gossip-kt `main` @ 33772f7.

## Review outcome

_Pending owner review. Record rulings changes here; the plan follows the
record, not the other way around._
