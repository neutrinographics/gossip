# Kotlin domain purification — rulings for review

One kt batch executing
[Purify the Kotlin domain layer: locks move to infrastructure wrappers](../../backlog/kt-pure-domain-concurrency.md).
The item carries the what/why; this page carries only the decisions that
need the owner's eye, made against gossip-kt `main` @ 0dafefd. The
implementation plan (`gossip-kt/docs/plans/2026-09-02-kt-domain-purification.md`)
is execution material for the agents — not for review.

Behavior-preserving throughout: no wire change, no timing change, the
existing suite is the harness. What changes is *where* every lock lives.

## The inventory the rulings are made against

Every lock outside an `infrastructure/` package in `src/main` today:

| Site | Layer | Guards | Ruling |
|------|-------|--------|--------|
| `PendingPullTracker` monitor | domain | pending map, its RTT tracker | pure class + `SynchronizedPendingPullTracker` |
| `GossipTimingPolicy` monitor | domain | pacer, cached adaptive base | pure class + `SynchronizedGossipTimingPolicy`; absorbs the round news flag (ruling 7) |
| `ProbeTimingPolicy` monitor | domain | pacer | pure class + `SynchronizedProbeTimingPolicy`; the detector's RTT tracker joins it (ruling 6) |
| `HlcClock` `Mutex` | domain | clock state | pure class + `SynchronizedHlcClock`; operations stop suspending (ruling 5) |
| `GenerationScheduler` monitor | domain | generation counter, running flag | state/mechanism split (ruling 4) |
| `GossipEngine._newsLock` | application | news flag **and** the pacer transition, as one | folded into the timing policy (ruling 7) |
| `GossipEngine._reportedGapsLock` | application | reported-gap dedup set | `ReportedGapRegistry` (sync/domain/aggregates) + wrapper |
| `FailureDetector._probeBookkeepingLock` | application | probing holds, last-attempt clock, sequence counter, pending pings | `ProbeTargetSelector` + `PendingPingRegistry`, each wrapped (ruling 6) |
| `FailureDetector._rttTracker` (unguarded) | application | the global RTT estimate | under the probe-timing wrapper (ruling 6) |
| `ReactivePusher` monitor | application | debounce buffer, flush flag, generation | `PendingPushes` (sync/domain/aggregates) + wrapper (ruling 2) |
| `ChannelService.appendLocks`, `MaterializationService` mutex + concurrent map | application | critical sections that suspend across repository IO | **exempt** (E3), allow-listed by name |

## Rulings

1. **The sweep is complete and machine-checked.** A new
   `architecture/LockPlacementTest` scans `src/main` for `synchronized(`,
   `Mutex(`, `ReentrantLock`, `Atomic*`, `ConcurrentHashMap`, and
   `@Volatile` and fails on any hit outside a `*/infrastructure/` package,
   except an explicit allow-list carrying a rationale per row — the
   `BoundaryTest` accepted-debt idiom, including "a row no longer needed
   fails too". Exemption E3 stops being prose and becomes a test.
2. **Application-layer monitors are in scope, not just the five domain
   services.** The engine's news lock and the pusher's monitor have the
   exact shape the ruling forbids (in-place guarded state that is pure
   in-memory work); leaving them would make E3's narrowed wording untrue
   the day it is machine-checked. The pusher's extraction (`PendingPushes`:
   buffer an entry and learn whether a flush is due; drain if the
   generation is still live; invalidate) is the batch's last task and can
   be struck by the owner without affecting the rest.
3. **One wrapper shape, one lock discipline.** Every wrapper is
   composition over the pure class with the same public surface (the
   `SynchronizedStalledRangeRegistry` template; the one exception, and
   why, is ruling 4), lives in its context's
   `infrastructure/` package, and is a **plain monitor** — every wrapped
   section is non-suspending in-memory work, and several are reached from
   the non-suspend lifecycle facade, the constraint the pull tracker
   documented. Invariant, stated in each wrapper's KDoc and honoured by
   construction: **a wrapper never calls another wrapper, a port, or a
   callback while holding its monitor.** No monitor is ever nested in
   another, so there is no lock order to get wrong. `SynchronizedPeerRegistry`
   (a `Mutex`) is untouched.
4. **The scheduler splits state from mechanism.** `GenerationScheduler`
   keeps the coroutine mechanism (scope, launch, delay, tick — the scope is
   E3-exempt) and loses its lock; the supersession state (generation
   counter, running flag, `start()`/`stop()`/`isLive(gen)`/`expire(gen)`)
   becomes a pure `LoopGeneration` in `shared/domain/services`, wrapped by
   `SynchronizedLoopGeneration` in `shared/infrastructure`. Because the
   consumer is itself a domain class it cannot name the infrastructure
   wrapper, so `LoopGeneration` is an `open` class and the wrapper
   subclasses it, overriding every member under the monitor; a reflection
   test pins that every public member is overridden. (The alternative — a
   kt-only domain interface whose sole job is typing — was judged worse: a
   type nobody reads.) The scheduler takes its `LoopGeneration` as a
   **required** constructor argument, no default: a pure default would be
   the unsafe one, and all three construction sites (both engines, the
   compaction loop) pass the synchronized instance explicitly. Dart
   companion: the same split is a flow-back candidate; once adopted, the
   scheduler bodies diff line-for-line.
