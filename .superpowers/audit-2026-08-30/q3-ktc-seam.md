# Q3 — KT-C (auto-compaction) pre-planning seam verification

Read-only verification, 2026-08-30.
Dart reference: `/Users/joel/git/neutrinographics/gossip` @ `working-connection` (8fc0165).
Kotlin target: `/Users/joel/git/neutrinographics/gossip-kt` @ `feature/compaction` (6ee2b03).

---

## Part 1 — Dart reference map

### GenerationScheduler
`packages/gossip/lib/src/shared/domain/services/generation_scheduler.dart:36-115`

```dart
GenerationScheduler({
  required TimePort timePort,
  required Duration Function() nextDelay,   // called fresh EVERY cycle (adaptive)
  required Future<void> Function() tick,
  required void Function(Object, StackTrace) onTickError,
  required void Function(Object, StackTrace) onSchedulingError,
})
void start();  bool get isRunning;  void stop();
```

- Built on `TimePort.delay` (not `schedulePeriodic`) so the interval can change per cycle (doc :7-10).
- **Forking fix** (doc :12-22): a naive `delay().then(tick).then(scheduleNext)` loop forks into two live loops if `stop()`+`start()` happen within one interval — the pre-stop pending delay still fires and reschedules alongside the fresh loop. `_generation` (:70) is bumped by every `start` (:83) and `stop` (:91); scheduled callbacks check it (:95, :99) and a stale callback does nothing. History: consolidated by CC5-7 (`655227e` "GenerationScheduler — one home for the generation-token loop"; FailureDetector migrated in `f12edf1`); the underlying forking bug class was fixed in the 2026-07-06 correctness audit (`2c1f6a9`, findings WS-A..WS-E).
- **Error-policy asymmetry** (doc :24-35): a `tick` error → `onTickError`, loop continues (:100-105). A *scheduling* error (the delay future itself failing) → loop stops itself first (keeps `isRunning` truthful), then `onSchedulingError` (:107-113).

### ChannelService.compactStream / compactAll
`packages/gossip/lib/src/sync/application/channel_service.dart`

- `Future<CompactionResult?> compactStream(ChannelId, StreamId, {bool resetMaterializers = true})` — :645-699. Flow: null-repo → null; `getRetentionPolicy` null or `retainsAll` → null (:652-653); empty stream → null; `retention.compact(entries, now)` (:659, `now` = HLC timestamp); prune via `removeEntries` (:664); read post-compaction VV (:665, "monotonic high-water mark, never regresses" :639-641); `resetState` rebuilds materializers (:667-669); emits `StreamCompacted(channelId, streamId, result, occurredAt)` only when `entriesRemoved > 0` (:687-696). `CompactionResult(entriesRemoved, entriesRetained, bytesFreed, baseVersion)` (:671-676) — note `baseVersion` is a `VersionVector`.
- `Future<void> compactAll()` — :704-731. Iterates `channelRepository.listIds()` × `channel.streamIds`; **cheap skip** of null/`retainsAll` policies without loading entries (:711-712); **per-stream failure isolation** — try/catch around each `compactStream`, failure emits `StorageSyncError(storageFailure, 'Compaction failed for $channelId/$streamId')` and the loop continues (:713-728, comment: "one poison stream must not starve every stream after it on every pass, forever").

### Coordinator loop + config
`packages/gossip/lib/src/coordinator/coordinator.dart`

- `_compactionScheduler` field :133 (nullable; built lazily). `_startCompaction()` :422-452 — no-op if `timePort == null || interval == null || interval <= Duration.zero` (:423-427); `??=` constructs `GenerationScheduler(nextDelay: () => interval /* fixed */, tick: _channelService.compactAll, onTickError → StorageSyncError 'Auto-compaction failed', onSchedulingError → StorageSyncError 'Auto-compaction scheduling failed')` (:428-450), then `start()`. `_stopCompaction()` :456-458.
- Lifecycle call sites: start :928, stop :958, pause :984, resume :1017, dispose :1048. Test hook `compactionSchedulerForTesting` :723.
- Config: `coordinator_config.dart:155` `final Duration? compactionInterval;`, **default 5 minutes** (:188). Doc (:137-154): null or `Duration.zero` disables (app then calls `EventStream.compact()` manually); requires a `timePort` (inactive in local-only mode); scheduling failure stops the loop deliberately — app observes `StorageSyncError` and stop/starts the coordinator to restart it.

### Retention policies
`packages/gossip/lib/src/sync/domain/interfaces/retention_policy.dart`

- `RetentionPolicy` :25 — `List<LogEntry> compact(List<LogEntry> entries, Hlc now)` :35 and **`bool get retainsAll`** :41 (the cheap-skip hook).
- `KeepAllRetention` :50 (`retainsAll => true`), `TimeBasedRetention` :69, `CountBasedRetention` :119, `CompositeRetention` :182 (`retainsAll => policies.any(...)` :221).

