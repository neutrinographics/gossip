# Dart → Kotlin port: authoritative behavior inventory (2026-05 → 2026-08 fixes)

**Purpose:** everything the Kotlin twin (`gossip-kt`) needs to reproduce so it doesn't
resurrect bug classes the Dart `packages/gossip` core already closed. Compaction is
prioritized (items 1–8) because it was the source of the one CRITICAL finding
(COR3-1, 2026-07-08 comprehensive audit) and has the deepest interaction surface.
Sources: `docs/audits/2026-07-06-algorithm-audit.md`,
`docs/audits/2026-07-08-comprehensive-audit.md`,
`docs/backlog/testing-compaction-scenario-coverage.md`,
`docs/backlog/engine-materializer-rebuild-marker.md`,
`docs/backlog/engine-push-scoping.md`, and current source on `working-connection`.
**Method:** the audits explain *why* a fix exists; every behavior contract below was
verified against the CURRENT Dart source (not the audit text, which predates later
refactors — e.g. the audited `gossip_engine.dart:1101` contiguity guard now lives in
`sync/application/delta_merger.dart`).

All file paths below are relative to `packages/gossip/` unless stated otherwise.

---

## 1. Compaction floor: storage contract

**Behavior contract.** `EntryRepository` tracks THREE monotonic per-(channel, stream)
values that must never regress and must survive process restarts:

1. **`latestSequence(channel, stream, author)`** — highest sequence number ever
   appended by `author`, independent of whether the entry still physically exists.
   "No surviving entries" is NOT 0 — it is whatever the high-water mark was before
   pruning.
2. **`getVersionVector(channel, stream)`** — the per-author map of (1), used to
   generate digests and `since` vectors. Also monotonic; derived from a cache, never
   from `SELECT MAX(sequence) FROM survivors`.
3. **`getCompactionFloor(channel, stream)`** — per-author highest sequence NO LONGER
   obtainable from this node (pruned by retention, or adopted via `adoptVersionFloor`
   — see item 2). Empty for an author never compacted. Also monotonic; reset ONLY
   when the stream identity itself is retired (`clearStream`/`clearChannel`/`clearAll`
   — never by `removeEntries`).

A persistent implementation MUST store (2) and (3) as separate rows/columns from the
entries themselves — deriving them from surviving rows silently reintroduces
resurrection (peers re-sent pruned entries forever) and sequence reuse (new local
entries permanently invisible to peers whose VV already covers the old numbers).

**Where it lives in Dart.**
- Contract: `lib/src/sync/domain/interfaces/entry_repository.dart:42-64` (Critical
  Invariants doc block), `:145-154` (`latestSequence`), `:202-214`
  (`getVersionVector`), `:216-230` (`getCompactionFloor`).
- Reference impl: `lib/src/sync/infrastructure/in_memory_entry_repository.dart` —
  three parallel maps: `_storage` (entries), `_latestSequenceCache` (2),
  `_compactionFloorCache` (3), all keyed `ChannelId → StreamId → NodeId → int`.
  `removeEntries` (`:210-239`) raises `_compactionFloorCache` for pruned authors and
  explicitly does NOT touch `_latestSequenceCache` (comment at `:233-238` states why).
- `appendAll` is all-or-nothing (interface `:59-63`; impl validates the whole batch
  before mutating anything, `:138-170`).

**Dart tests.**
- `test/sync/infrastructure/in_memory_entry_repository_semantics_test.dart` —
  duplicate/monotonicity semantics.
- `test/sync/application/gossip_engine_compaction_floor_test.dart` — `responder side`
  group pins floor computation end-to-end.
- `test/coordinator/event_stream_compaction_test.dart` — `'reports the real version
  vectors, and compaction never regresses...'`.

**Priority:** compaction-critical.

---

## 2. Late-joiner lockout fix: floor adoption

**Behavior contract.** A `DeltaResponse` carries an optional per-author `floor`
(`VersionVector`, default empty). Exact rules:

- **Responder side** (`handleDeltaRequest`): computes its full compaction floor, then
  reports only the portion the REQUESTER is still behind (`request.since[author] <
  floor[author]`). A requester already at/above the floor gets an empty floor field —
  the common case, and it's omitted from the wire entirely to save bytes.
- **Requester side** (`DeltaMerger._mergeInner`): **only when the response is
  `solicited`** (answers a request the caller was tracking in its pull tracker) AND
  `floor.entries.isNotEmpty`, calls `adoptVersionFloor` — which raises BOTH the local
  high-water mark (`getVersionVector`/`latestSequence`) AND the local compaction
  floor (`getCompactionFloor`) for each author in the claim, but only where the
  claimed floor exceeds the current high-water mark (never regresses, never
  double-applies). This happens **before** the contiguity filter runs, in the same
  merge call — so the just-adopted range no longer looks like a gap to entries above
  it.
- **Unsolicited responses (reactive pushes) MUST NOT adopt a floor** — a peer we
  never asked can't be trusted to make us skip history that might still be
  obtainable elsewhere. The `solicited` flag is decided by the CALLER (pending-pull
  tracker state), never by trusting the sender's own claim.
