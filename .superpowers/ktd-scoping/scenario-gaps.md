# Batch KT-D pre-planning: scenario-coverage gap analysis

Date: 2026-08-30. Read-only survey.

- Dart reference: `/Users/joel/git/neutrinographics/gossip` @ `working-connection`,
  `packages/gossip/test/` (suite 1254; **113 scenario tests in `test/integration/`**
  across 18 files, all built on the `TestNetwork` DSL in
  `test/support/test_network.dart`).
- Kotlin target: `/Users/joel/git/neutrinographics/gossip-kt` @ `feature/compaction`
  (fc4bec3, suite 795; **16 scenario tests** across 7 files in
  `src/test/kotlin/com/neutrinographics/gossip/integration/`, hand-rolled setup, no DSL).

## 1. Dart scenario inventory vs kt counterparts

Scenario-level = everything under `packages/gossip/test/integration/` plus the DSL
and bus-conditions support tests. No multi-node end-to-end tests live outside
`integration/` in Dart (coordinator/* tests are single-node or two-port unit-style).
Absolute paths below are relative to `packages/gossip/test/` (Dart) and
`src/test/kotlin/com/neutrinographics/gossip/` (kt).

| Dart scenario file / group | What it proves | kt counterpart | If NONE: kt machinery needed |
|---|---|---|---|
| `integration/sync/basic_sync_test.dart` — two-node group (3 tests) | Channel creation parity; A→B sync; bidirectional convergence | `integration/TwoNodeSyncTest.kt` (entry syncs A→B, bidirectional, multiple streams, VV convergence) — **covered** | — |
| `basic_sync` — three-node group (2) | Propagation through an intermediate node; three writers converge | `integration/MultiNodeSyncTest.kt` (both tests) — **covered** (but kt is full-mesh; the Dart "through intermediate node" chain variant is not distinctly pinned — uncertain, kt setup looks full-mesh) | Chain wiring only (Class A) |
| `basic_sync` — concurrent/rapid ops (3) | Concurrent, rapid-sequential, rapid-alternating writes converge | Partially: `MultiNodeSyncTest` "concurrent writes on all three nodes converge" | Rest Class A |
| `basic_sync` — multiple streams (2) | Streams sync independently; stream created after entries exist | `TwoNodeSyncTest` "multiple streams sync" covers first; late-created stream: NONE | Class A |
| `basic_sync` — multi-channel (3) | Many channels simultaneously; per-channel membership; high channel count | NONE | Class A |
| `integration/sync/topology_sync_test.dart` (3) | Chain, star, ring topologies all converge | NONE | Class A — only peer wiring helpers |
| `integration/sync/scale_sync_test.dart` (8) | Empty channel; single node; large payload; many entries; 8-node mesh; 100 entries; 8 concurrent writers | Partially: `TwoNodeSyncTest` "large payload syncs correctly"; rest NONE | Class A |
| `integration/sync/churn_sync_test.dart` — churn group (4) | Join mid-sync; rejoin with stale data; offline writes sync on reconnect; long offline catch-up | NONE. "Join mid-sync" is Class A (connect-later). The other three use `network.partition`/`heal` — heal-in-place | Class B (node-level cut + re-attach) |
| `churn_sync` — restart group (4) | Stop/restart preserves data; sequential restarts; all restart; stale-clock HLC recovery | NONE (kt `CoordinatorTest` "can restart after stop" is unit-level, no sync-after-restart) | Class A — kt stop/start + kept repositories suffice |
| `integration/sync/partition_sync_test.dart` (4) | Partition heals, sync resumes; entries written during partition merge; divergent writes merge; three-way partition heals | NONE | Class B — needs node-level partition + heal that preserves coordinator state (registered in `docs/backlog/kt-normalize-twin-divergences.md` "Partition primitive" row) |
| `integration/sync/compaction_late_joiner_test.dart` (4) | Floor adoption content-checked; transitive floor via B; returning peer below floor; prune-all then new appends | `integration/CompactionLateJoinerTest.kt` (3 tests, same first three scenarios) + `TwoNodeCompactionFloorTest.kt` + `TwoNodeCompactionTest.kt` + `AutoCompactionFloorTest.kt` — **covered**; kt worked around partition via connect-later. "Prune-all then new appends" exact variant: probably covered by the floor tests but not 1:1 — uncertain | Verify during KT-D; port the 4th variant if missing (Class A) |
| `integration/sync/idle_quiescence_test.dart` (5) | Idle traffic decays post-convergence; write snaps cadence back; deep idle stretches toward ceiling; lost reactive push repaired within 30s ceiling; deep idle never marks healthy peers unreachable | NONE | Class C — quiescence pacer + reactive push + probe suppression are unported (postponed to `docs/backlog/kt-port-wire-efficiency.md`; divergence register row 58 says the pin ports with the mechanism). "Lost reactive push" test additionally needs `dropNext` (also Class B) |
| `integration/sync/adverse_network_test.dart` (6) | One-way partition blocks until healed; delayed link holds in flight; drops/dups/corruption don't break convergence or integrity | NONE | Class B — needs the full link-conditions set: `partitionOneWay`, `delayLink`/`releaseInFlight`, `dropNext`, `duplicateNext`, `corruptNext` |
| `integration/adverse/asymmetric_partition_test.dart` (4) | One-way-deaf peer with/without relay: suspicion, recovery after one-way heal | NONE | Class B — directional link block (`partitionOneWay`/`healOneWay`) |
| `integration/adverse/clock_skew_test.dart` — offset + rate groups (4) | 30-min offset converges; causal order across offset; 4x tick-rate skew converges; causal chain across skewed rates | NONE | Class A — kt has per-node `InMemoryTimePort` with `advance`; no harness gap |
| `adverse/clock_skew` — hlcMaxDrift group (3) | Beyond-bound entries still sync; out-of-bound remote clock clamped not adopted; within-bound keeps causal adoption | NONE | Class C — kt `HlcClock` has **no drift clamp** and `CoordinatorConfig` has no `hlcMaxDrift` knob (Dart default 1h, `coordinator_config.dart:167`). Production machinery gap, not previously on the wire-efficiency list — flag for a ruling |
| `integration/adverse/congestion_test.dart` (4) | Gossip rounds skipped while queued sends exceed threshold; draining reopens gate; convergence after congestion; per-peer isolation | NONE | Class B — kt `GossipEngine.kt:229` **has** the per-peer congestion gate (`PER_PEER_CONGESTION_THRESHOLD` via `pendingSendCount`), but kt `InMemoryMessagePort.pendingSendCount` is hardcoded 0 — needs held-link queue + pending-count accounting in the harness |
| `integration/adverse/duplicate_frames_test.dart` (3) | Duplicate frames are idempotent at the wire level; repeated dup cycles don't corrupt | NONE (kt `CoordinatorTest` "intra-batch-duplicate DeltaResponse" is a unit-level cousin) | Class B — `duplicateNext`/`corruptLink` bus primitives |
| `integration/adverse/message_loss_test.dart` (2) | Lost delta response: pull stays pending, timeout expires, retry converges; sustained probabilistic loss on one link converges | NONE (kt has `PendingPullTracker` + its unit test, so the production side exists) | Class B — `dropNext`, `setDropRate` (seeded), `delayLink` |
| `integration/edge_cases/message_handling_test.dart` (8) | Duplicate entries idempotent; out-of-order reception; intermittent partition; long message gap; asymmetric partition eventual consistency; entry integrity; large/empty payload | NONE (large payload partially in `TwoNodeSyncTest`) | Idempotency/ordering/integrity/payload rows: Class A. Partition/gap/asymmetric rows: Class B |
| `integration/failure_detection/peer_status_test.dart` (8) | Reachable baseline; suspected after partition; failed-probe count; suspected→reachable after heal; unreachable after prolonged partition; unreachable→reachable after heal; mutual unreachable recovery | `integration/FailureDetectionTest.kt` (3 tests) covers suspected, unreachable, and "recovery" — but kt recovery **disposes B and builds a fresh coordinator with a fresh port** (state scrubbed), so heal-in-place recovery, failed-probe-count, and mutual-recovery scenarios have no true counterpart | Class B — re-attach/`reregister` so a healed node keeps its port and state |
| `integration/lifecycle/coordinator_lifecycle_test.dart` (7) | Peer add/query; state transitions; no restart after dispose; pause/resume sync semantics; multi start/stop preserves data; writes-while-stopped sync after restart | Partially: kt `CoordinatorTest` covers transitions/dispose/restart at unit level; the sync-visible pause/resume and writes-while-stopped scenarios: NONE | Class A |
| `integration/lifecycle/channel_operations_test.dart` (7) | Channel/stream CRUD across nodes; membership modification; entries only sync to members; adding member syncs existing entries | NONE at scenario level (kt `CoordinatorTest` covers single-node CRUD) | Class A — membership-scoped sync is the valuable part |
| `integration/ordering/causality_test.dart` (14) | HLC causal ordering across sync; distinct HLCs for concurrent writes; HLC receive-update; physical time advancement; skew reflected in HLC; logical-counter overflow behavior; sequence contiguity/persistence | NONE (kt `HlcClockTest`/`HlcTest` are unit-level) | Class A — per-node time ports suffice |
| Support: `shared/infrastructure/in_memory_message_bus_conditions_test.dart` + `support/test_support_test.dart` | The link-condition primitives themselves behave as documented | NONE | Ports together with the Class B primitive — these are its spec |

## 2. kt harness capability inventory (the precise delta)

`src/main/kotlin/com/neutrinographics/gossip/shared/infrastructure/InMemoryMessageBus.kt`
(37 lines) + `InMemoryMessagePort.kt` (40 lines):

CAN express today:
- Normal routing between registered ports (`route` → `SharedFlow` emit, buffer 100).
- **Silent whole-node in-cut**: `removePort(nodeId)` — `route` does `ports[to]?.receive(...)`,
  so sends to a removed port vanish silently (this is how `FailureDetectionTest` makes
  B suspected/unreachable). Equivalent to Dart's `partition()`.
- **Loud whole-node in-cut**: `failSendsTo(destination)` / `healSendsTo` — sends throw
  `IOException` at the sender (visible failure, different SWIM surface than silent loss).
- Port close (sends `check`-fail; receives dropped).

CANNOT express today:
- **Heal-in-place**: `createPort` builds a *new* port; an existing coordinator still holds
  the old instance, so a partitioned node can only "recover" by dispose+recreate (state
  scrubbed). No `reregister`. This is the single biggest blocker (Class B).
- Per-link `(from, to)` directional conditions of any kind (Dart: `blockLink`).
- Counted drops (`dropNextMessages`), seeded probabilistic drop (`setDropRate`).
- Duplication (`duplicateNextMessages`, `setDuplicateRate`).
- Corruption transforms (`corruptNextMessages`, `setLinkCorruption`).
- Hold/delay links with in-flight queues (`holdLink`/`flushHeldMessages`/`releaseLink`,
  `heldMessageCount`).
- Backpressure observability: `pendingSendCount`/`totalPendingSendCount` hardcoded to 0
  (Dart's port derives it from held messages + `setSimulatedPendingCount`).
- No `TestNetwork`-equivalent DSL: no `connectAll/connectChain/connectStar/connectRing`,
  `setupChannel`, `joinChannel`, `runRounds`, `hasConverged`. Every kt integration test
  hand-rolls ~100 lines of setup.

Minimal bus-level link-cut for kt (`InMemoryMessageBus`):
1. Keep ports registered; add a `blockedLinks: MutableSet<Pair<NodeId, NodeId>>` checked
   in `route()` before delivery (silent drop) → gives `partitionOneWay`; a node-level
   partition is "block all links into and out of X" (or an `unregistered` set distinct
   from the port map) with heal = unblock — **no port recreation, coordinator state intact**.
2. Then layer the counted/seeded conditions as a per-link conditions record evaluated in
   `route()` in the same order Dart documents (block → drop → corrupt → duplicate → hold),
   and have `InMemoryMessagePort.pendingSendCount(dest)` report the held-queue length for
   that destination. Port Dart's `in_memory_message_bus_conditions_test.dart` as the spec.
3. Thread-safety note: kt's bus maps are unsynchronized `mutableMapOf` used from
   `Dispatchers.Default` tests — the new conditions state should be a `Mutex`-guarded or
   confined structure, unlike Dart's single-isolate free ride.

## 3. Classification

### A. Portable NOW with the existing kt harness
(needs only wiring/DSL conveniences, no bus or production-code changes)

- `basic_sync`: rapid/alternating writes, late-created stream, multi-channel groups,
  chain-propagation variant.
- `topology_sync_test.dart` (chain/star/ring) — pure peer-wiring.
- `scale_sync_test.dart` (empty channel, single node, many entries, 8-node mesh,
  100 entries, 8 concurrent writers).
- `churn_sync`: join mid-sync; all four restart tests (stop/start with retained repos);
  stale-clock HLC recovery.
- `ordering/causality_test.dart` — all 14 (per-node `InMemoryTimePort.advance` exists).
- `adverse/clock_skew_test.dart` offset + divergent-rate groups (4 tests).
- `edge_cases/message_handling`: duplicate-entry idempotency, out-of-order reception,
  entry integrity, large/empty payload.
- `lifecycle/coordinator_lifecycle`: pause/resume sync semantics, multi start/stop
  preserves data, writes-while-stopped sync after restart.
- `lifecycle/channel_operations`: membership-scoped sync (entries only reach members;
  adding a member syncs existing entries).
- Verify/port the `compaction_late_joiner` "prune-all then new appends" variant.

Strong recommendation: port a `TestNetwork`-style DSL first (create N coordinators on
one bus, topology helpers, `runRounds` over per-node time ports, `hasConverged`) —
~40 of the tests above become near-mechanical translations; without it each is a
hand-rolled 100-line fixture.

### B. Blocked on the partition/link-cut primitive
(motivates building it; registered in `docs/backlog/kt-normalize-twin-divergences.md`
"Partition primitive" row, homed via the wire-versioning campaign's register)

- Node-level cut + heal-in-place: `partition_sync_test.dart` (all 4);
  `churn_sync` rejoin-with-stale-data / offline-writes / long-offline (3);
  `edge_cases` intermittent partition, long message gap (2);
  `failure_detection/peer_status` heal-recovery, failed-probe-count, prolonged-partition
  + recovery, mutual unreachable recovery (~6).
- Directional block: `asymmetric_partition_test.dart` (4); `edge_cases` asymmetric
  partition (1); `adverse_network` one-way partition (1).
- Drops/dups/corruption/hold: `message_loss_test.dart` (2), `duplicate_frames_test.dart`
  (3), remaining `adverse_network_test.dart` (5).
- Hold + pendingSendCount accounting: `congestion_test.dart` (4) — kt's production
  congestion gate already exists (`GossipEngine.kt:229`) and is currently **untestable
  at scenario level**; this is the highest-value payoff of the held-link work.
- Plus the harness's own spec tests (`in_memory_message_bus_conditions_test.dart`,
  DSL portions of `test_support_test.dart`).

Rough count: ~28 scenario tests unlocked.

### C. Blocked on unported production machinery
(postponed by ruling to `docs/backlog/kt-port-wire-efficiency.md`; scenarios postpone too)

- **Quiescence pacing / adaptive idle cadence**: `idle_quiescence_test.dart` tests 1, 2,
  3, 5. Explicitly sequenced in divergence-register row 58: pin ports with the mechanism.
- **Reactive push (sender side)**: `idle_quiescence` test 4 ("lost reactive push repaired
  within the 30s ceiling") — kt only *tolerates* unsolicited pushes on receive
  (`GossipEngine.kt:499`), never sends them. Dual-blocked (also needs `dropNext`).
- **Probe suppression / responder exchange recording / dominance filter**: no dedicated
  Dart integration scenarios beyond idle_quiescence, but any translated pins ride with
  the wire-efficiency item.
- **Digest budgeting/rotation**: no `DigestBudgeter` in kt; no Dart *integration* scenario
  depends on it (unit-level only), so nothing extra postpones here.
- **HLC drift clamp (`hlcMaxDrift`)**: `clock_skew_test.dart` drift-bound group (3 tests).
  kt `HlcClock` has no clamp and `CoordinatorConfig` no knob. NOTE: this is *not* on the
  wire-efficiency list nor (as far as I can find) in the divergence register — it needs
  either a KT-D ruling (port the clamp, it's small and safety-relevant) or a new register
  row. Flagging rather than assuming.

### D. Dart-only for structural reasons

- Nothing in `test/integration/` is structurally unportable. Two semantics notes, not
  scenario gaps:
  - Dart's single-isolate model makes `runRounds` + seeded `Random` fully deterministic
    (exact-round-count pins). kt tests run coroutines on `Dispatchers.Default` with real
    `delay(50)` sleeps (`FailureDetectionTest.runSingleProbeCycle`), so ported pins on
    exact round counts/timing may need loosening or a virtual-dispatcher harness rework.
  - Dart's bus delivers synchronously in `deliver`; kt's port emits into a
    `MutableSharedFlow(extraBufferCapacity = 100)` consumed by a receive loop — ordering
    is preserved but delivery is asynchronous relative to the send call, so
    "immediately after send" assertions need a settle step.
- Dart's `reregister()`-based heal is itself a harness design choice, not a structural
  Dart-ism — the kt primitive can do better (block-set instead of unregistering).

## 4. Suggested KT-D sequencing input

1. DSL first (Class A enabler), then translate Class A (~50 tests, mechanical).
2. Bus link-conditions primitive (Class B enabler; port the conditions spec test with
   it), then Class B (~28 tests). Congestion tests validate an already-shipped,
   currently-unpinned production gate — prioritize.
3. Class C waits on the wire-efficiency port by standing ruling; add a divergence-register
   row or ruling for the `hlcMaxDrift` clamp, which currently falls through the cracks.
