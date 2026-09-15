# Receive-loop lifecycle batch — rulings for review

One kt batch covering three roadmap items:
[coordinator restart lifecycle](../../backlog/kt-coordinator-restart-lifecycle.md),
the Kotlin half of [retiring indirect probing](../../backlog/kt-retire-indirect-probing.md)
(absorbed here per the [retirement ruling](2026-09-01-swim-slimdown-decision.md)), and
[swallowed cancellation](../../backlog/kt-cancellation-swallowed.md) (which its
own item says to fold in — the same call sites get restructured). Those
items carry the what/why; this page carries only the decisions that need the
owner's eye. The implementation plan
(`gossip-kt/docs/superpowers/plans/2026-09-01-kt-receive-loop-lifecycle.md`) is execution
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
2. *(Superseded 2026-09-02 by the [purification rulings](2026-09-02-kt-domain-purification-rulings.md), ruling 6: the ping bookkeeping is now `PendingPingRegistry` + `ProbeTargetSelector` behind `Synchronized*` wrappers, and the detector carries no lock; the plan's T4 step 3 becomes verify-only.)* **The detector's ping bookkeeping gets a monitor guard anyway.** The
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
6. **Cancellation carve-outs at the five surviving suspend-carrying
   catch-alls** *(amended 2026-09-14; was "nine")*: the coordinator's
   collector, the detector's send, the engine's send and clock-persist, and
   the compaction pass (whose swallow defeats the scheduler's correct
   rethrow one frame up — and repeats once per remaining stream per tick).
   The two scheduler-callback sites the original count included vanished
   with `GenerationScheduler`; the two codec decode catches are non-suspend
   and cannot see a cancellation, so they are left alone. Wire bytes
   untouched; no codec file is edited.
7. **Dart's lifecycle-epoch guard IS ported** *(reversed 2026-09-14)*. The
   original ruling said kt's `start()` has no awaited gap that needs it;
   ruling 4's cancel-and-join is exactly such a gap. `stop()` and
   `dispose()` bump an epoch; a `start()` that resumes from the join to
   find the epoch changed, the state running, or the coordinator disposed
   stands down. *(The former first half of this ruling — porting Dart's
   adaptive relay timeout — is void: the relay is retired.)*
8. **This batch is not KT-E.** The legacy sweep (entry insertion total order,
   HLC ceiling naming, etc.) keeps that name and follows separately.
9. **Kotlin goes first on the relay retirement** (owner, 2026-09-14). The
   decision record's "Dart first" sequencing and the roadmap's gate are
   amended; the wire is safe either way (a kt node that ignores a relay
   request looks like "no intermediary" to a Dart prober), the server is
   where the stall hurts, and the Dart half has no plan yet. The Dart half
   stays tracked on the same both-sides item.
10. **Lifecycle preconditions are Dart's, throwing** (owner, 2026-09-14):
    `pause()` throws unless running; `resume()` throws unless paused;
    `start()` and `stop()` throw when disposed and are otherwise
    idempotent; `dispose()` is idempotent. Lifecycle methods are **not
    thread-safe; the caller serializes them** — documented on the class,
    not enforced (the server calls start once and stop once with no
    overlap). Ruling 3's "contract = Dart parity" is thereby contract
    parity, not only vocabulary parity.
11. **The ack-sender guard is ported.** Dart completes a pending ping only
    when the Ack's sender is the probed target; kt matched by sequence
    alone. After retirement every pending ping is direct, so the guard is
    unconditional and this batch is the moment to add it.
12. **Two small kt-side choices, recorded as flow-back candidates:** the
    grace window after a direct timeout *races* the late Ack instead of
    sleeping blind (same outcome, less latency); and an inbound `PingReq`,
    though ignored, still counts toward the sender's receive metrics (owner,
    2026-09-14 — Dart counts every received frame, so the fleet's metrics
    stay comparable during the mixed period).

Estimated suite growth: 1046 → ~1060, on a branch off gossip-kt `main`
@ 83ec65a *(re-baselined 2026-09-14; was 938 → ~950 off 33772f7)*.

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
- 2026-09-02: ruling 2 superseded by the purification batch (gossip-kt
  PR #7) — the detector's bookkeeping is extracted and wrapped, not
  monitor-guarded in place; the relay deletion now touches fewer sites.
- 2026-09-14: **plan audited before execution**
  ([audit of record](../../audits/2026-09-14-receive-loop-lifecycle-plan-audit.md)):
  six Majors, none Critical. The owner ruled the four open points as
  recommended — rulings 9–12 added, 6 and 7 amended in place — and the
  plan was rewritten against gossip-kt 83ec65a (stale anchors, a
  monitor-guard step that would now fail `LockPlacementTest`, red tests
  that could never turn red, and a doc-truth task contradicting rulings 1
  and 3). All twelve rulings stand; the batch may start.
- 2026-09-15: **shipped** — gossip-kt ea0d51c (PR #8, real merge of
  `feature/receive-loop-lifecycle`, nine commits), suite 1046 → 1067. All
  twelve rulings executed as written; none bent. Two invariants were added
  beyond the rulings by the automated review passes on the PR: the engines'
  running flags come up before the receive collector attaches (a frame
  routed in the gap would be dropped by ruling 4's gates), and the simulated
  clock refuses a delay requested after it closes. One consequence recorded
  in the register: ruling 6's non-cancellable append-and-notify pair also
  makes the merged-entries fold uninterruptible by `stop()`. Deferred minor
  findings live on
  [the follow-ups item](../../backlog/kt-lifecycle-batch-follow-ups.md).