- A separate, related mechanism: **`_adoptClaimedAuthorshipFloor`** — if a peer's
  digest claims a HIGHER sequence for OUR OWN authorship than our local store has
  (channel/stream identity was removed and recreated, or local storage was reset),
  the requester adopts that as a sequence floor too, so new local appends allocate
  past the peer's claim instead of colliding with stale history under one entry
  identity.

**Where it lives in Dart.**
- Responder: `lib/src/sync/application/gossip_engine.dart:1400-1439`
  (`handleDeltaRequest` computes `fullFloor` then `_reportableFloor`).
- Requester adoption: `lib/src/sync/application/delta_merger.dart:130-150`
  (`_mergeInner`, the `if (solicited && response.floor.entries.isNotEmpty)` block —
  comment there states the ordering requirement explicitly: "BEFORE filtering").
- Authorship-floor variant: `gossip_engine.dart:1339-1362`
  (`_adoptClaimedAuthorshipFloor`).
- Repository primitive: `entry_repository.dart:232-248` (`adoptVersionFloor` doc);
  impl `in_memory_entry_repository.dart:286-307`.
- Wire: `lib/src/sync/domain/messages/delta_response.dart:47-56` (`floor` field doc);
  codec omits it when empty and defaults it to empty on decode for legacy senders —
  `lib/src/sync/infrastructure/sync_message_codec.dart:119-121, 256-268`.

**Dart tests.**
- `test/sync/application/gossip_engine_compaction_floor_test.dart` — `'a solicited
  response with a floor is adopted...'`, `'an UNSOLICITED response cannot move our
  floor'`, `'a repeated identical floored response is idempotent'`, `'a peer
  claiming sequences under OUR authorship...'`, `'two authors pruned to different
  depths...'` (multi-author independence), `'the responder compacts AFTER the
  requester sends its DeltaRequest but BEFORE...'` (mid-sync race), `'late joiner
  converges with a compacted responder (the lockout scenario)'`.
- `test/sync/application/delta_merger_test.dart` — `group('DeltaMerger — floor
  adoption')`: `'solicited floor adoption raises the mark'`, `'unsolicited floor is
  IGNORED'`.
- `test/integration/sync/compaction_late_joiner_test.dart` (full-DSL, real
  Coordinator): `'late joiner vs compacted responder: floor adoption,
  content-checked, and traffic quiesces after convergence'`.