### Floor production → serving
- `InMemoryEntryRepository.removeEntries` raises the per-author compaction floor as it prunes (`in_memory_entry_repository.dart:211-228`); `getCompactionFloor` :275; `adoptVersionFloor` :287 (raises floor AND high-water mark, monotonic — interface contract `entry_repository.dart:216-247`).
- Serve time: `GossipEngine.handleDeltaRequest` reads `entryRepository.getCompactionFloor(...)` fresh per request (`gossip_engine.dart:1400-1404`) and reports the portion the requester is below via `_reportableFloor` (:1427-1440) in `DeltaResponse.floor` (:1416). So compaction needs **no wiring into the engine** — raising the repo floor is immediately visible.

---

## Part 2 — kt assumptions, verified at 6ee2b03

### 1. Repository compact/floor primitives — ASSUMPTION HOLDS
`sync/domain/interfaces/EntryRepository.kt`: `suspend fun removeEntries(channelId, streamId, ids: List<LogEntryId>)` :119 (contract: atomically raises the floor); `suspend fun getCompactionFloor(channelId, streamId): VersionVector` :149; `suspend fun adoptVersionFloor(channelId, streamId, floor: VersionVector)` :169.
`sync/infrastructure/InMemoryEntryRepository.kt`: monotonic `latestSequenceCache` KDoc :30-38 ("Never regresses on removeEntries... always at or above compactionFloors"); `removeEntries` merges pruned sequences into `compactionFloors` atomically :127-158; `adoptVersionFloor` :183-207 (no-op on empty floor :188, raises mark + floor per author). KT-A retention require-guards present: `CountBasedRetention.kt:18` (`maxEntriesPerAuthor >= 0`), `TimeBasedRetention.kt:18` (`!maxAge.isNegative()`), `CompositeRetention.kt:17-18` (non-empty policy list). There is no single `compact()` on the repo — compaction is `ChannelService.compactStream` + `removeEntries`, same as Dart.

### 2. Retention types + defaults in ChannelService — HOLDS (one gap)
`KeepAllRetention` / `CountBasedRetention` / `TimeBasedRetention` / `CompositeRetention` all exist in `sync/domain/services/`; interface `sync/domain/interfaces/RetentionPolicy.kt:15` with `fun compact(entries: List<LogEntry>, now: Hlc): List<LogEntry>` :22. Default applied in `ChannelService.createStream` — `val policy = retentionPolicy ?: KeepAllRetention()` (`ChannelService.kt:80-85`), not in the aggregate (matches memory). **Gap:** kt `RetentionPolicy` has **no `retainsAll`** — Dart's cheap-skip hook for `compactAll` does not exist (see Part 3 #4).

### 3. Local floor → reportableFloor — HOLDS, no missing wire-up
`GossipEngine.kt`: `private suspend fun reportableFloor(request)` reads `entryRepository.getCompactionFloor(request.channelId, request.streamId)` **at serve time** :332-333, used in `handleDeltaRequest` :295-320 (`DeltaResponse.floor` :318, floor-only responses sent even with zero entries :309). Receiving side adopts a solicited response's floor via `adoptVersionFloor` :395-401. An auto-compaction loop only needs to call `compactStream`; the repo floor flows to lagging peers with no extra plumbing. (Digest-level floor advertisement is still absent — a deferred old-plan item, not a KT-C blocker; see #8.)

### 4. Materializer handling of own compaction — HOLDS (event shape diverges)
`ChannelService.compactStream(channelId, streamId, resetState: Boolean = true): CompactionResult?` (`ChannelService.kt:202-270`): on prune it calls `materializationService?.reset(channelId, streamId)` :257-259 — `MaterializationService.reset` "Forces a full rebuild of all materializers for the stream" (`materialization/MaterializationService.kt:149`) — and emits `StreamCompacted` via `onEvent` :261-264. So yes, kt has the event and the rebuild. **Shape divergence:** kt `StreamCompacted(channelId, streamId, removedCount: Int, at)` (`sync/domain/events/StreamCompacted.kt`) vs Dart's event carrying the full `CompactionResult`; kt `CompactionResult(entriesRemoved, entriesRetained, bytesFreed: Long)` (`sync/domain/values/CompactionResult.kt`) **has no `baseVersion`** — deliberately dropped post-audit ("floor is observable via getCompactionFloor", plan changelog item 1).

