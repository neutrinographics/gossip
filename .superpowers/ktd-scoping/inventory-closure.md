# KT-D pre-planning: inventory closure verdicts (2026-08-30)

Scope: every numbered item of
`docs/superpowers/specs/2026-08-28-kt-port-dart-fix-inventory.md`, verified against
**gossip-kt `feature/compaction` @ fc4bec3** source (not the batch summaries).
Dart reference: gossip `working-connection`. All kt paths relative to
`/Users/joel/git/neutrinographics/gossip-kt/`, Dart paths to
`/Users/joel/git/neutrinographics/gossip/packages/gossip/`.

Verdicts: **CLOSED** (artifact verified at HEAD), **PARTIAL** (named sub-piece
remains), **OPEN** (nothing ported), **REASSIGNED** (routed elsewhere by ruling,
destination named).

---

## Per-item verdicts

### Item 1 — Compaction floor: storage contract — **CLOSED** (KT-A; monitor guard KT-C)

Evidence:
- Contract KDoc with all three monotonic marks and the "no surviving entries is NOT 0"
  invariant: `src/main/kotlin/com/neutrinographics/gossip/sync/domain/interfaces/EntryRepository.kt:24-45`
  (Critical Invariants), `:114` (`latestSequence`), `:146` (`getVersionVector`),
  `:159` (`getCompactionFloor`), `:179` (`adoptVersionFloor`).
- Impl: `sync/infrastructure/InMemoryEntryRepository.kt` — `latestSequenceCache` (`:49`),
  `compactionFloors`, all methods under one monitor (`lock`, `:35`, KT-C ruling 8).
  `removeEntries` raises the floor and *deliberately does not touch*
  `latestSequenceCache`, with the why-comment ported (`:143-177`, comment `:167-176`).
  `appendAll` validates the whole batch (store + intra-batch) before mutating,
  including the phantom-stream fix (validation precedes `getOrPut`) (`:73-106`).