**Priority:** compaction-critical (this is COR3-1's fix).

---

## 3. Contiguity guard + gap reporting

**Behavior contract.** `DeltaMerger._selectContiguousEntries` accepts, per author,
only the contiguous run starting at `ourVersion[author] + 1`; entries at or below our
version are silently skipped as already-held, and the first entry that breaks
contiguity stops acceptance for that author (a `ContiguityGap` is recorded, not
raised, at that point — this is the invariant floor adoption (item 2) exists to
avoid tripping in the compaction case). Entries are grouped and sorted per author
first so a mixed-author batch doesn't cross-contaminate.

Gap reporting is asymmetric by `solicited`:
- **Solicited** gap (we asked for everything since our VV, and a hole showed up
  anyway) is always anomalous → `LogLevel.warning` + `ChannelSyncError` via
  `ErrorCallback`, but deduped: reported once per
  `(peer, channel, stream, author, expectedNext)` key so a persistent hole doesn't
  spam every round. Cleared on peer disconnect/removal
  (`clearReportedGapsForPeer`/`clearReportedGaps`) so a fresh connection gets a fresh
  diagnosis window.
- **Unsolicited** gap (a reactive push naturally races normal anti-entropy) is
  routine → trace-level log only, no error.

A fully-dropped batch (`newEntries.isEmpty` after filtering) returns cleanly with no
merge — this must NOT be a silent no-op in the sense of hiding the gap; the gap
report above is what makes it diagnosable.

**Where it lives in Dart.** `lib/src/sync/application/delta_merger.dart:239-297`
(`_selectContiguousEntries`), `:299-362` (`_reportContiguityGaps` +
`_reportedGaps` dedup set), `:404-420` (`clearReportedGaps`/`clearReportedGapsForPeer`).

**Dart tests.** `test/sync/application/delta_merger_test.dart`: `group('DeltaMerger —
contiguity guard')`, `group('DeltaMerger — gap reporting')` — `'solicited gaps emit
the error once per position (dedup)'`, `'unsolicited gaps only trace-log — no
error'`.

**Priority:** compaction-critical (the guard is what makes floor adoption necessary
in the first place — port both together or neither is safe alone).

---

## 4. Version vectors never regress on compaction

**Behavior contract.** Already stated in item 1's contract — restated here for the
digest/since angle specifically: because `getVersionVector` is a monotonic
high-water mark independent of physical survivors, `generateDigest` and
`DeltaRequest.since` always advertise the FULL history the node has ever seen, not
just what it can currently serve. This is by design — it's what lets a peer detect
"I'm behind" even for pruned ranges, which is the precondition floor adoption (item
2) resolves. Do NOT "fix" this by making the VV reflect only surviving entries; that
was the pre-remediation bug (H6 in the 2026-07-06 correctness audit) and doing so
independently reintroduces resurrection.

**Where it lives in Dart.** Same as item 1: `in_memory_entry_repository.dart:43-53`
(doc comment on `_latestSequenceCache` states the invariant directly), consumed by
digest generation in `gossip_engine.dart` (`_computeVersionVector`, called around
`:1300` in `handleDigestResponse`) and by `handleDeltaRequest`'s `computeDelta`.

**Dart tests.** `test/coordinator/event_stream_compaction_test.dart` (title states
the guarantee directly); `test/sync/application/gossip_engine_compaction_floor_test.dart`
asserts `vv[authorA]` after floor adoption in several groups.

**Priority:** compaction-critical.

---

## 5. Transitive floors, returning peer, prune-all

**Behavior contract — the key non-obvious mechanism.** `adoptVersionFloor` (item 2)
doesn't just raise the adopter's high-water mark; it ALSO raises the adopter's own
`_compactionFloorCache` entry for that author (`in_memory_entry_repository.dart:298-306`:
`streamCache[author] = seq; streamFloor[author] = seq;` — both maps updated
together). This means a peer B that adopted a floor from A will itself report that
same floor when SERVING a delta request from C — with zero special-casing. Transitive
propagation (A compacts → B adopts → C adopts from B, never talking to A) falls out
of the single mechanism for free; there is no separate "propagate floor" code path.
Port this as one operation that touches both the high-water and floor maps
atomically, or the transitive case silently breaks even though the direct case
still passes.

**Other pinned scenarios (all in the integration suite, real Coordinator + simulated
network — not unit harnesses, because staging these needs real peer disconnect/
reconnect):**
- **Returning peer below the floor:** a peer that was online, holds entries
  1..3 itself, disconnects, misses the sender compacting past its position, then
  reconnects. It must KEEP its own already-held 1..3 (nothing deletes a peer's own
  copy just because the sender later compacted) AND adopt the floor to accept new
  survivors (7..8) — with the pruned 4..6 range correctly absent and no error
  surfaced (skipping via floor adoption is designed behavior, not a fault).
- **Prune-all then new appends:** `CountBasedRetention(0)` is legal and prunes
  every entry (see item 8). A peer joining after prune-all adopts a pure floor with
  zero survivors ("converged-empty"), and a SUBSEQUENT new append from the pruned
  node must reach the peer contiguously starting right after the adopted floor —
  proving the floor isn't a dead end for future writes.
- **Compaction landing mid-sync:** compaction racing an in-flight `DeltaRequest`
  (compact happens between request-send and request-handle) must still produce a
  response with the correct floor computed at HANDLE time, converge the requester,
  and leave no pending-request dedup-flag wedge blocking a follow-up round.

**Where it lives in Dart.** Mechanism: `in_memory_entry_repository.dart:286-307`.
Scenarios are integration-level, not a single source location.

**Dart tests.** `test/integration/sync/compaction_late_joiner_test.dart` — all four
tests: `'late joiner vs compacted responder...'`, `'transitive floor propagation: C
joins via B only and never talks to A...'`, `'returning peer below the floor:
reconnect after the responder has compacted past the peer's last-known position'`,
`'prune-all then new appends: a floor-only peer with no entries still accepts new
contiguous history'`. Mid-sync race is pinned at the unit level too:
`gossip_engine_compaction_floor_test.dart` — `group('compaction mid-sync race')`.

**Known adjacent nuance (not a bug, document deliberately in the port):** the
reactive push path (debounced push-on-write) freezes entries at append time but
picks recipients at flush time, and never re-consults the repository or the
compaction floor in between — so an unflushed push can in principle hand a peer
entries the sender no longer durably holds. Benign today (entries are immutable;
anti-entropy repairs any mismatch) but worth a deliberate decision in the port
rather than an accidental one. See `docs/backlog/engine-push-scoping.md`.

**Priority:** compaction-critical (transitive case) / robustness (returning-peer,
prune-all, mid-sync race — regression traps, not independent bugs).

---

## 6. OBS-3: digest budgeter response cursor rotation

**Behavior contract.** When a node's full digest set (or the flattened
`(channel, stream)` list a responder needs to answer with) doesn't fit
`maxMessageBytes`, `DigestBudgeter` selects a byte-budgeted, round-robin-rotated
WINDOW instead of failing or silently truncating the same tail forever. There are
**two independent cursors**, not one shared cursor:
- `_requestCursor` — advances only via `fitRequest` (this node's own outbound digest
  request cadence).
- `_responseCursor` — advances only via `fitResponse` (however often peers ask this
  node to respond).

Sharing one cursor would let one side's advance silently skew the other's coverage —
this was the actual OBS-3 bug (a paused/serve-only responder with over-budget VVs
truncated the same tail forever because the only cursor in use was driven by
requests it never issued). Each cursor advances by the number of items CONSUMED
(including skipped-as-oversized items), wrapping modulo the flattened list length. A
single stream digest that alone exceeds the budget is skipped and reported as an
`OversizedDigest` diagnostic rather than blocking the whole message every round.

**Where it lives in Dart.** `lib/src/sync/application/digest_budgeter.dart` —
`_requestCursor`/`_responseCursor` fields (`:62-72`), `fitRequest` (`:88-102`),
`fitResponse` (`:110-118`), the shared `_fit` windowing logic (`:143-194`).

