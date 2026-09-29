# Dart half: the round can be woken, and a pull is a request with identity — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the Dart twin (`packages/gossip`) level with gossip-kt on two approved rulings pages: news wakes a sleeping gossip round, and a pull is a request with identity, correlated by reference with the bridge's content rule kept only as an explicitly transitional legacy policy. The Dart pending-pull tracker becomes a value in the process.

**Architecture:** Same shapes as the Kotlin half, in Dart's layout. `shared/domain/value_objects/generation.dart` (value) + `shared/domain/services/loop_generation.dart` (pure transitions) sit beside the existing `GenerationScheduler`, which keeps one `Generation` field and gains `wake()`; `TimePort` gains `monotonicMs`. `sync/domain/value_objects/request_id.dart`, `sync/domain/entities/pull_request.dart`, `sync/domain/aggregates/outstanding_pulls.dart` (value), `sync/domain/services/outstanding_pull_tracker.dart` (pure) and `sync/domain/services/legacy_correlation.dart` (pure, transitional). The engine holds one `OutstandingPulls` field (single isolate: no cell, no lock) and applies transitions. Both wire emissions carry `requestId`/`inReplyTo` flat. `PendingPullTracker` is deleted.

**Tech Stack:** Dart 3.13, `package:test`, `dart analyze` (zero issues), Melos monorepo (`packages/gossip` only in this plan).

**Specs:** `docs/superpowers/specs/2026-09-27-round-wake-rulings.md` (with its Precisions), `docs/superpowers/specs/2026-09-28-response-correlation-rulings.md` (superseded parts marked), `docs/superpowers/specs/2026-09-29-pull-request-identity-rulings.md` (with its Precisions — they override ruling text where they say so). Kotlin reference: gossip-kt `main` @ c8dde6f (`sync/domain/{values,entities,aggregates,services}`, `shared/domain/services/LoopGeneration.kt`, `shared/infrastructure/GenerationScheduler.kt`, `sync/infrastructure/SyncWireV2.kt`) — mirror its names and its pins' claims; do not copy its prose.

## Global Constraints