5. **The clock stops suspending, all the way up.** The pure `HlcClock` is
   Dart's, line for line, with non-suspend `now`/`receive`/`current`/`restore`.
   `SynchronizedHlcClock` implements `HlcProvider`, whose `now()` and
   `current()` **lose `suspend`** — a public API change, source-compatible
   for every caller (a suspend context calls a plain function freely) and
   breaking only for implementors, of which there are none outside this
   repo (`gossip-kt-testing` and the server were checked). The engine and
   coordinator hold the wrapper.
6. **The detector extraction rides here, not the lifecycle batch.** The
   wire-efficiency review already serialized the ping bookkeeping under one
   monitor, so the extraction is now mechanical, and the lifecycle batch's
   rulings are still unreviewed. Two pure classes replace the guarded
   fields:
   - `ProbeTargetSelector` in `membership/domain/services` — Dart's name
     and home, holding the probing holds, the last-attempt clock, and the
     unreachable-cycle index. kt adaptation: the probable-peer list and
     `nowMs` are passed in, because kt's registry reads suspend and time
     is data (the same adaptation `GossipTimingPolicy` already records).
     **Behavior unchanged**: the random pick stays; Dart's shuffled cursor
     remains the behavior half of the
     [probe-selection item](../../backlog/kt-probe-selection-parity.md),
     whose structural half this closes.
   - `PendingPingRegistry` in `membership/application` — pure, lock-free,
     owning sequence allocation and the pending map. It is
     application-layer, not domain, because `PendingPing` carries the ack
     signal (a `CompletableDeferred`), which has no business in the domain;
     its wrapper still lives in `membership/infrastructure`.

   The detector's global `RttTracker` is written by the receive path and
   read by the scheduler's `nextDelay` with no guard today — the race the
   lifecycle rulings noticed. It goes under `SynchronizedProbeTimingPolicy`,
   which takes the policy *and* its tracker and exposes `recordRtt`; the
   pure policy stays Dart's. The unused `FailureDetector.rttTracker` getter
   is removed rather than leaking unguarded state. Lifecycle ruling 2 is
   **superseded**: its "guard the detector bookkeeping" step becomes
   verify-only, and the relay deletion touches fewer sites.
7. **The round news flag moves into `GossipTimingPolicy`.** `news()` also
   raises it; a new `beginRound()` consumes it (hold the active cadence) or
   calls `quietRound()` (stretch). The flag and the pacer must move as one —
   that is what the engine's lock existed for — and inside the pure policy
   they do so under the policy wrapper's monitor with no engine-side lock.
   Dart's engine inlines the same three lines; moving them is a flow-back
   candidate.
8. **Docs duties for the closing truth pass.** E3 gains "machine-checked by
   `LockPlacementTest`"; the register's superseded KT-B row closes with the
   batch SHA; the lifecycle rulings page records ruling 6's amendment; the
   [flow-backs item](../../backlog/health-adopt-kt-flow-backs.md) gains
   four candidates (news flag into the policy, the `LoopGeneration` split,
   `ReportedGapRegistry` — Dart keeps that set inside `DeltaMerger` — and
   `PendingPushes`); and the
   [Dart reshape item](../../backlog/health-pure-runtime-trackers.md)
   records that kt's `PendingPullTracker` keeps today's port-holding shape
   until Dart reshapes it, so kt follows Dart there rather than pre-empting.
9. **Public API delta, in full.** `HlcProvider` non-suspend (ruling 5);
   `HlcClock` methods non-suspend; `GossipEngine` takes a
   `SynchronizedHlcClock`; `GenerationScheduler` gains a required
   `generation` parameter; `FailureDetector.rttTracker` removed. Everything
   else is internal composition. The server touches none of these (checked).
10. **Proof.** The existing suite green, unchanged in count except where a
    test moves with its subject (the clock's concurrency test moves to the
    wrapper's suite). New: one test class per wrapper — delegation for all,
    a real multi-thread hammer for the four on hot boundaries (pull tracker,
    clock, loop generation, ping registry); the reflection pin for
    `SynchronizedLoopGeneration`; `LockPlacementTest`. Every translated or
    moved test keeps its source citation.

Estimated suite growth: 999 → ~1040, on a branch off gossip-kt `main`
@ 0dafefd. Ships via the next opendoor-api submodule bump like every kt
batch.

## Review outcome

- 2026-09-02: **approved by the owner as written** — all ten rulings stand,
  including the scheduler's subclass wrapper (ruling 4) and the
  non-suspend `HlcProvider` (ruling 5). The plan follows this record.
- 2026-09-02: **built and reviewed** — gossip-kt PR #7
  (`feature/domain-purification`, branch head 03aa7ce), suite 999 → 1038,
  every task reviewed, final whole-branch review + one fix wave re-reviewed
  clean; awaiting the owner's merge. Ruling 2's strikeable task (the pusher)
  was **executed**. One carve-out to ruling 3 recorded in the code and in
  E3: the clock's and pull tracker's wrappers read `TimePort.nowMs` under
  their monitors — a leaf, non-reentrant port read kept so the pure classes
  stay Dart's; a time port that re-enters or calls out on read is forbidden
  by the wrappers' KDoc.