**Dart tests.** `test/sync/application/digest_budgeter_test.dart` —
`group('DigestBudgeter cursor independence')`: `'a fitted request does not advance
the response cursor, and a fitted response does not advance the request cursor'`;
`group('DigestBudgeter.fitRequest over-budget window selection')`; `group
('DigestBudgeter alone-over-budget stream handling')`.

**Priority:** wire-efficiency (prevents a specific starvation pattern, not a
correctness bug — but the scenario coverage backlog doc flags this fix as landing
"alongside" the compaction scenario suite, so treat it as compaction-adjacent).

---

## 7. StreamCompacted event + auto-compaction loop

**Behavior contract.**
- `ChannelService.compactStream(channelId, streamId, {resetMaterializers = true})`
  applies the stream's `RetentionPolicy`, removes pruned entries via
  `EntryRepository.removeEntries`, and — **only when entries were actually
  removed** (`toPrune.isNotEmpty`) — emits `StreamCompacted(channelId, streamId,
  CompactionResult, occurredAt)` through `onEvent`. A no-op pass (nothing to prune:
  no repository, no policy, retain-all policy, empty stream, or every entry
  survives) returns `null` and emits nothing.
- `compactAll()` iterates every channel and every non-retain-all stream, calling
  `compactStream` per stream, WITH PER-STREAM TRY/CATCH: one throwing retention
  policy or storage failure emits a `StorageSyncError` for that stream and moves on
  — it must not starve every stream after it in iteration order on every periodic
  pass (this was COR3-15).
- `Coordinator` runs `compactAll` on a `GenerationScheduler` (see item 10) gated by
  `CoordinatorConfig.compactionInterval` — **default 5 minutes**, disabled by `null`
  or `Duration.zero`, requires a `timePort` (inactive in local-only mode). A
  scheduling failure (the timer mechanism itself breaking) stops the loop
  deliberately rather than retrying, and reports via `onSchedulingError` — the
  caller must `stop()`/`start()` the coordinator to resume it (this is
  `GenerationScheduler`'s asymmetric failure policy, item 10).
- `CompactionResult` carries `entriesRemoved`, `entriesRetained`, `bytesFreed`,
  `baseVersion` — note `baseVersion` is computed AFTER pruning (the VV, per item 1's
  monotonicity, is unaffected by the prune, so `oldBaseVersion`/`newBaseVersion`
  would be provably equal if both were tracked — the audit's MIN-9/OBS-9 finding;
  current `CompactionResult` only exposes one `baseVersion` field, already
  reflecting that resolution).

**Where it lives in Dart.**
- `lib/src/sync/application/channel_service.dart:645-699` (`compactStream`),
  `:704-731` (`compactAll`, try/catch per stream at `:717-728`).
- `lib/src/coordinator/coordinator.dart:421-451` (`_startCompaction`, builds the
  `GenerationScheduler` lazily), `:455-457` (`_stopCompaction`).
- `lib/src/coordinator/coordinator_config.dart:134-149` (`compactionInterval` doc),
  `:175` (default `Duration(minutes: 5)`).
- Event: `lib/src/sync/domain/events/sync_events.dart:133-144` (`StreamCompacted`).

**Dart tests.**
- `test/coordinator/coordinator_compaction_test.dart` — `'streams are compacted per
  their retention policy on the interval'`, `'auto-compaction publishes
  StreamCompacted on coordinator.events'`, `'auto-compaction is disabled when
  compactionInterval is null'`, and the scheduling-failure group: `'a delay failure
  emits exactly one scheduling error and the loop stays dead until the next
  stop/start cycle'` (asserts `coordinator.compactionSchedulerForTesting!.isRunning`
  directly, not just error-stream absence — a retrying-but-no-op scheduler would
  pass a weaker assertion).
- `test/sync/application/channel_service_compaction_events_test.dart` — `'compacting
  a stream that removes entries emits exactly one [event]'`, `'a no-op compaction
  (nothing removed) emits nothing'`.
- `test/sync/application/channel_service_compaction_isolation_test.dart` —
  `'compactAll isolates a throwing stream: later streams still compact'`.
- `test/sync/application/channel_service_append_compaction_race_test.dart` — `'an
  append racing an in-flight compaction on the same stream: neither...'`.

**Priority:** compaction-critical (the loop is what makes floor adoption reachable
in practice — without it, compaction only happens via explicit app calls).

---

## 8. Retention policy validation: runtime throw vs `const` + `assert`

**Behavior contract — and WHY the three built-in policies are inconsistent on
purpose.** `assert` is stripped from Dart release/AOT builds entirely. A retention
policy validated only by `assert` would pass its bad input silently in production
and then prune destructively on the next compaction pass. The three built-ins split
on whether `assert` alone is safe:

- **`TimeBasedRetention(Duration maxAge)`** — NOT `const`; constructor body throws
  `ArgumentError` unconditionally if `maxAge.isNegative`. A negative `maxAge` would
  move the compaction cutoff into the future, pruning every entry on the next pass —
  and `assert` being stripped in release mode means it would do so silently. A
  `const` constructor can't have a body (only initializer-list assigns/asserts), so
  `const` was traded away specifically to get a check that survives every build
  mode.
- **`CompositeRetention(List<RetentionPolicy> policies)`** — same reasoning, same
  trade: NOT `const`, throws `ArgumentError` if `policies.isEmpty` (an empty
  composite has union-of-nothing semantics = prunes everything).
- **`CountBasedRetention(int maxEntriesPerAuthor)`** — KEPT `const` and `assert`
  (`assert(maxEntriesPerAuthor >= 0, ...)`), unlike the other two. This is safe
  specifically because `compact()` passes the count straight to `List.take(n)`, and
  `take`'s own bounds check (`RangeError.checkNotNegative` in `dart:_internal`) runs
  UNCONDITIONALLY in every build mode, including AOT with asserts stripped —
  verified empirically in the Dart source comment (`dart compile exe` still throws
  `RangeError` from `[x].take(-1)`). Since `take`'s check is already a build-mode-
  independent backstop, there's nothing to gain by giving up `const` here the way
  the other two do. `maxEntriesPerAuthor: 0` is explicitly LEGAL and deliberately
  prunes everything (used by the prune-all integration scenario, item 5).

**Port implication:** in Kotlin, `assert` behaves differently (JVM `-ea` flag,
off by default in production, not silently stripped from bytecode the way Dart's
AOT compiler strips it) — so the exact mechanism doesn't transfer, but the
underlying decision procedure does: **for every retention policy constructor, ask
"does some other code path already throw unconditionally on this bad input in every
runtime mode?" If yes, a cheap assert-equivalent is fine. If no, add an explicit
unconditional validation that survives whatever Kotlin's release/production
configuration is** (there is no Dart-AOT-style silent-strip equivalent to specifically
guard against in Kotlin/JVM, but the equivalent risk is e.g. a `require()` that
gets optimized away only if you're doing something unusual — verify, don't assume
parity).

**Where it lives in Dart.** `lib/src/sync/domain/interfaces/retention_policy.dart` —
`TimeBasedRetention` constructor + comment `:73-93`, `CountBasedRetention` constructor
+ comment `:123-142`, `CompositeRetention` constructor + comment `:186-205`.

**Dart tests.** `test/sync/domain/interfaces/retention_policy_test.dart` —
`group('constructor guards')`: `'TimeBasedRetention rejects a negative maxAge with
ArgumentError...'`, `'CountBasedRetention accepts zero (deliberately prunes
everything...'`, `'CompositeRetention rejects an empty policy list with
ArgumentError'`.

**Priority:** compaction-critical (silent prune-everything is a data-loss bug class,
not a robustness nicety).

---

## 9. Duplicate appends: throws, does not silently drop

**Behavior contract.** A duplicate `(author, sequence)` pair reaching
`EntryRepository` is a contract violation, not data to discard — it must throw
`StateError`, never silently skip. This applies to both:
- `append` (single entry) — throws `StateError` immediately if the pair already
  exists.
- `appendAll` (batch, used by the sync merge path) — validates the WHOLE batch
  (against the store AND within the batch itself) before mutating anything;
  any duplicate anywhere in the batch throws `StateError` and NOTHING in the batch
  is applied (all-or-nothing, not skip-and-continue). The insert loop itself runs
  without an `await` between entries specifically so a concurrent overlapping merge
  can't interleave a partial application despite the atomic contract (see item 3's
  `DeltaMerger` per-(channel,stream) chain serialization, which is the other half
  of this guarantee — the repository's own synchronous loop is necessary but not
  sufficient without the caller also serializing overlapping merges).