- Pure domain: nothing new under `domain/` holds a `TimePort`, a `Timer`, or mutable state except the one documented exception below; `nowMs`/`monotonicMs` are readings the caller takes and passes in.
- The one exception, already recorded on the register: `GenerationScheduler` (Dart) keeps its own timer state until the port-and-adapter flow-back lands; it keeps it as ONE `Generation` field moved only by `LoopGeneration`'s transitions.
- Single isolate: the engine holds `OutstandingPulls` in one private field and replaces it whole per transition; no `await` between reading it and writing it (the Dart tracker's existing "no await between check and mark" rule carries over).
- Boundary rule (`test/architecture/boundary_test.dart`): sync imports shared and itself; nothing new reaches membership.
- Doc comments state contract and why, never steps; no retired names (`PendingPullTracker`, `_pendingSince`, `tryMark`, `markContinuation`, `complete(` as the tracker's) outside the deletion commit's own message.
- Gate per task: `cd packages/gossip && dart test` all passing (baseline 1,267) and `dart analyze` "No issues found"; never commit red. Before the PR: the adverse harness's stalled-range and churn-shaped tests ten clean runs of ten.
- Every whole-branch review carries a timing table of side effects against `main`.
- gossip `main` is ~80 docs commits ahead of `origin/main` (owner's call); the branch is off local `main`. Before the PR opens, the owner pushes `main` or accepts the PR showing those commits — ask once, at PR time.

---

### Task 1: The rule on the value, the monotonic reading, and the wake

**Files:**
- Create: `packages/gossip/lib/src/shared/domain/value_objects/generation.dart` — `class Generation { final int number; final bool running; final int? waitEndsAtMs; }` immutable, `==`/`hashCode`, `static const initial = Generation(number: 0, running: false)`.
- Create: `packages/gossip/lib/src/shared/domain/services/loop_generation.dart` — pure functions: `start(g) → (Generation state, int number)`, `stop(g)`, `isLive(g, gen)`, `expire(g, gen)`, `arm(g, endsAtMs)` (requires running), `ticking(g)`, `wake(g, nowMs, freshDelayMs) → (Generation state, int? cutShortAtMs)` — re-arm iff `running && waitEndsAtMs != null && waitEndsAtMs > nowMs + freshDelayMs`, the result naming the end it cut short.
- Modify: `packages/gossip/lib/src/shared/domain/interfaces/time_port.dart` — `int get monotonicMs;` (a reading that moves with `delay` and nothing else).
- Modify: `packages/gossip/lib/src/shared/infrastructure/real_time_port.dart` — `monotonicMs` from a `Stopwatch` started at construction (`elapsedMilliseconds`).
- Modify: `packages/gossip/lib/src/shared/infrastructure/in_memory_time_port.dart` — `monotonicMs => nowMs` (one simulated clock).
- Modify: `packages/gossip/lib/src/shared/domain/services/generation_scheduler.dart` — replace `_generation`/`_isRunning` with `Generation _state`; `start`/`stop`/`_scheduleNext` through `LoopGeneration`; `wake()`: read `(number, waitEndsAtMs)`; return if not running or no wait pending (no `nextDelay()` read); read `fresh = nextDelay()` (a non-positive delay is a scheduling failure: expire that generation, report `onSchedulingError`, return); `nowMs = timePort.monotonicMs`; decide with `LoopGeneration.wake` ONLY if the state still holds the same number and wait end (a stop/start or a reschedule in between makes the readings about nothing); on re-arm, `_scheduleNext(newGen, decided: fresh, noLaterThanMs: cutShortAtMs)`. `_scheduleNext` computes `delay = decided ?? nextDelay()`, bounds it `min(delay, noLaterThan - monotonicMs)` floored at 1 ms when a bound is given, records `arm(endsAtMs = monotonicMs + delay)` and calls `timePort.delay(delay)` in the same synchronous run (Dart registers the delay at the call — no hop), and on resumption does the liveness check and `ticking` as one step.
- Test: `packages/gossip/test/shared/domain/services/loop_generation_test.dart` (new: purity sweep + arm/ticking/wake cases incl. the exact-horizon edge), `generation_scheduler_test.dart` (the five spec pins + one-draw + bound + throwing/zero `nextDelay` + stale-reading no-op), `test/shared/infrastructure/*time_port*` (monotonicMs; a wall-clock skew does not move it).

- [ ] Write the failing tests (claims as the kt pins: `wake cuts short a wait that would outlast a fresh interval`; `wake leaves a wait already shorter alone`; `wake does nothing while no loop is running`; `wake during an in-flight tick leaves the loop to its own reschedule` and reads no interval; `a stop landing inside wake leaves the loop stopped`; `a wake arms the delay it decided with, not a second draw`; `a wake that pauses between reading the clock and deciding never ends later than the wait it cut short`; `a wall clock set forward during a wait does not stop a wake from cutting it short`; `a nextDelay of no time at all is a scheduling failure`).
- [ ] Run `dart test test/shared` — FAIL. Implement. Run — PASS; `dart analyze` clean.
- [ ] Commit `feat(shared): a sleeping loop can be woken — the rule on the Generation value, the adapter executes it`.

### Task 2: News wakes the round

**Files:**
- Modify: `packages/gossip/lib/src/sync/application/gossip_engine.dart` — `_recordNews()` calls `_timing.news()` then `_scheduler.wake()`; nothing else wakes the loop; the failure detector's probe loop is untouched.
- Test: `packages/gossip/test/sync/application/gossip_engine_pacing_test.dart` (or the interval-pacing file): a stretched pacer merges a delta → the next DigestRequest to another peer goes out within the active interval; the same for a local write; the round count per minute at active cadence is unchanged (use a non-jittering random or a tolerance, as kt's `UnjitteredRandom` pin does).
- [ ] Red → green → `dart analyze` → commit `feat(sync): news wakes the round`.
- Parity check for Task 7: the seven `_recordNews()` sites (local write, merge, delta request received, delta answered non-empty, pull sent, peer added/removed, sync with peer) against kt's seven — list each pair in the report.

### Task 3: The request, the aggregate, its transitions, and the transitional rule

**Files:**
- Create: `sync/domain/value_objects/request_id.dart` — `RequestId(String value)` with the identifier rule (non-blank; no control characters, quotes or backslashes; ≤ 64 UTF-8 bytes — Dart's other ids do not carry this rule today; note it in the report for a register row) and `RequestId.mint(issuedAtMs, sequence)` (base-36, opaque by contract).
- Create: `sync/domain/entities/pull_request.dart` — `PullRequest(id, peer, channelId, streamId, since, wanted, issuedAtMs, carrying = {})`, invariant `wanted ∪ carrying` non-empty; KDoc states the two transitional attributes (`wanted` narrowed by the legacy rule; `carrying` on a continuation).
- Create: `sync/domain/value_objects/correlation.dart` — `enum Correlation { unknown, legacy, byReference }` and `class Correlated { final AnsweredPull? answered; final Correlation? learned; }`.
- Create: `sync/domain/value_objects/answered_pull.dart` — `AnsweredPull(elapsedMs, remaining)`.
- Create: `sync/domain/aggregates/outstanding_pulls.dart` — `OutstandingPulls(requests: Map<RequestId, PullRequest> (issue order kept), peers: Map<NodeId, Correlation>, rtt: RttEstimate, sampleCount, nextSequence)`, `initial`.
- Create: `sync/domain/services/outstanding_pull_tracker.dart` — `effectiveTimeout(pulls)` (RFC-6298 over `RttEstimate`, min/max as the deleted tracker's), `isOutstanding`, `issueUnlessOutstanding` (evicts that key's expired requests), `issue(..., carrying)`, `release(id)`, `answer(pulls, sender, inReplyTo, channel, stream, firstByAuthor, floor, hasMore, nowMs) → (OutstandingPulls, Correlated)` — by reference (peer AND channel AND stream must match; unknown id → push; flips the peer to byReference, `learned` on change) else byReference peer → push, else `LegacyCorrelation.answer`; `clearAll` (keeps rtt, peers, nextSequence), `clearForPeer` (drops its fact), `clearForChannel`.
- Create: `sync/domain/services/legacy_correlation.dart` — TRANSITIONAL (says so): `answers`, `addressed`, `answer` (oldest live request first by `issuedAtMs`; begins-where-asked for every carried author; speaks to the request: a wanted author carried or floored past `since`, or a carried author; empty response answers; retire on all-accounted / empty / `hasMore`, narrow otherwise; RTT sampled only on a whole retirement).
- Test: `test/sync/domain/services/outstanding_pull_tracker_test.dart` and `legacy_correlation_test.dart` — every claim of the kt classes (Task 1/2 reviews' lists) plus the Dart tracker's 19 pins re-homed.
- [ ] Red → green → analyze → commit `feat(sync): a pull is a request with identity — OutstandingPulls, its transitions, and the transitional content rule`.

### Task 4: The wire carries the identity, and the cap pays for it

**Files:**
- Modify: `sync/domain/messages/delta_request.dart` (`RequestId? requestId`), `delta_response.dart` (`RequestId? inReplyTo`) — last, optional.
- Modify: `sync/infrastructure/sync_message_codec.dart` — `_encodeDeltaRequest` emits `requestId` when non-null; both emissions' `deltaResponseJson` emit `inReplyTo` when non-null (flat, both dialects — Dart's v1 is flat); decode absent → null; `maxEntryPayloadForBudget` subtracts the reply identity's maximal cost `15 + 64` on BOTH Dart dialects before the ratio (Dart's v1 is flat, unlike kt's batched v1, so its cost is v2's: state this on the constant). Defaults at 30 KiB: v1 → 7532, v2 → 22596.
- Test: codec round-trip both dialects; absent → no key, null on decode; a frame carrying the keys decodes (tolerance pinned); the budget test's maximal message names its request with a 64-byte id and fits; the cap pins derive the number; `RequestId` over the bound refused.
- [ ] Red → green → analyze → commit `feat(sync): requests carry their identity on the wire, answers echo it; each dialect pays for the echo`.

### Task 5: The application issues, sends, echoes, correlates

**Files:**
- Modify: `sync/application/gossip_engine.dart` — `OutstandingPulls _pulls = OutstandingPulls.initial`; the pull planner path: cheap `isOutstanding` early exit → shape `since` as today → `wanted = digest authors above since` → `issueUnlessOutstanding` (no await between) → return the `PullRequest` (the send seam builds `DeltaRequest(..., requestId: request.id)`); `_sendDeltaRequests(recipient, List<PullRequest>)`: on refusal `release(request.id)`; `handleDeltaRequest` answers with `inReplyTo: request.requestId`; the reactive push (`_flushPendingPushes`) leaves it null; `handleDeltaResponse`: one `answer(...)` transition → INFO once per learned fact (`peer X answers by reference` / `peer X answers without a reference; correlated by content (legacy)`) → `_merger.merge(response, answered: correlated.answered)`; `clearPendingRequests`/`ForPeer`/`clearPendingFor` → the new transitions; the `outstandingPullCount`/`effectiveTimeout` getters read the value.
- Modify: `sync/application/delta_merger.dart` — `merge(response, {required AnsweredPull? answered})`; `solicited = answered != null`; a continuation ONLY when `answered != null` (an unasked `hasMore` page spawns none — log at trace); `onContinuationIssued(peer, channel, stream, since, wanted, carrying) → PullRequest` returns the request the engine issued; the merger returns `continuation: PullRequest?` and the engine's send seam builds the frame.
- Tests: `gossip_engine_*_test.dart` — the bridge-equivalent claims as LEGACY-peer pins (racing push of an unwanted author; own push at tip answers that author only; true answer completes with floor; paged two-author; three-page drain continuing an author; unasked `hasMore` → no continuation frame; refused continuation releases only itself); BY_REFERENCE pins (named answer whatever it carries → hole is a stall; unknown id → push; reference-less from a byReference peer → push; INFO once per peer; `requestId` on every pull frame, `inReplyTo` on every answer, never on a push); `test/integration/adverse/stalled_range_suppression_test.dart` — the no-floor front-truncation pin re-homed (under identity the answer IS the answer; one diagnosis, one probe in 40 s).
- [ ] Red → green → analyze → the adverse suite 3× → commit `feat(sync): pulls are issued with identity, answered by reference, continued only when answered`.

### Task 6: Retire the tracker

- Delete `sync/domain/services/pending_pull_tracker.dart` and its test; sweep prose in `lib/` and `test/` (the engine's doc comments cite it at ~245–250, ~467–476, ~1319, ~1587); gossip `CLAUDE.md`'s core-package notes if they name it. `dart analyze` + full suite + adverse 10×.
- [ ] Commit `refactor(sync): the pending-pull tracker retired — the aggregate is OutstandingPulls`.

### Task 7: Docs

- gossip `CLAUDE.md` (core package section): the scheduler can be woken; a pull is a request with identity; `LegacyCorrelation` transitional.
- Register (`docs/backlog/kt-normalize-twin-divergences.md`): close the rows "News wakes the round" and "A pull is a request with identity" as parity with the PR; correct the Dart cap in the identity row (v1-dart flat → 7532; v2 → 22596); the news-site parity result (seven for seven, or the difference as its own row); "The transitional content rule and its deletion" gains Dart's half; a row for Dart's identifier bound if `RequestId` is the only Dart id carrying it; a row for the app's `ProtocolTranslator` needing to carry `requestId`/`inReplyTo` across the v1-dart↔v1-kt bridge (flat ↔ batched), homed to the app pin bump — without it the server never sees a phone answer by reference.
- `docs/roadmap.md`: the round-wake item ◐ → Dart half landed; the correlation item line; `docs/backlog/engine-news-wakes-the-round.md` and `engine-response-correlation.md` Related lines; both rulings pages' status lines.
- OpenDoorApp: a backlog item for the translator change + the pin bump (owner's repo; write it when asked or at the pin bump).
- [ ] Commit `docs: Dart half of the round-wake fix and the pull-identity re-model landed`.

**After this plan:** whole-branch review with the timing table → PR (owner pushes `main` first, or accepts the docs commits in the diff) → OpenDoorApp: `ProtocolTranslator` carries the two keys across the bridge + pin bump + live-device validation (a phone on the new pin should make the server log `answers by reference`) → the legacy rule's deletion in both twins when the criterion is met.

---

## Self-review

- **Spec coverage.** Round-wake rulings 1–3 + Precisions (monotonic; one draw; bound; three-part binding; no interval read without a wait; zero delay = failure; arm-and-take in one run) → Task 1; ruling 2 (news wakes) → Task 2; parity (seven sites) → Task 2 report + Task 7. Identity rulings 1–5 + Precisions (identifier rule; per-dialect cost; stream-bound reference; expired requests no legacy candidates; `carrying`) → Tasks 3–5; ruling 6 (INFO counter) → Task 5; ruling 7 (order) → "After this plan"; the Dart tracker as a value → Task 3/6.
- **Placeholders.** Names and claims stated; exact Dart signatures are the implementer's to shape in Dart idiom (records for transitions), reported per task.
- **Type consistency.** `Generation`/`LoopGeneration` (T1) drive `GenerationScheduler.wake()` (T1) called from `_recordNews()` (T2). `RequestId` (T3) rides `DeltaRequest.requestId`/`DeltaResponse.inReplyTo` (T4) and `release`/`answer` (T3, T5). `AnsweredPull`/`Correlated` (T3) are what the engine logs and merges from (T5). `PullRequest` (T3) is what the planner returns and the send seam frames (T5).