- Pins: `gossip-kt-testing/src/main/kotlin/com/neutrinographics/gossip/testing/contract/EntryRepositoryContractTest.kt`
  — a full shared contract test (`:207-341` monotonic marks incl. "preserves high-water
  mark after removeEntries removes all author entries", "never below the compaction
  floor", "does not regress when compaction prunes"; `:343-441` floor + adoption).

Residual nits (not gaps): kt has `clearStream`/`clearChannel` but no `clearAll`
(interface surface, not behavior); the persistent-impl requirement now lands on the
server's `PgEntryRepository` — that's the owner-side precondition already registered in
`docs/backlog/kt-wire-versioning-campaign.md` (2026-08-30 audit rows).

### Item 2 — Late-joiner lockout fix: floor adoption — **CLOSED** (KT-B + wire batch)

Evidence:
- Responder computes full floor then the reportable portion at HANDLE time:
  `sync/application/GossipEngine.kt:308-338` (`reportableFloor`, `:332-338`; a
  floor-only response is sent even with zero entries, `:309`).
- Requester adopts only when solicited AND non-empty, BEFORE the contiguity filter,
  with the ordering comment ported: `GossipEngine.kt:381-401` (`solicited` decided by
  the caller's `PendingPullTracker.complete`, peer-keyed — stronger than sender's
  claim; `:87-88` doc). Unsolicited cannot move the floor (`:392-395`).
- Authorship-floor variant: `GossipEngine.kt:643-668` (`adoptClaimedAuthorshipFloor`).
- Repository primitive raises BOTH maps atomically, never regresses, never
  double-applies: `InMemoryEntryRepository.kt:205-231`.
- Wire: floor omitted when empty, defaults empty on decode; hasMore defaults false —
  `sync/infrastructure/SyncWireV2.kt:101-129`; v1 dialect too `SyncWireV1.kt:131-179`.
- Pins: `GossipEngineTest.kt:611` (solicited adopted), `:654` (unsolicited ignored),
  `:678` (never-asked peer can't piggyback on another peer's outstanding pull —
  *stronger than Dart's pin*), `:721`, `:765-859` (authorship-floor group incl.
  allocation-level assert), `:1605` (adoption-before-filter), `:1721` (below-floor
  re-offer not resurrected). Repo-level: contract test `:377-430` (raises both marks,
  ignores at-or-below, **idempotent**, **per-author independent**). Codec pins:
  `SyncMessageCodecTest.kt:560, :581`. Integration: see item 5.
- The mid-sync-race unit pin cited under this item's Dart tests is the one missing
  piece — tracked under item 5 below.

### Item 3 — Contiguity guard + gap reporting — **CLOSED** (KT-B)

Evidence: `GossipEngine.kt:94-96` (`ContiguityGap`/`ContiguitySelection`),
`:466-487` (`selectContiguousEntries`: per-author grouping+sorting, skip
already-held, stop at first break), `:503-` (`reportContiguityGaps`: solicited →
warning + `ChannelSyncError`, deduped per `(peer, channel, stream, author,
expectedNext)` via `_reportedGaps` `:107-122`; unsolicited → trace only, `:499`
comment), cleared on `stop`/`clearPendingRequests`/`clearPendingRequestsForPeer`
(`:160, :570-585`). Monitor-guarded (registered kt pattern, divergence register
thread-safety row).
Pins: `GossipEngineTest.kt:1358-1596` — the full Dart group translated (dedup
once-per-position `:1467`, new position re-reported `:1489`, unsolicited trace-only
`:1513`, per-peer window reopen `:1529`, fully-dropped batch no continuation `:1659`),
plus a gap-reopen pin Dart lacks (register "test-strength flow-backs" row).

### Item 4 — VV never regresses on compaction — **CLOSED** (KT-A)

Evidence: same mechanism as item 1; digest generation consumes the monotonic VV
(`GossipEngine.kt:557` builds `StreamDigest` from `entryRepository.getVersionVector`,
`:613, :664` on the request path). Pins: contract test `:302-341` (three explicit
non-regression pins); integration `TwoNodeCompactionTest.kt:213-224` (high-water mark
survives full compaction; new append allocates seq 4, peer accepts — the H6/sequence
-reuse scenario end-to-end).

### Item 5 — Transitive floors / returning peer / prune-all / mid-sync race — **PARTIAL**

Scenario-by-scenario against
`src/test/kotlin/com/neutrinographics/gossip/integration/`:

| Pinned Dart scenario | kt counterpart | Verdict |
|---|---|---|
| Late joiner vs compacted responder (lockout) | `CompactionLateJoinerTest.kt:115` (partially-compacted, content-checked) + `TwoNodeCompactionFloorTest.kt:127` (fully-compacted) + timer-driven variant `AutoCompactionFloorTest.kt:156` | **CLOSED** |
| Transitive floor propagation (A→B→C, C never talks to A) | `CompactionLateJoinerTest.kt:176`; the single-mechanism guarantee (adoption raises B's own *servable* floor) is explicitly pinned at `:219` and at `TwoNodeCompactionFloorTest.kt:183-189`; mechanism is atomic in `InMemoryEntryRepository.kt:205-231` | **CLOSED** |
| Returning peer below the floor (keeps own 1..3, adopts, pruned range absent, no error) | `CompactionLateJoinerTest.kt:254` | **CLOSED** — but note kt models the disconnect via `peers.remove()`/`add()` (state-scrubbing), not a true partition; already registered (divergence register "Partition primitive" row → campaign backlog future scope) |
| Prune-all then NEW appends (floor-only converged-empty peer accepts subsequent contiguous history) | `TwoNodeCompactionFloorTest.kt:127-221`: A fully compacts 3 entries, C joins after with zero entries, adopts a pure floor (`:162-199`), then A authors a NEW entry (seq 4) and C receives exactly it (`:202-212`), error sink asserted empty (`:214-221`). Uses TimeBased-total-prune rather than `CountBasedRetention(0)`, but the behavior contract (floor-only peer is not a dead end) is fully exercised; `CountBasedRetention(0)` legality is separately pinned (`RetentionPolicyTest.kt:202`) | **CLOSED** (shape differs, contract covered) |
| **Compaction landing mid-sync** (compact between request-send and request-handle; floor computed at handle time; no pending-dedup wedge) | **No kt test exists** — searched all of `src/test` for any compact-during-in-flight-request staging; nothing. The handle-time-floor property holds *by construction* (`reportableFloor` reads the repo at serve time, `GossipEngine.kt:332`), and pending-flag release paths have adjacent pins (`GossipEngineTest.kt:916, :959, :1318`), but the race itself — Dart's `group('compaction mid-sync race')` — is unpinned | **OPEN** — the genuine item-5 gap |

**"Known adjacent nuance" check (push scoping):** kt has **no reactive push path at
all** (no push-on-write/debounce anywhere in `src/main` — only inbound-unsolicited
handling). So the freeze-at-append vs recipients-at-flush question cannot arise
mechanically today — but **no deliberate decision is recorded on the kt side** (no
divergence-register row, no plan note; `docs/backlog/engine-push-scoping.md` is
Dart-only). The inventory asked for a deliberate decision, not an accidental absence.
Small doc-only KT-D item.

### Item 6 — OBS-3 digest budgeter cursor rotation — **REASSIGNED**

Nothing in kt: no `DigestBudgeter`, no cursors, no `maxMessageBytes`, no
`OversizedDigest` (verified by repo-wide grep). Explicitly routed by ruling:
`docs/backlog/kt-wire-versioning-campaign.md` campaign register rows **"Splitting
large answers into pages, and fitting summaries to a size budget, on the Kotlin
side"** and **"Rotating which summaries get sent when they don't all fit"** — "after
the format settles. The wire spec's out-of-scope section records the reassignment."
Sharing a surface with `docs/backlog/kt-port-wire-efficiency.md`. Do NOT pull into
KT-D.

### Item 7 — StreamCompacted event + auto-compaction loop — **CLOSED** (KT-C), one minor test gap

Evidence:
- `sync/application/ChannelService.kt:202-271` (`compactStream`: retention → remove →
  floor updated inside `removeEntries` → materializer reset by default (`:257-259`) →
  `StreamCompacted` only when `removed` non-empty (`:249` returns null early);
  `:282-307` (`compactAll`: pre-filters null-policy and `retainsAll` streams before
  loading entries, per-stream try/catch emitting `StorageSyncError` — COR3-15;
  unconfigured store is a silent no-op *by ruling 3*, deliberately diverging from
  `compactStream`'s error-emitting skip paths).
- `coordinator/Coordinator.kt:404-…` (loop on `GenerationScheduler`, lazily built,
  restart contract noted `:87-89`); `CoordinatorConfig.kt:34` (**default 5.minutes**),
  `:43-44` (null disables; non-positive REJECTED — deliberate, KT-C ruling 5,
  register row "Compaction-interval disable idiom"). kt runs the loop in local-only
  mode (always has a TimePort) — deliberate, ruling 6, register row.
- Event/result shapes: `StreamCompacted(channelId, streamId, removedCount, at)` and
  `CompactionResult(entriesRemoved, entriesRetained, bytesFreed)` — **no
  `baseVersion`**; ruled deliberate ("documented past decisions", KT-C ruling 7),
  consistent with the MIN-9/OBS-9 resolution (old/new base VVs provably equal).
- Pins: `ChannelServiceCompactAllTest.kt` (6 tests: prune across channels, retainsAll
  skip without loading, poison-stream isolation, silent no-op, compactStream-vs-
  compactAll error asymmetry, channel-deleted-mid-iteration);
  `CoordinatorAutoCompactionTest.kt` (interval prunes + emits StreamCompacted `:91`,
  pause/resume `:117`, null disables `:152`, dispose cancels cleanly `:179`);
  timer-driven crown `AutoCompactionFloorTest.kt:156`.

**Minor gap:** Dart's coordinator-level pin `'a delay failure emits exactly one
scheduling error and the loop stays dead until the next stop/start cycle'` has no kt
counterpart at the *coordinator* level — the asymmetric failure policy is pinned only
at scheduler level (`GenerationSchedulerTest.kt:169, :274`). KT-C ruling 9 chose "no
test seam on the Coordinator", which is why; a coordinator-level stays-dead pin would
need that ruling revisited or an InMemoryTimePort-driven staging.

### Item 8 — Retention policy validation — **CLOSED** (KT-A)

The Dart const/assert decision procedure was applied correctly for Kotlin: all three
built-ins use unconditional `require` in `init` (survives every JVM configuration —
`require` is not stripped):
`sync/domain/services/TimeBasedRetention.kt:17-18` (negative maxAge),
`CompositeRetention.kt:16-18` (empty list, with the union-of-nothing rationale),
`CountBasedRetention.kt:17-18` (negative count; zero legal). `retainsAll` added
(interface default false — `RetentionPolicy.kt:30`; KeepAll true, Composite any —
kinder-than-Dart default per KT-C ruling 4).
Pins: `RetentionPolicyTest.kt:170` (negative maxAge rejected), `:180` (zero maxAge
accepted), `:189` (empty composite rejected), `:195` (negative count rejected),
`:202` (**zero accepted and prunes every entry** — the prune-all-legality pin),
`:212-236` (retainsAll matrix).

### Item 9 — Duplicate appends throw — **CLOSED** (KT-A/KT-B)

Evidence: `InMemoryEntryRepository.kt:62-65` (`check` → `IllegalStateException`, with
the "sequence-allocation race loses an entry with no trace" comment ported), `:76-105`
(`appendAll` all-or-nothing: whole-batch validation against store AND intra-batch
before any mutation, single synchronized block = kt's equivalent of Dart's
no-await-in-loop guarantee).
Pins: contract test `:92` (append throws on duplicate), `:124` (against-store,
applies nothing), `:139` (intra-batch, applies nothing), `:151` (rejected batch
leaves no trace — the phantom-stream pin, *stronger than Dart*, register row).
Caller-side belt-and-suspenders: `GossipEngineTest.kt:1701` (duplicates filtered
before the repository — no throw, no error); `CoordinatorTest.kt:693` (residual
intra-batch duplicate surfaces via ErrorCallback and the receive loop survives).

### Item 10 — Scheduler forking fix + zero-interval guard — **CLOSED** (KT-C)

Evidence: `shared/domain/services/GenerationScheduler.kt` — `generation` counter
(`:56`), bumped by every `start` (even while running, `:64-71`) and `stop` (`:80-83`),
staleness check before tick AND reschedule (`:88, :99`); asymmetric failure policy
ported exactly: tick error → report + continue (`:113`), scheduling error →
stop-self-first-then-report (`:99-104`, KDoc `:30-45` distinguishes live vs stale
failures); kt-specific `CancellationException` carve-out (ruling 1).
Zero-interval guard: `InMemoryTimePort.kt:25-26` throws on non-positive
`schedulePeriodic`. Note: kt ALSO guards `RealTimePort.kt:24-25` — the inventory
warned against cargo-culting this onto the real port; kt did it deliberately under
KT-A's fail-fast-guard convention (and pinned it, `RealTimePortTest.kt:21-28`), so it
is a considered choice, not a cargo-cult, but it is *not* explicitly argued anywhere
against the JVM's degenerate-interval behavior. Cosmetic.
Pins: `GenerationSchedulerTest.kt` — 10 tests incl. the direct fork pin
(`:108` stop-then-start within one interval never forks), fresh `nextDelay` per cycle
(`:81`), stale-delay no-op (`:207`), stop-during-in-flight-tick (`:313`), stale
scheduling error does not stop a live loop (`:274` — *stronger than Dart*).
Follow-up already registered, not a KT-D scenario item: the gossip and
failure-detector loops still run on frozen-interval `schedulePeriodic`
(`GossipEngine.kt:132`) — migration onto the scheduler is the divergence register's
"Per-cycle interval recomputation" row, ruled out of KT-C scope (ruling 1).

### Item 11 — Materializer/compaction interaction — **PARTIAL**

Closed pieces:
- Reset-on-compact by default: `ChannelService.kt:205` (`resetState: Boolean = true`),
  `:257-259` → `MaterializationService.reset` → per-materializer `fullRebuild`
  (`MaterializationService.kt:150-158, :272-289`).
- Cursor resume vs full rebuild, and the **uninitialized + out-of-order → full
  rebuild** branch (Dart's `dd16e29` half) with its rationale comment:
  `MaterializationService.kt:184-200` (`:189-192`: "A cursor comparison can't be
  trusted against an entry that may sort below a cursor it was never actually folded
  past").
- **The KNOWN OPEN GAP is deliberately documented, not hidden**: class KDoc
  `MaterializationService.kt:27-35` states the rebuild decision is in-memory only,
  the silent-divergence consequence, and that closing it "requires persisting a
  'rebuild from the beginning' cursor value, which is a [StateMaterializer] contract
  change" — parity with Dart's open state
  (`docs/backlog/engine-materializer-rebuild-marker.md`, campaign register row 80
  homes the Dart-side fix). The "account for it in the interface" instruction is
  satisfied as a recorded design input; the fix itself is open in BOTH libraries by
  design.

Remaining (the real gaps):
- **COR3-13 is present in kt**: `foldEntries` iterates materializers *sequentially*
  with no per-materializer catch (`MaterializationService.kt:140-147`; `reset`
  likewise `:150-158`) — one throwing materializer starves its siblings and the
  exception propagates into the append/merge caller (`ChannelService.kt:170` calls it
  unwrapped). Dart enqueues all before awaiting (`materialization_service.dart:99-118`).
- **Cursor tie-blindness (COR3-27 residue)**: kt's cursor is a raw `Hlc` and resume
  filters `it.timestamp > cursor` (`:228-246`) — an entry tying the cursor timestamp
  from another author is silently skipped. Dart's cursor comparison uses the full
  `(timestamp, author, sequence)` order. (The *merge-path* `<=` tie check IS ported
  and pinned — `GossipEngineTest.kt:1426`.) Pairs naturally with the M3 insertion-
  order fix (KT-E).

### Item 12 — Wire-level contracts — **CLOSED** (format) / **REASSIGNED** (budget/cap)

- Format parity shipped by the wire batch and is now a *shared spec*, not an
  accidental match: v2 base64 payloads with dual-format decode + out-of-range
  rejection (`SyncWireV2.kt:175-236`), floor omitted-when-empty / default-empty and
  hasMore default-false (`SyncWireV2.kt:101-129`; v1 `SyncWireV1.kt:131-179, :231,
  :270-283`), typed three-way decode result (register rows judge kt's shape better).
  Pinned by golden bytes + cross-repo conformance vectors (`WireGoldenTest.kt`,
  `WireVectorConformanceTest.kt:150`, `SyncMessageCodecTest.kt:560, :581`). The
  inventory's "only if interop" framing is obsolete — interop is now a stated goal
  (app↔server), and the campaign owns it.
- **Not in kt**: `maxMessageBytes`, `maxEntryPayloadForBudget`, the ~22KB append-time
  cap, delta paging (responder hard-codes `hasMore = false` — "kt sends complete
  deltas; no pagination yet", `GossipEngine.kt:317`; the *receiver* side of hasMore +
  progress-gated continuation IS implemented and pinned, `:443`,
  `GossipEngineTest.kt:1167-1266, :1659`). All REASSIGNED to
  `kt-wire-versioning-campaign.md`'s paging/budget register row (same ruling as
  item 6). The 30KB-vs-32KB distinction has no kt meaning until that lands.

### Item 13 — Other 2026-07 audit fixes — mixed, per sub-item

| Sub-item | Verdict | Evidence / remaining |
|---|---|---|
| H1 delta livelock (byte budget + poison isolation) | **REASSIGNED** | No budget machinery in kt (verified); campaign register paging/budget row. |
| H2 scheduler forking | **CLOSED** | Item 10. Gossip/probe loop migration = register "Per-cycle interval recomputation" row (routed follow-up). |
| H5 append race / silent loss | **PARTIAL** | The *silent-loss* half is closed (duplicate throws, item 9; loud `IllegalStateException`). The *serialization* half is not: `EventStream.append` → `ChannelService.appendEntry` reads `latestSequence + 1` then appends as two separate repo calls (`ChannelService.kt:146, :166`) with no per-stream chain, on a multi-threaded `Dispatchers.Default` scope — two concurrent app-side appends to one stream can allocate the same sequence and one *throws to the caller*. Loud, not silent — but Dart guarantees success via `KeyedTaskChain` (`channel_service.dart:375`). Not recorded in the divergence register (its merge-serialization row covers only the receive loop). |
| H6 compaction VV regression | **CLOSED** | Items 1/4; contract test `:302-341`; `TwoNodeCompactionTest`. |
| M3 total order (insertion by full compareTo) | **OPEN — already routed to KT-E** | `InMemoryEntryRepository.kt:262` (`findInsertIndex` on timestamp only); divergence register "Entry insertion order" row names it a KT-E candidate. Not KT-D unless resequenced. |
| COR3-1 (the CRITICAL) | **CLOSED** | Items 2+3. |
| COR3-8 interface doc rot | **CLOSED** | `EntryRepository.kt:24-45` states the real contract (verified language: "monotonic high-water marks", not "0 if none"). |
| COR3-9 overlapping-merge interleaving | **CLOSED by architecture** | Single-collector receive loop + `Coordinator.start` idempotence pin (`CoordinatorTest.kt:177`); register "Merge-path serialization" row = tolerated architectural difference, ruled no-action. |
| COR3-13 throwing materializer starves siblings | **OPEN** | See item 11. `MaterializationService.kt:140-147`. |
| COR3-15 compactAll isolation | **CLOSED** | Item 7; `ChannelServiceCompactAllTest.kt:112`. |
| COR3-16 createChannel silently resets existing | **OPEN** | `ChannelService.kt:60-67` unconditionally `ChannelAggregate.create` + `save`; `InMemoryChannelRepository.kt:22-24` `save` overwrites (`storage[id] = deepCopy`); `Coordinator.createChannel` (`Coordinator.kt:472-475`) adds no guard. Calling `createChannel` on an existing channel wipes members and stream configs with no event and no error — the exact pre-fix Dart bug. Not in the divergence register. |
| COR3-27 HLC-tie blind spots | **PARTIAL** | Merge path closed and pinned (`GossipEngineTest.kt:1426`, ties count as possibly-out-of-order). Materializer cursor path still raw-Hlc (item 11). |
| COR3-10 unbounded HLC drift | **OPEN** | No `hlcMaxDrift`/drift bound anywhere in kt main (`HlcClock.kt` has none; `CoordinatorConfig.kt` has no field); `GossipEngineTest.kt:872` pins that remote timestamps update the clock — unboundedly. Directly protects `TimeBasedRetention` from a bad peer clock pruning mesh-wide, so it is compaction-adjacent, not cosmetic. |
| MIN-8 VersionVector aliasing | **PARTIAL (minor)** | `VersionVector.kt:14` stores the caller's map without a defensive copy (a caller-held `MutableMap` stays aliased); explicit zeros preserved — the zeros half is a **registered tolerated asymmetry** (register "Version-vector explicit-zero handling" row), the aliasing half was never examined kt-side. |
| MIN-6 retention validation | **CLOSED** | Item 8. |

---

## KT-D candidates

Genuine scenario/behavior work from the PARTIAL/OPEN pieces above. Excluded as
REASSIGNED by ruling: budgeter rotation + paging + payload cap + H1
(→ `kt-wire-versioning-campaign.md` register), quiescence/pacing pins
(→ `kt-port-wire-efficiency.md`), M3 insertion order (→ KT-E per register),
partition primitive (→ campaign register future scope), gossip/probe loop migration
onto GenerationScheduler (→ register follow-up row).

**Correctness (behavior fixes):**
1. **COR3-16 — `createChannel` get-or-create semantics.** Existing aggregate must be
   a no-op (no reset, no events). Port Dart's fix (`channel_service.dart:148-163`) +
   pin. Smallest, sharpest data-loss class on the list.
2. **COR3-13 — materializer fold isolation.** One throwing materializer must not
   starve siblings nor kill the append/merge caller; error per materializer via
   ErrorCallback. Port Dart's enqueue-all-then-await shape (adapted to kt's per-state
   mutexes) + pin.
3. **COR3-10 — HLC drift bound.** `hlcMaxDrift`-equivalent config + clamp in
   `HlcClock` receive path + pin. Compaction-adjacent (guards TimeBasedRetention).
4. **H5 — local append serialization.** Either a per-stream append chain (Dart
   parity) or an explicit accept-and-document ruling that concurrent same-stream app
   appends may throw; today it is an *undocumented* loud race. Needs a register row
   either way.
5. **COR3-27 residue — materializer cursor uses full entry order.** Fix the
   `timestamp > cursor` resume filter's tie-blindness (or fold into KT-E with M3,
   since both are total-order fixes — decide at triage).

**Scenario pins (no production change expected, regression traps):**
6. **Compaction-landing-mid-sync race pin** (item 5's one missing scenario): stage
   compact between DeltaRequest send and handle; assert handle-time floor, requester
   convergence, and no pending-flag wedge on the follow-up round. Unit-level per
   Dart's `group('compaction mid-sync race')`; kt's engine harness supports it.
7. **Coordinator-level scheduling-failure pin** for the compaction loop (delay
   failure → exactly one error, loop stays dead until stop/start). Requires
   revisiting KT-C ruling 9 (no Coordinator test seam) or driving it purely through
   `InMemoryTimePort`.

**Doc-only (deliberate-decision records the inventory asked for):**
8. **Push-scoping nuance**: record in the divergence register that kt has no reactive
   push path today, and that if one is ported the freeze-vs-reconsult decision from
   `docs/backlog/engine-push-scoping.md` must be made deliberately.
9. **MIN-8 aliasing half**: one-line register addendum on the existing VV row (kt
   stores the constructor map unaliased-copy-free) — or a trivial `toMap()` fix
   ride-along with any of the above.

**Already routed TO KT-D by KT-C (triage, kt-plan enhancements beyond Dart parity):**
digest-level floor advertisement, skip-below-peer-floor on serve, snapshot sync
(KT-C plan `docs/plans/2026-08-30-kt-batch-c-auto-compaction.md:96-99`; old plan
`2026-05-14-compaction.md:882-887`). These are new capability, not fix-porting —
triage them against candidates 1–7 rather than assuming they lead the batch.