- The OLD (pre-remediation) contract silently dropped duplicates — this is
  explicitly called out as the bug class to avoid: "a duplicate reaching the
  repository is a bug that must surface," because silent drop is "how a
  sequence-allocation race loses an entry with no trace."

**Where it lives in Dart.**
- Contract: `entry_repository.dart:54-58` (Critical Invariant #2), `:59-63`
  (Invariant #3, `appendAll` atomicity), `:93-100` (`append` doc), `:102-114`
  (`appendAll` doc).
- Impl: `in_memory_entry_repository.dart:65-89` (`append`, throws at `:81-85`),
  `:137-170` (`appendAll`, batch-validates at `:143-159` before any mutation at
  `:161-169`).
- Caller-side dedup (belt-and-suspenders, not a substitute): `DeltaMerger` filters
  already-held/gapped entries BEFORE calling `appendAll` (item 3), so a
  well-behaved caller never actually trips the repository's throw in normal
  operation — the throw is the backstop for a caller bug or a genuinely racing
  duplicate.

**Dart tests.** `test/sync/infrastructure/in_memory_entry_repository_semantics_test.dart`
— `group('InMemoryEntryRepository duplicate handling')`: `'append throws on a
duplicate (author, sequence)'`. `test/sync/application/delta_merger_test.dart` —
`'duplicate/stale batches are filtered — no repository throw, no [error]'` (proves
the caller-side filter keeps normal duplicate/stale responses from ever reaching the
repository's throw path).

**Priority:** correctness (data-loss bug class if regressed to silent-drop).

---

## 10. Scheduler forking fix + zero-interval guard

**Behavior contract.** `GenerationScheduler` is the shared delay-based periodic-loop
idiom used by the gossip round loop, the SWIM probe loop, and the coordinator's
auto-compaction loop (item 7). It exists specifically to close a forking hazard: a
naive `delay().then(tick).then(scheduleNext)` loop forks into TWO concurrent loops
if `stop()` then `start()` happen within one interval — the pre-stop delay is still
pending and, when it eventually fires, ticks and reschedules right alongside the
freshly-started loop.

**The fix:** an integer `_generation` counter, bumped by every `start()` AND every
`stop()` (even a `start()` while already running bumps it — a restart never forks a
second loop because the previous generation's scheduled callback finds itself stale
and does nothing). Every scheduled callback captures its generation at schedule time
and checks it against the live `_generation` before doing ANYTHING (tick or
reschedule) — a stale callback silently no-ops instead of ticking.

**Failure policy is deliberately asymmetric** (port this distinction, not just the
generation-check mechanism):
- A `tick()` error (one round's business logic failing) → reported via
  `onTickError`, loop reschedules and tries again next interval. One bad round must
  not kill dissemination/compaction.
- A scheduling error (the underlying `TimePort.delay` future itself failing — a
  broken platform timer) → the scheduler STOPS ITSELF first (so `isRunning` stays
  truthful) and reports via `onSchedulingError`. Retrying a broken timer mechanism
  silently would leave `isRunning` claiming a loop that will never tick again.
  Callers must explicitly `stop()`/`start()` to resume (see item 7's coordinator
  test pinning this exact recovery path).

**The zero/sub-millisecond guard is a TEST-PORT contract, not a production-port
one** — worth flagging explicitly since the task description conflates them:
`InMemoryTimePort.schedulePeriodic` throws `ArgumentError` for
`interval.inMilliseconds <= 0`, because the deterministic-simulation port advances
time by discrete interval boundaries and a zero/negative interval would hang or
loop infinitely inside `advance()`. `RealTimePort.schedulePeriodic` has NO such
guard — it delegates straight to Dart's `Timer.periodic`, which has different
(acceptable) behavior for a zero-duration interval on a real event loop. **Port
implication:** if `gossip-kt` has an equivalent deterministic/virtual-time test
clock, IT needs the guard; the production `TimePort`/`Clock` implementation likely
doesn't need an equivalent — don't cargo-cult the guard onto the real-clock
implementation without checking whether the JVM's periodic-scheduling primitive has
the same degenerate-interval hazard.

**Where it lives in Dart.**
- `lib/src/shared/domain/services/generation_scheduler.dart` (whole file, 115
  lines) — `_generation` field `:70`, `start()` `:81-85`, `stop()` `:89-92`,
  `_scheduleNext` `:94-113` (the two failure branches at `:100-104` vs `:107-113`).
- Zero-interval guard (test port only): `lib/src/shared/infrastructure/in_memory_time_port.dart:79-105`.
- Not present in `lib/src/shared/infrastructure/real_time_port.dart:35-38`
  (delegates to `Timer.periodic` with no validation).

**Dart tests.** `test/shared/domain/services/generation_scheduler_test.dart` —
`'ticks fire after nextDelay elapses and reschedule after the tick'`, `'nextDelay is
re-evaluated for every cycle'`, `'stop() makes the scheduled tick stale'`, `'stop()
during an in-flight tick prevents the reschedule'`, **`'restart while running forks
nothing'`** (the direct regression pin for the forking hazard), `'a tick error goes
to onTickError and the loop continues'`, plus a scheduling-error test. Coordinator-
level pin: `test/coordinator/coordinator_compaction_test.dart` — `'a delay failure
emits exactly one scheduling error and the loop stays dead until the next
stop/start cycle'`.

**Priority:** correctness (forking would double-fire compaction/gossip/probe rounds
— directly compaction-relevant since `compactAll` is not idempotent-free of cost,
though it IS idempotent in outcome; the bigger risk is doubled network traffic from
a forked gossip loop).

---

## 11. Materializer/compaction interaction: resetState, rebuild cursor, known open gap

**Behavior contract.**
- `ChannelService.compactStream(..., resetMaterializers = true)` — by DEFAULT, after
  pruning, calls `resetState(channelId, streamId)` → `MaterializationService.reset`
  → `_fullRebuild` for every materializer registered on that stream: calls
  `materializer.initial(isReset: true)`, then re-folds every SURVIVING entry from
  `EntryRepository.getAll` (pruned entries are gone from storage, so they're
  naturally excluded — no separate "skip pruned" logic needed in the fold itself).
  Callers can pass `resetMaterializers: false` to skip this (e.g. when the caller
  knows no registered materializer needs it).
- **Rebuild cursor:** `FoldCursor` (an opaque string, persisted via
  `StateMaterializer.save`) marks how far a materializer has folded. Normal
  operation resumes from the cursor (`_initialize`, folds only entries the cursor
  reports as strictly-after). A full rebuild always re-folds from scratch and
  produces a fresh cursor from the last entry.
- **Out-of-order triggers a full rebuild, not a cursor resume**, in TWO places: (a)
  `DeltaMerger` computes `containsOutOfOrderEntries` by comparing merged entries
  against the previous tail HLC (ties count as possibly-out-of-order — a rare extra
  rebuild beats silent divergence); (b) `MaterializationService._foldForState`
  branches on that flag even when the materializer is UNINITIALIZED (this half
  shipped as `dd16e29`, referenced in the backlog doc below) — an out-of-order
  batch arriving before first initialization forces `_fullRebuild` instead of
  `_initialize`-from-cursor, because a cursor comparison can't be trusted against an
  entry that may sort below a cursor it was never actually folded past.
- **KNOWN OPEN GAP — do not port as a hidden feature:** the "this materializer needs
  a full rebuild" decision is **entirely in-memory** (a function parameter, not
  persisted state). If a full rebuild's OWN save fails (`_commit` catches, marks
  `isInitialized = false`, rethrows) or the process restarts mid-rebuild, the NEXT
  operation goes through `_initialize` (resume-from-cursor) using whatever cursor
  was last successfully persisted — silently skipping the out-of-order entries
  below that cursor that motivated the rebuild in the first place. Two devices can
  then show different materialized state indefinitely with no error, even though
  the underlying entry log is fully synced and correct. The fix (not yet
  implemented in Dart) is to persist "needs rebuild" durably — e.g. a cursor value
  that explicitly means "rebuild from the beginning," so a crash mid-rebuild is
  indistinguishable from a rebuild that never started. **This is a materializer
  CONTRACT change, not an internal fix — don't design the Kotlin materializer
  interface without accounting for it, since retrofitting it later is a breaking
  change for the same reason it's deferred in Dart.**

**Where it lives in Dart.**
- `lib/src/sync/application/channel_service.dart:645-699` (`compactStream`,
  `resetMaterializers` param and the `resetState` call at `:667-669`).
- `lib/src/sync/application/materialization/materialization_service.dart:120-130`
  (`reset`), `:164-200` (`_foldForState`, the uninitialized+out-of-order branch at
  `:172-192`), `:207-243` (`_initialize`, cursor-based resume), `:245-264`
  (`_fullRebuild`), `:304-321` (`_commit`, the save-first-then-mutate ordering and
  the `isInitialized = false` on save failure).
- Backlog doc for the open gap (read this before designing the Kotlin materializer
  contract): `docs/backlog/engine-materializer-rebuild-marker.md`.

**Dart tests.** Materializer out-of-order/rebuild tests live outside the compaction
test files proper (search `test/sync/application/materialization/` for the
cursor/rebuild suite — not enumerated here since this item's priority is the
compaction-triggered path, which is `channel_service_compaction_events_test.dart`
and `channel_service_compaction_isolation_test.dart`, already cited in item 7).

**Priority:** compaction-critical (the reset-on-compact call path) / the open gap
itself is correctness (silent data divergence) but explicitly NOT yet fixed in
Dart — track it as a design input, not a behavior to replicate as "done."

---

## 12. Wire-level contracts (only relevant if the two libraries ever interop)

**These are internal implementation choices, not a documented cross-language wire
protocol** — nothing in the repo suggests gossip-kt and gossip (Dart) are meant to
gossip with each other directly today. Listed for completeness in case that ever
changes; treat as "would need to match" rather than "part of the port."

- **Payload encoding:** entry payloads are base64-encoded strings in the JSON wire
  format (not a JSON int array) — chosen because base64 is ~1.33 chars/byte vs
  ~3.6 chars/byte for a JSON int list, and payload size dominates `DeltaResponse`
  size. `SyncMessageCodec._decodePayload` accepts BOTH the base64 string format and
  a legacy JSON int-list format for backward compatibility with older senders (out-
  of-range bytes in the legacy format are rejected as corruption, not truncated mod
  256). `sync_message_codec.dart:156-169` (encode), `:319-335` (decode, dual-format).
- **Message framing:** `[1-byte type][JSON payload]`, decode returns `null` (not an
  error) for a type byte owned by a sibling wire family (membership vs sync) so the
  caller falls through to the other codec; an UNKNOWN type byte (owned by neither
  family) throws — `sync_message_codec.dart:38-59`.
- **Floor field wire compatibility:** `DeltaResponse.floor` is omitted from the JSON
  entirely when empty (the common case, saves bytes) and defaults to
  `VersionVector.empty` when absent on decode — meaning an OLDER (pre-floor) sender
  interoperates fine with a newer receiver; there is no version negotiation.
  Similarly `hasMore` defaults to `false` when absent. `sync_message_codec.dart:110-122`
  (encode), `:255-269` (decode).
- **Payload size cap:** derived, not hardcoded — `SyncMessageCodec.maxEntryPayloadForBudget(budgetBytes)`
  inverts the base64 + JSON envelope overhead (`_entryEnvelopeOverhead = 512` bytes,
  conservative) to compute the largest raw payload guaranteed to fit one
  `DeltaResponse` under the budget. At the default `maxMessageBytes = 30 * 1024`
  (30KB, `coordinator_config.dart:175`), this yields **~22.1KB**
  (`(30720-512)/4*3 = 22656` bytes) — `EventStream.append` rejects anything larger
  with an `ArgumentError` at write time (`channel_service.dart:349-360`) rather than
  livelocking at sync time. `sync_message_codec.dart:196-213`.
- **The 32KB figure** referenced in project memory is the TRANSPORT frame ceiling
  (Android Nearby Connections / the BLE frame codec in `gossip_nearby`/
  `gossip_bluey`), not this package's own budget — `maxMessageBytes` defaults to
  30KB specifically to leave headroom under that 32KB ceiling
  (`coordinator_config.dart:118-129` doc comment states this explicitly). These are
  DIFFERENT numbers for a reason; don't conflate them in the port.

**Where it lives in Dart.** `lib/src/sync/infrastructure/sync_message_codec.dart`
(whole file), `lib/src/coordinator/coordinator_config.dart:118-129, 175`.

**Priority:** wire-efficiency / not port-relevant unless cross-language interop is
ever a real goal (flag this explicitly — don't spend Kotlin-port effort matching
byte-for-byte wire format unless that's actually a requirement).

---

## 13. Other 2026-07 audit fixes plausibly present (as bugs) in a pre-2026-07 port

One line each — Dart pointer for verification, not full detail (out of scope for
this compaction-focused inventory; each of these deserves its own pass if/when
non-compaction remediation work on gossip-kt starts).

- **H1 delta livelock** (byte budget + poison-entry isolation) — `gossip_engine.dart`
  `_fitDeltaToBudget` (search for it) + `sync_message_codec.dart:196-213`.
- **H2 scheduler forking** — item 10 above (`GenerationScheduler`).
- **H5 append race / silent loss** — per-stream `KeyedTaskChain` in
  `channel_service.dart:375` (`_appendChain`) serializes appends to the same
  stream; duplicate appends throw (item 9).
- **H6 compaction VV regression** — items 1 & 4 above.
- **M3 total order (LogEntry.compareTo)** — `entry_repository.dart:34-40, 118-122,
  133-136` mandate `(timestamp, author, sequence)` order, not timestamp alone (HLC
  ties ordered by arrival diverge across peers for non-commutative folds).
  `in_memory_entry_repository.dart:102-121` (`_findInsertIndex`, binary search on
  full `compareTo`).
- **COR3-1 → item 2 & 3 above** (the CRITICAL itself).
- **COR3-8 EntryRepository interface doc rot** — fixed; current
  `entry_repository.dart` Critical Invariants block (item 1) states the real
  contract, not the pre-remediation "0 if none exist" language the audit found.
- **COR3-9 overlapping-merge interleaving** — `DeltaMerger`'s per-(channel, stream)
  `KeyedTaskChain` (`delta_merger.dart:94-108, 115-124`) serializes merges; doc
  comment at `:100-108` states the interleaving hazard directly.
- **COR3-13 one throwing materializer starves siblings** — `MaterializationService.foldEntries`
  enqueues ALL materializers before awaiting any (`Future.wait`, not sequential
  awaits) — `materialization_service.dart:99-118`, comment explains why.
- **COR3-15 compactAll no per-stream isolation** — item 7 above (fixed with
  try/catch per stream).
- **COR3-16 createChannel silently resets an existing aggregate** — fixed to
  get-or-create semantics, no-op + no events when the channel already exists —
  `channel_service.dart:148-163`.
- **COR3-27 HLC-tie blind spots** — `DeltaMerger`'s out-of-order check uses `<=`
  against the previous tail (ties count as possibly-out-of-order) —
  `delta_merger.dart:190-197`; materializer cursor comparison likewise uses full
  entry order not raw timestamp (item 11).
- **COR3-10 unbounded HLC drift** — `CoordinatorConfig.hlcMaxDrift` (default 1 hour)
  — `coordinator_config.dart:150-159`; bounds how far a remote peer's clock can drag
  the local HLC forward, protecting `TimeBasedRetention` from a single
  misconfigured device clock pruning everything mesh-wide.
- **MIN-8 VersionVector map aliasing** — audit flagged this as still-open in
  2026-07-08; CURRENT `version_vector.dart:36-53` constructor copies the input map
  via `_normalized` (never aliases the caller's map) and drops explicit zero
  entries so structural and semantic equality can't diverge — appears to be fixed
  since the audit; verify independently if porting this exact history matters.
- **MIN-6 / retention validation** — item 8 above.

**Priority:** correctness (each, individually) — listed for triage, not detailed
here.

---

## Summary table

| # | Item | Priority |
|---|---|---|
| 1 | Compaction floor storage contract | compaction-critical |
| 2 | Late-joiner lockout fix (floor adoption) | compaction-critical |
| 3 | Contiguity guard + gap reporting | compaction-critical |
| 4 | Version vectors never regress on compaction | compaction-critical |
| 5 | Transitive floors / returning peer / prune-all | compaction-critical (transitive) / robustness (rest) |
| 6 | OBS-3 digest budgeter cursor rotation | wire-efficiency |
| 7 | StreamCompacted event + auto-compaction loop | compaction-critical |
| 8 | Retention policy validation (throw vs assert) | compaction-critical |
| 9 | Duplicate appends throw (not silent drop) | correctness |
| 10 | Scheduler forking fix + zero-interval guard | correctness |
| 11 | Materializer/compaction interaction + open rebuild-marker gap | compaction-critical (reset path) / correctness (open gap, NOT fixed) |
| 12 | Wire-level contracts | wire-efficiency / not port-relevant unless interop is a goal |
| 13 | Other 2026-07 audit fixes (one-liners) | correctness |