### 5. Coordinator loop home, idempotence, config — PARTIAL
- Loop idiom: kt has **no GenerationScheduler**. Both existing loops use `TimePort.schedulePeriodic(interval) { ... } → TimerHandle`, with `if (_isRunning) return` idempotent start and `TimerHandle.cancel()` on stop: `GossipEngine.kt:128-161`, `FailureDetector.kt:118-141`. `RealTimePort.schedulePeriodic` (`shared/infrastructure/RealTimePort.kt:20-38`) launches a `while (isActive) { delay; action() }` coroutine on the Coordinator's scope and cancels the Job — the cancelable handle forecloses Dart's forking hazard by a different mechanism. Note the kt gossip loop computes `effectiveGossipInterval()` **once at start** (`GossipEngine.kt:132`) — kt's idiom cannot express Dart's per-cycle adaptive interval (which is *why* Dart built GenerationScheduler on `delay`).
- `Coordinator.start()` idempotence (KT-B): `Coordinator.kt:300-355` — `if (_syncState == SyncState.RUNNING) return` :302 guards everything started inside, so a compaction start added there is covered. `stop()` :362-366 / `pause()` :373-377 / `dispose()` :384-390 each stop the engines; a compaction stop slots in symmetrically. No separate `resume()` — restart is `start()` from PAUSED.
- Config: `CoordinatorConfig.kt:14-37` — flat data class, `Duration` knobs (`gossipInterval = 200.milliseconds`, `probeInterval = 1.seconds`), **`init { require(x > Duration.ZERO) }` guards** :30-35 (a KT-A addition). No `compactionInterval` exists. `TimePort.schedulePeriodic` also `require`s a positive interval (`TimePort.kt:21-24`, `RealTimePort.kt:24-26`). Dart's "null or zero disables" idiom collides with this require-positive pattern (Part 3 #5). Also: kt **always** has a TimePort (`RealTimePort` default, `Coordinator.kt:137-138`) — Dart's "no timePort in local-only mode ⇒ no auto-compaction" gate has no kt analog (Part 3 #6).

### 6. Event surface — HOLDS
Shared `MutableSharedFlow<DomainEvent>(extraBufferCapacity = 100)` created in `Coordinator.create` (`Coordinator.kt:155`), exposed as `Coordinator.events` :94; `ChannelService.onEvent = { events.tryEmit(it) }` :169. `StreamCompacted` is already a `DomainEvent` and already published from `compactStream` (`ChannelService.kt:264`). Errors: `onError: ErrorCallback` + `Coordinator.errors` flow :96-99. No scope decision needed — the path exists and is exercised.

### 7. Threading — PARTIAL (real decision required)
The Coordinator scope is `Dispatchers.Default + SupervisorJob` (`Coordinator.kt:137`) — a **multi-threaded pool**. The receive collector (`scope.launch` :305) and every `schedulePeriodic` loop (launched by `RealTimePort` on that same scope) run as separate coroutines that can execute **concurrently on different threads**. KT-B T1's serialization claim covers only `handleMessage`'s single caller (`GossipEngine.kt:194-203` KDoc: "Callers must serialize invocations... the Coordinator's single receive-loop collector is the sole caller"); it does NOT serialize the gossip round loop against the receive path — those already run concurrently today. `InMemoryEntryRepository` has **no internal synchronization at all** (zero `Mutex`/`synchronized` hits; plain nested `mutableMapOf`) — a timer-driven `compactAll` calling `getAll`/`removeEntries` concurrently with a merge's `appendAll` is a genuine data race on shared maps. This race class exists today (round loop reads vs receive writes), but compaction adds *structural mutation* (list removal + floor merge) to it, and `Channel.compact()`/`EventStream.compact()` already expose the same hazard from arbitrary caller coroutines. `MaterializationService` IS guarded (per-state `Mutex`, `ConcurrentHashMap` — `MaterializationService.kt:61,77,108`); the repository is the unguarded piece. Existing idiom for arbitrary-caller boundaries is plain-monitor guarding (divergence register row "Thread-safety posture", `docs/backlog/kt-normalize-twin-divergences.md:51`).

### 8. Old compaction plan — remaining items
`gossip-kt/docs/plans/2026-05-14-compaction.md` (876 lines). Tasks 1-5 all shipped (CompactionResult, floor storage in EntryRepository, `ChannelService.compactStream`, `EventStream.compact()`, `Channel.compact()` fan-out — `Channel.kt:115-125`, `EventStream.kt:~62-74`), plus the post-audit fix round (encapsulated floor `cbb90eb`, contract test suite `96bd99f`, materializer fold/reset Mutex `a3800d8`, two-node integration `1e280fc`) and changelog rows 5-6 for KT-A/KT-B (:851-862, the KT-B T8 update). **Still undone** (Out of scope, :870-875):
- (a) Digest-level floor advertisement — the floor went on the wire only in `DeltaResponse` (2026-08-29 wire/codec batch, per the nested supersessions in :872); digests still advertise a range the node can no longer serve.
- (b) `GossipEngine` skipping DeltaRequests below a peer's advertised floor (:873).
- (c) Snapshot/checkpoint sync to bring a fresh peer past a compacted region (:874).
- (d) "Periodic or threshold-based automatic triggering (currently manual only, matching Dart)" (:875) — **this is KT-C itself**, and its "matching Dart" note is stale: Dart has had auto-compaction since CC5. (a)-(c) are KT-C/KT-D routing candidates, not KT-C prerequisites.

---

## Part 3 — Mismatch list: KT-C's plan must decide

1. **GenerationScheduler: port literally or not.** kt's existing loop idiom (`schedulePeriodic` + cancelable `TimerHandle`, idempotent-start flag) already forecloses the forking hazard by cancellation rather than generation tokens, and compaction needs only a fixed interval. A literal port buys twin parity and would give kt the per-cycle-adaptive-delay primitive its gossip loop currently lacks (kt computes the adaptive interval once at start — `GossipEngine.kt:132` — a latent twin divergence worth a register row regardless). Decide: literal port into `shared/domain/services` (and whether GossipEngine/FailureDetector migrate onto it as Dart did in CC5-7), vs. idiomatic `schedulePeriodic`.
2. **Scheduling-error asymmetry has no kt analog.** Dart distinguishes tick failure (report, continue) from scheduling failure (stop loop, keep `isRunning` truthful, report). kt's `schedulePeriodic` loop has no equivalent channel — `RealTimePort`'s while-loop wraps nothing; an `action()` throw kills the launched coroutine silently (SupervisorJob swallows it) and `_isRunning` keeps lying. If KT-C keeps `schedulePeriodic`, the tick must catch its own errors (as `GossipEngine.start` does, :133-145) and the "broken timer stops the loop truthfully" behavior is simply unrepresentable without the scheduler port. Decide which failure contract KT-C promises.
3. **`compactAll` doesn't exist and `compactStream`'s skip-paths are noisy.** kt `compactStream` emits `StorageSyncError`/`ChannelSyncError` for no-repo / missing-channel / missing-stream (`ChannelService.kt:208-241`) where Dart returns null silently. A periodic loop naively calling kt `compactStream` on a repo-less or racing-deleted channel would emit an error every 5 minutes forever. `compactAll` must pre-filter Dart-style (iterate repo IDs, check policy first) and add Dart's per-stream try/catch isolation — note kt's existing `Channel.compact()` fan-out (`Channel.kt:115-125`) has **no** per-stream isolation; decide whether it gains it too or stays a manual-API with throw-through semantics.
4. **No `retainsAll` on kt `RetentionPolicy`.** Without it, `compactAll` cannot skip KeepAll streams cheaply — it would load every entry of every stream each tick just to discover nothing prunes. Decide: add `retainsAll` (parity; touches the interface and all four policies) or accept the per-tick load.
5. **Config disable idiom.** `CoordinatorConfig.init` `require`s positive intervals and `schedulePeriodic` requires a positive interval; Dart disables via `null`/`Duration.zero`. Decide kt's representation (`compactionInterval: Duration? = 5.minutes` with null-disables, exempted from the require-positive guard; or an `autoCompactionEnabled` flag) and pin the guard interaction.
6. **Local-only mode gate.** kt always has a TimePort, so auto-compaction would run in local-only mode, unlike Dart (gated on timePort presence). Probably desirable (retention should be enforced locally too) — but it's a deliberate twin divergence either way; decide and register it.
7. **Event/result shape.** kt `StreamCompacted(removedCount)` and `CompactionResult` without `baseVersion` are documented past decisions (floor observable via `getCompactionFloor`), diverging from Dart's event carrying the full result incl. `baseVersion`. Decide keep-or-converge; add/confirm a divergence-register row.
8. **Execution context vs. the unsynchronized repository.** A timer-driven `compactAll` on `Dispatchers.Default` races `handleMessage`'s `appendAll` on `InMemoryEntryRepository`'s plain maps (Part 2 #7). Options: accept as same-class-as-existing (and say so in a KDoc), route compaction ticks through the same serialized path as the receive collector, guard the in-memory repo (monitor, per the registered kt pattern), or confine the whole Coordinator scope to a single-threaded dispatcher (biggest change, closest to Dart's ADR-001 model). This is the one item with correctness stakes; the plan must pick explicitly.
9. **Lifecycle mapping.** Dart wires `_startCompaction`/`_stopCompaction` into start/stop/pause/resume/dispose; kt has start/stop/pause/dispose (restart-after-pause is `start()`). Straightforward, but pin that `start()` after `pause()` restarts compaction and that `dispose()` cancels it (scope cancellation would kill a `schedulePeriodic` handle anyway — decide whether to rely on that or cancel explicitly). Dart also exposes `compactionSchedulerForTesting` (:723); decide kt's test seam (with `InMemoryTimePort` a seam may be unnecessary).
