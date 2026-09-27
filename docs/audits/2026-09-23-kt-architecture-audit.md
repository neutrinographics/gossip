# gossip-kt architecture audit (2026-09-23)

**What this is.** A full clean-architecture, cohesion and coupling audit
of the Kotlin twin, read at the head of gossip-kt PR #9 (`feature/item-9-bump`,
b55da0b, suite 1,093 green). Rubric: the clean-architecture skill's
dependency rule and component principles, plus the repository's own
rules from its CLAUDE.md (bounded contexts, the one ACL concession, lock
placement, pure domain, "data, not ports", comments say why). The
domain-model pass (DDD rubric, written logic only) and the code-quality
pass follow this one, after its fixes land. The owner asked for the
audit after eight rounds of external review on one PR kept surfacing
items; this report is the findings list for approval, and nothing here
has been changed.

**Method.** Ground truth first: the import graph, the two machine-checked
gates, sizes per area (main source 9,861 lines in 130 files; tests
23,301 lines in 101 files). Then five read-only deep-readers, one per
territory, each reading its files in full against the rubric. Then
every claim re-verified against source by the orchestrator: each cited
line opened, each seam (dead code, duplication, reachability) followed
to every hop, and reachability on the one production consumer
(opendoor-api) checked by grep. About 140 citations were checked; none
was fabricated; a handful of line ranges were loose by a few lines and
are corrected below. Severity is re-graded on one ladder: Critical is
unsound now, Major is a real defect in what the library exists to do,
Moderate is a structural gap that will bite, Minor is real, cheap and
low-risk, Observation is recorded with no action. A defect unreachable
today grades as the hazard it is.

**No prior architecture audit of gossip-kt exists.** The baseline is the
tracked debt in the gossip repo's backlog: `kt-application-types-against-domain`
(application classes import their `Synchronized*` wrappers), the register
row "Wire budget arithmetic's home" (`CoordinatorConfig` imports the sync
codec for the envelope constant), and the recorded `PendingPullTracker`
stateful-domain-service smell. Where a finding is that debt, it is not
re-reported; where it is worse than described, this says so.

## Verdict

The architecture is sound at the boundaries and loose in the middle.
The bounded contexts hold mechanically: `shared/` is a true leaf,
`sync/` and `membership/` never name each other outside the one ACL
adapter, the composition root is the only sink, and both gates are
honest (the lock-placement debt rows match the code line for line). The
domain ports the engines depend on are narrow and domain-owned, the
identifier invariant and the byte-order comparison each have exactly one
home, cancellation discipline is uniform, and the test harness runs
real production code end to end.

Inside the contexts the picture is weaker, in three ways that recur
across every territory:

1. **The application layer wires itself.** Engines name concrete codecs,
   construct their own `Synchronized*` collaborators with defaults, and
   hold framework primitives; the tracked debt item describes imports,
   but the code constructs. One infrastructure class imports its own
   application layer, a cycle.
2. **The clock is everywhere.** Forty-three `Instant.now()` reads sit in
   events, errors and aggregates while every class involved holds or
   could hold the `TimePort`, so nothing is comparable under a simulated
   clock and domain events carry two timestamps.
3. **Written but not wired.** Nine configuration knobs, eleven error
   types and events, a materializer disposal, an incarnation chain and a
   stream config exist in the public surface with no producer or reader.

One finding is Major and reachable in production today: the channel
aggregate store is an unguarded map wired as the default, and
`createChannel` is a check-then-act outside the per-channel lock that PR
#9 just added, while the server creates a channel per joining phone. The
rest is 27 Moderate findings (structural, will bite on the next change
in that area), 22 Minor, and 4 Observations. The good design is worth
protecting on purpose; the list of what is healthy is below.

**About PR #9.** Nothing in the branch's diff breaks the rubric. The
branch fixed a real lost-update (the per-channel mutex), extended the
accepted-debt rows correctly, and put the identifier invariant in one
place. One stale comment on the branch says kt has no byte cap after the
branch added one (KCA1-39); that is the only item here the PR itself
should carry.

## Findings

IDs are `KCA1-n` (Kotlin clean-architecture audit, first). Paths are
under `src/main/kotlin/com/neutrinographics/gossip/` unless stated;
test paths under `src/test/kotlin/com/neutrinographics/gossip/`.

### MAJOR

**KCA1-1 — The channel aggregate store is unguarded and `createChannel`
is a check-then-act outside the channel lock.** `InMemoryChannelRepository`
keeps its aggregates in a bare map with no synchronization, and
`Coordinator.kt:180` wires it as the default; `CachingChannelRepository`
has the same shape. `ChannelService.createChannel` (`ChannelService.kt:105-113`)
runs `findById` then `save` with no lock, while every other aggregate
write goes through `withChannel` under `channelLocks` (`:443`), whose own
KDoc names the harm: a stream registered by one joiner lost to another's
repeat lookup, after which the engine ignores that stream's deltas.
`compactStream` (`:301-313`) likewise reads, computes and removes holding
neither the channel lock nor the per-stream append lock. **Reachable:**
opendoor-api passes no channel repository, so it runs the default, and
`CoordinatorLifecycle.kt:94` and `:135` execute `getChannel(cid) ?:
createChannel(cid)` per connecting phone; two phones joining a new
channel at once race the map and the check. **Fix:** a `Synchronized*`
wrapper (or a guarded adapter) in `sync/infrastructure/` per the lock
rule; route `createChannel` through `channelLocks`; take the stream lock
in `compactStream` or document why it need not.

### MODERATE

**KCA1-2 — Both engines depend on concrete codecs, not the `MessageCodec`
port.** `GossipEngine.kt:28,82` types `codec: SyncMessageCodec` and uses
one method, `codec.encode` (`:926`), which the port in
`shared/domain/interfaces/MessageCodec.kt` declares.
`FailureDetector.kt:22,74` goes further: `codec: MembershipMessageCodec =
MembershipMessageCodec(WireVersion.V1)`, a constructing default that pins
the dialect inside the application layer. Not covered by the tracked
debt (that item is scoped to the `Synchronized*` wrappers). **Fix:** type
both against `MessageCodec`, no default; the composition root already
passes the instances (`Coordinator.kt:272`).

**KCA1-3 — Application classes construct their own `Synchronized*`
collaborators, which is worse than the tracked debt describes.**
`GossipEngine.kt:91-92` (`stalledRanges`, a defaulted constructor
parameter), `:104-106` (`timing`), `:161` (`pusher`), `:187`
(`pendingPullTracker`), `:206` (`reportedGaps`); `ReactivePusher.kt:37`
(`pushes`). The backlog item `kt-application-types-against-domain` says
the application layer *imports* the wrappers; its own fix sketch says
"application constructors take the pure type with no default; every
construction site passes the synchronized instance explicitly". The code
constructs five collaborators itself, so none can be substituted or
pre-seeded, and paying the debt touches these sites, not just imports.
**Fix:** as the item's sketch says; wire in `Coordinator.Companion`.

**KCA1-4 — `membership/application` and `membership/infrastructure`
form a cycle.** `SynchronizedPendingPingRegistry` (infrastructure) imports
the application layer it wraps, while the application layer imports the
wrapper. Infrastructure may depend on inner layers, but the inner layer
must not depend back. **Fix:** move the pure registry the wrapper
serializes into `membership/domain` (it is a registry of pending probes,
a domain concept), so the wrapper depends only inward.

**KCA1-5 — `GossipEngine` is 1,021 lines, `handleDeltaResponse` carries
eight concerns, and the plan's own extraction trigger has passed.**
`GossipEngine.kt:426-586` runs the pause gate, membership filter,
pull settlement, floor adoption, contiguity filtering, gap reporting,
canonical sort, HLC advance, append and notify, news, credit and
continuation in one method. Digest building (`:685-700`), request
computation (`:737-793`) and the merge path have no domain home, unlike
pacing, gaps, stalled ranges and pushes, which do. The Dart reference
hosts these in `DeltaMerger` and `DigestBudgeter`; the parity record E2
accepts their absence on one ground (no `KeyedTaskChain` needed), and
the kt plan that made the call set its own trigger: extract when the
pusher lands or the engine grows past taste. Both have happened.
Pagination (`hasMore = false`, `:394`) has nowhere to go but this method.
**Fix:** extract the merge path and the request/digest computation into
sync application services; restate E2 as "no `KeyedTaskChain`".

**KCA1-6 — A throwing materializer skips the engine's bookkeeping and the
merged event.** `GossipEngine.kt:544-561`: `onEntriesMerged` runs inside
the `NonCancellable` block; `recordNews()` and `recordAntiEntropy(...)`
follow it, and the continuation follows those. The callback is
`channelService.foldMergedEntries` → `MaterializationService.foldEntries`
→ `runIsolatedPerState`, which rethrows the first failure
(`MaterializationService.kt:197`). The coordinator reports the throw as
`PROTOCOL_ERROR` (`Coordinator.kt:435-447`), so it is not silent, but the
node then stretches its interval as if quiet, loses coverage credit and
abandons a multi-page drain, and the coordinator's `EntriesMerged`
emission (`Coordinator.kt:285-293`), which the server's health ledger
counts, never fires. Dart orders it the other way on purpose
(`delta_merger.dart:234-245`). The server registers five materializers.
**Fix:** bookkeeping before the notification, Dart's order.

**KCA1-7 — Scheduler liveness doubles as the ingestion policy.**
`GossipEngine.kt:213` defines `isRunning` as `scheduler.isRunning`, and
`:342`, `:362`, `:436` and `:842` gate reciprocal pulls, digest-response
pulls, delta ingestion and local-write pushes on it. `GenerationScheduler`
sets the flag false when `TimePort.delay` itself throws
(`GenerationScheduler.kt:26-36,88-94`). A scheduling failure therefore
turns the node serve-only: it answers digests and delta requests but
merges nothing, including reactive pushes, until `start()` is called,
and only the scheduling error is reported. **Fix:** a posture flag
separate from the loop's liveness.

**KCA1-8 — The wall clock is read in events, errors and aggregates while
a `TimePort` exists.** Forty-three `Instant.now()` reads library-wide.
Every sync domain event defaults `at = Instant.now()` and passes it to
`DomainEvent(at)`, so events carry two stamps; `GossipEngine` stamps six
errors from the wall clock while using `timePort.nowMs` for protocol time
three lines away (`:126,143,172,671,941,970` vs `:512,561,570,772`);
`ChannelService` stamps ten and falls back to
`Hlc(System.currentTimeMillis(), 0)` (`:208,302`, mirroring Dart);
`Coordinator.kt:414,430,443,557` and `FailureDetector.kt:121,132,469`
do the same. Under a simulated clock nothing is comparable with anything
else. **Fix:** an `Instant`-valued reading on `TimePort`; application
services stamp; events take `at` as a required argument; aggregates take
`now` as data.

**KCA1-9 — The materializer cursor is a bare `Hlc`; Dart replaced exactly
this with `FoldCursor`, and the divergence is unregistered.**
`MaterializationService.kt:53` (`var cursor: Hlc?`), `:287-291` folds
`timestamp > cursor`, `:301` and `:350` set it from timestamps alone.
Dart's value object states the defect (`fold_cursor.dart:9-16`): an entry
that ties the cursor's timestamp may or may not have been folded, so the
cursor carries timestamp, author and sequence. The live path is guarded
by the tail-tie rule (`GossipEngine.kt:547-553`); the hole is a crash
between `appendAll` and `save` with a tying entry, after which the next
`initialize` skips it forever. The server persists cursors
(`GroupMaterializer.kt:25,80` and four siblings). No row in `parity.md`
or the divergence register. **Fix:** port `FoldCursor`; until then, a
register row.

**KCA1-10 — Materializer state updates drop silently and a disposed
materializer's collectors never finish.** `MaterializationService.kt:63-69`:
`MutableSharedFlow<T>(extraBufferCapacity = 1)` with `tryEmit`'s result
discarded; with the default `SUSPEND` overflow it returns false whenever
a subscriber is one update behind. Dart's broadcast controller cannot
drop. `disposeChannel`/`disposeAll` (`:200-211`) remove state but never
complete the flow. The server does not consume `stateStream` today, so
this is a hazard, and a "no silent errors" violation. **Fix:**
`replay = 1, onBufferOverflow = DROP_OLDEST` (a latest-state stream is
what a view wants) and a completing dispose.

**KCA1-11 — The accepted per-materializer mutex is wider than its debt
row says and is silently non-reentrant.** The row
(`LockPlacementTest.kt:71-79`) sanctions a section that "suspends across
repository IO"; under `matState.mutex.withLock` (`:109,149,163`) the
service also calls the application's `initial` (`:270,321`), `fold` in a
loop (`:296,326,347`) and `save` (`:250,306,333`). A slow materializer
stalls every `getState`/`foldEntries` for that key with no timeout; a
`kotlinx.coroutines.sync.Mutex` is not reentrant, so a materializer whose
`save` or `fold` calls `getState` for its own key deadlocks, and neither
`StateMaterializer`'s KDoc nor the class warns. **Fix:** state the real
scope in the row; document the re-entrancy ban; consider Dart's
compute-outside, commit-inside split (`materialization_service.dart:197-198`).

**KCA1-12 — The Ping reply bypasses `safeSend`.** The coordinator's
router sends the Ack itself (`Coordinator.kt:585-589`:
`failureDetector.handlePing(message)`, then `membershipCodec.encode`, then
`effectiveMessagePort.send(message.sender, bytes)`), so the reply goes out
at the default `NORMAL` priority, without `recordMessageSent`, and a send
failure surfaces as the receive loop's generic `PROTOCOL_ERROR` instead
of the `PEER_UNREACHABLE` every other membership send reports through
`safeSend` (`FailureDetector.kt:457-475`). Two ways to reach one
operation: `FailureDetector.encodeMessage` is public and unused outside
the detector. The server's port ignores priority and reports zero
pending sends (`WebSocketMessagePort.kt:46-65`), so the priority half is
inert there; the bookkeeping and error-type halves stand. **Fix:** the
detector owns the reply (`handlePing` sends through `safeSend`); the
router only dispatches.

**KCA1-13 — Failure-detector thresholds and the status transition table
live in the application, with a read-decide-write race.** The detector
reads a peer's state, decides the transition from thresholds it holds,
and writes back, with the registry's lock released in between; Dart's
aggregate owns the transition. **Fix:** the transition rule on the
`Peer`/registry aggregate, taking `now` and the thresholds as data; the
application supplies readings.

**KCA1-14 — The recorded stateful-domain-service smell has five more
instances.** `PendingPullTracker` is on record. The same shape, a
mutable "domain service" that needs a `Synchronized*` wrapper to be
safe, also describes `HlcClock` and `GossipTimingPolicy`
(`sync/domain/services/`), `ProbeTargetSelector` and `ProbeTimingPolicy`
(`membership/domain/services/`), and `LoopGeneration`
(`shared/domain/services/`, two `var`s mutated by five methods, wrapped
by `SynchronizedLoopGeneration`). The owner's standing rule is pure DDD:
a domain service takes data and returns data. **Fix:** per class, either
make it pure (data in, data out, the caller holds the state) or name it
what it is (a small entity or a value the application owns); pay it
together with the recorded item.

**KCA1-15 — `GenerationScheduler` is an application orchestrator filed
under `shared/domain/services`.** `GenerationScheduler.kt:48-62` holds a
`CoroutineScope` and a `TimePort` and runs its own delay-and-tick loop
(`scope.launch { timePort.delay(...); tick() }`). CLAUDE.md's rule is
that domain services hold no IO and no clocks; the lock-placement gate
does not see `launch` or `delay`, so this passes it while breaking the
written rule and sets the precedent. Its generation bookkeeping is
already isolated in `LoopGeneration`. **Fix:** move the loop to an
application-layer primitive (or `coordinator/`) and leave the pure
generation state in the domain.

**KCA1-16 — Configuration the coordinator accepts but does not wire.**
`startupGracePeriod` and the probing holds are inert (Dart wires them);
`adaptiveTimingEnabled` is half-wired and its thresholds unvalidated;
`healthStatus()` returns a hardcoded `isHealthy = true`; `maxConnections`
(`CoordinatorConfig.kt:24`) has no reader and no Dart counterpart. Each is
a published promise the library does not keep. **Fix:** wire or delete
each; validate what stays.

**KCA1-17 — Coordinator events are `tryEmit` on a 100-slot buffer with
silent drops, and the server counts merges from that stream.**
`Coordinator.kt:285` emits `EntriesMerged` with `tryEmit` and discards the
result; opendoor-api's `CoordinatorLifecycle.kt:65` collects
`coordinator.events` into the health ledger's merge counts. A slow
collector undercounts production merges with no signal. **Fix:** report
a false `tryEmit` through `onError`, or suspend on `emit` from the
already-suspending call site.

**KCA1-18 — `Channel.compact` duplicates `compactAll` without its
safeguards.** The facade's per-channel compaction re-implements the
service's loop without the per-stream isolation and the unconfigured
store handling `compactAll` carries (`ChannelService.kt:337-364`). **Fix:**
one implementation on the service; the facade delegates.

**KCA1-19 — No sync-with-new-peer on `peers.add`; Dart has one, and the
divergence is unregistered.** Dart's coordinator runs `_syncWithNewPeer`
when a peer is added; kt's `Peers.add` registers and bootstraps a probe
only, so the first exchange waits for the next round. opendoor-api adds a
peer per WebSocket connection (`PeerConnections.kt:46`), so every joining
phone waits up to one idle interval for its first digest. **Fix:** port
the immediate digest, or record the divergence with the latency it costs.

**KCA1-20 — Stream identity has two sources of truth.**
`EntryRepository.streamIds` answers "which streams exist" from the entry
store while the aggregate answers it from `ChannelAggregate.streamIds`;
`Channel.kt:54-64` unions the two; `InMemoryEntryRepository.clearStream`
(`:180-186`) empties a stream but leaves its key, so a retired stream
still reports; `resourceUsage` (`Coordinator.kt:670-680`) walks the union.
**Fix:** the aggregate owns stream identity; the repository answers only
about entries; `clearStream` retires the key.

**KCA1-21 — `entriesForAuthorAfter` is uncalled but pinned by the
published contract test.** Every adapter, including the server's
Postgres repository, must implement and pass a query nothing calls.
**Fix:** delete it from the port and the contract, or give it its caller.

**KCA1-22 — The frame layout is re-derived in both codecs, the two
dialects share ~110 duplicated lines, and the expansion arithmetic sits
in the facade that declares itself schema-free.** `SyncMessageCodec` and
`MembershipMessageCodec` each read marker offsets that `WireTypes` claims
to own; `SyncWireV1`/`SyncWireV2` duplicate the envelope code; the
"4 characters a byte" and "4 per 3" ratios (`SyncMessageCodec.kt:113-128`)
are facts about each dialect's payload encoding held outside it. **Fix:**
one envelope reader in `WireTypes`; a shared envelope module for the two
dialects; `SyncWireV1.maxEntryPayload(usable)` / `SyncWireV2...` with the
facade only subtracting the envelope and dispatching.

**KCA1-23 — `HlcClock` and `PendingPullTracker` take the fat `TimePort`
for one reading.** Both need `nowMs`; the port also carries `delay`,
timers and cancellation. Dart gives them a `TimeSource`. **Fix:** a
narrow `Clock`-shaped port for readers; keep `TimePort` for schedulers.

**KCA1-24 — `LocalNodeRepository` bundles three concerns.**
`LocalNodeRepository.kt:6-22`: node identity, HLC clock state (sync's
vocabulary) and the incarnation number (membership's) in one shared port;
`ChannelService`, `GossipEngine` and `PeerService` each call exactly one
of its seven methods (`ChannelService.kt:213`, `GossipEngine.kt:962`,
`PeerService.kt:35`). **Fix:** narrow ports per concern, one adapter
implementing all.

**KCA1-25 — `shared/infrastructure` ships ~860 lines of test-only
simulation.** `InMemoryMessageBus` (481 lines: partition, drop, corrupt,
duplicate, hold) and `InMemoryTimePort` (377 lines: advance, tick, idle
waits) have no `src/main` consumer outside their own package and none on
the server. `RealTimePort`, `SynchronizedLoopGeneration`,
`InMemoryLocalNodeRepository` and `InMemoryMessagePort` are real adapters
and belong. **Fix:** move the two simulators (and the `support/` harness
over them) into `gossip-kt-testing`, which is published and already
exists for exactly this.

**KCA1-26 — The published contract test omits `getTailTimestamp` and
under-covers `streamIds`.** Zero calls to `getTailTimestamp` in
`EntryRepositoryContractTest.kt`; `streamIds` appears only as two
side-assertions (`:191,200`); the positive tests sit in the in-memory
adapter's private suite under a header calling them "in-memory-specific"
(`InMemoryEntryRepositoryTest.kt:97`). `getTailTimestamp` drives the
engine's out-of-order rule (`GossipEngine.kt:536`), so an adapter that
gets it wrong causes silent materializer divergence. The server's
repository is about to extend this contract (item 9, Part B). **Fix:**
promote those tests into the contract.

**KCA1-27 — Two launches escape the `ErrorCallback` contract, and the
coordinator scope has no exception handler.** `ReactivePusher.kt:47-60`
guards only the delay; `flush(batches)` (`:59`) → `flushPendingPushes`
calls the peer directory and the port outside any try. The bootstrap
probe is `scope.launch { failureDetector.probeNewPeer(peer) }`
(`Coordinator.kt:132-134`) with the same exposure. The scope is
`CoroutineScope(dispatcher + SupervisorJob())` (`Coordinator.kt:195`),
no `CoroutineExceptionHandler`, so a throw reaches the JVM default
handler, never `onError`. Dart's pusher has the same hole. **Fix:** a
`CoroutineExceptionHandler` on the scope routing to `onError`, plus the
two local guards.

### MINOR

**KCA1-28 — The incarnation chain is dead across three layers.**
`PeerRegistry.kt:121-124` (KDoc: "unused: verdicts never travel"),
`SynchronizedPeerRegistry.kt:61-62,79-80`, `PeerService.kt:33-36`,
`updatePeerIncarnation` flips status without an event; persisted and
restored (`Coordinator.kt:203-207`), never exercised. **Fix:** one
register row, or retire with the relay protocol.

**KCA1-29 — `SynchronizedPeerRegistry` publishes a racy pair and an
escape hatch.** `getUncommittedEvents`/`clearUncommittedEvents`
(`:38-39`) have no caller because `PeerService.dispatchEvents` uses
`withLock` on purpose; `peerRegistry.withLock { reg -> reg.allPeers }`
hands the pure aggregate to the caller. **Fix:** delete the pair;
expose the queries the callers need.

**KCA1-30 — Two `PeerOperationSkipped` per unknown-sender frame, and the
event's `operation` is a string copy of the method name.** Nine literal
sites in `PeerRegistry.kt`. **Fix:** one skip per frame; an enum.

**KCA1-31 — The stop triplet is written three times.**
`Coordinator.kt:483-485,497-499,521-523`; `startEngines()` exists,
`stopEngines()` does not. **Fix:** extract.

**KCA1-32 — Dead vocabulary in the public surface.** Seven of eleven
`SyncErrorType` values, `BufferOverflowError`, `TransformSyncError`, four
of eleven sync events (`ChannelRemoved`, `NonMemberEntriesRejected`,
`BufferOverflowOccurred`, `SyncErrorOccurred`), `ChannelAggregate.isMember`,
and `StreamConfig` have no producer or reader in `src/main` or on the
server. Dart raises none of the seven either, so this is parity-consistent
dead code, but kt's `NonMemberEntriesRejected` KDoc claims an enforcement
Dart explicitly disclaims. **Fix:** delete, or document as reserved.

**KCA1-33 — A channel that vanishes between `listIds()` and `findById()`
is advertised as empty, silently.** `GossipEngine.kt:686-691`. Every other
unknown-channel path logs. **Fix:** a WARN, or a `ChannelSyncError`.

**KCA1-34 — Three policies for an unconfigured collaborator.** Missing
entry store → `StorageSyncError` (`ChannelService.kt:178,237,265`);
`compactAll` → silent with a stated reason (`:337-341`); missing
materialization service → silent in five places with no reason
(`:385,393,404,413,420`), so `registerMaterializer` evaporates. **Fix:**
one policy, stated.

**KCA1-35 — `dispose()` clears the lock maps while operations may run.**
`ChannelService.kt:427-431`; a later caller mints a fresh mutex.
**Fix:** a terminal flag, or stop clearing.

**KCA1-36 — The `""` cursor sentinel round-trips as "corrupt".**
`MaterializationService.kt:306,333` save `""` for a null cursor;
`:273-279` parse it as invalid and force a rebuild; `:249-251` skip the
save instead. **Fix:** one rule in the `StateMaterializer` contract.

**KCA1-37 — `disposeChannel` has no production caller; kt has no
`removeChannel`; `ChannelRemoved` is never emitted.** Dart has all three
(`channel_service.dart:179-206`). **Fix:** port `removeChannel` or record
the gap.

**KCA1-38 — The merged-batch ordering invariant is documented in the
caller, not the callee.** `GossipEngine.kt:525-529` sorts and explains;
`MaterializationService.incrementalFold` takes `newEntries.last()` as the
cursor (`:349-351`) with no stated precondition, and `foldEntries` is
public; the helper's KDoc still says "Preserves original order" (`:593`).
**Fix:** state the precondition on the callee; fix the KDoc.

**KCA1-39 — A comment on this branch says kt has no byte cap, after the
branch added one.** `GossipEngine.kt:850-854`: "No size guard yet: kt has
no payload/message byte cap anywhere (its own roadmap item)". PR #9 added
`CoordinatorConfig.maxMessageBytes` and the append-time cap. **Fix:** on
PR #9, reword to say the push path relies on the append-time cap.

**KCA1-40 — Three log vocabularies.** `GossipEngine.LogLevel`
(`:1020`) shadows `shared/domain/values/LogLevel` (`WARN` vs `WARNING`),
so the composition root bridges them (`Coordinator.kt:255-258,345`); the
detector's seam is `((String) -> Unit)?`, dropping severity. Dart's engine
uses the shared enum. Four unused imports in the engine (`:6,20,49,50`).
**Fix:** one `LogCallback` from `shared/`.

**KCA1-41 — The per-peer backpressure predicate is written twice.**
`GossipEngine.kt:297-299` and `:872-874`, identical. Inert on the server
(pending count is always 0). **Fix:** one helper.

**KCA1-42 — `EntriesMergedCallback` lives in `shared/domain/errors`.** It
fires on success, is sync vocabulary, and has one consumer
(`GossipEngine.kt:85`). **Fix:** move to `sync/application`, or retire in
favor of the `EntriesMerged` event.

**KCA1-43 — `LogEntry.sizeBytes` documents a wire estimate it is not.**
`LogEntry.kt:41-47` claims "wire protocol sizing" with a 36-byte author;
identifiers are bounded at 64 bytes and the v1 dialect costs four
characters a byte, so it is neither. Its only consumers are storage
accounting (`ChannelService.kt:309`, `InMemoryEntryRepository.kt:140`,
`Coordinator.kt:678`). **Fix:** say it is a storage heuristic; measure
the author.

**KCA1-44 — `MessagePort` says nothing about priority, and both adapters
ignore it.** `InMemoryMessagePort.kt:20-27` drops it; the server's port
drops it; the port defaults it. **Fix:** state the contract (advisory,
or an ordering guarantee) and make the in-memory adapter honor it so it
is testable.

**KCA1-45 — `RttTracker` duplicates `RttEstimate`'s defaults.**
`RttEstimate.kt:41-42`, `RttTracker.kt:104-105`. **Fix:** one home.

**KCA1-46 — A `shared/` KDoc names `ChannelService`.**
`HlcProvider.kt:5-9`; prose only, the gate does not see it. **Fix:** say
"a context's application service".

**KCA1-47 — `CachingChannelRepository` contradicts its own KDoc, duplicates
`deepCopy`, and is unwired.** `:8-14` promises identity-map semantics;
`:25-30` returns copies; `:37-43` duplicates `InMemoryChannelRepository.kt:45-51`,
both reaching for `reconstitute` from outside the aggregate, which drops
uncommitted events. **Fix:** `ChannelAggregate.copy()`; fix or drop the
decorator.

**KCA1-48 — The boundary gate's edges are sharper than its documentation
and looser than the rule.** `BoundaryTest.kt:83` scans raw text including
comments while `LockPlacementTest.kt:111` scrubs them, and neither the
asymmetry nor the typealias/reflection limit (`LockPlacementTest.kt:40-43`
has the block; `BoundaryTest` does not) is stated; the ACL check
(`:84-86`) tests the directory, not "to implement an adapter for an
interface its own domain defines"; CLAUDE.md's Boundary Rule omits the
`testing` edge-table row (`BoundaryTest.kt:23-29`). **Fix:** a known-limits
block; a one-file allowlist for the concession; one CLAUDE.md sentence.

**KCA1-49 — Wire fixture paths are unguarded.** `WireGoldenTest.kt:63`,
`WireVectorConformanceTest.kt:53-54` build `File(...)` from a root-relative
literal with no `isDirectory` guard, unlike both architecture tests.
**Fix:** the same guard, or classpath loading.

**KCA1-50 — README counts are stale.** `README.md:113` says 25 contract
tests (36); `:195` says 532 tests (1,057 in `src/test`). **Fix:** drop the
numbers.

### OBSERVATION

**KCA1-51 — `sync/domain/services/` mixes four stateless retention
strategies with three stateful protocol-state holders.** A
`domain/retention/` package would match the concept-first layout.

**KCA1-52 — `WireTypes` names both contexts.** `WireTypes.kt:19-25`
defends it in place as the envelope agreement both families publish;
recorded, not disputed.

**KCA1-53 — Boundaries have no compiler backstop.** One compilation unit;
`internal` is module-scoped; the text scan is the whole enforcement.
Already the project's chosen trade-off.

**KCA1-54 — `LogEntry.equals` (author + sequence) and `compareTo` (full
order) disagree by design.** No sorted-set or tree structure keys on
`LogEntry` anywhere in `src/main`, so nothing relies on `compareTo == 0`
meaning identity. Worth a sentence on the class.

## What is genuinely healthy

Verified, and worth protecting on purpose:

- **The bounded contexts hold mechanically.** `shared/` imports nothing
  outside itself (all 44 files); `sync/` names membership only in
  `MembershipPeerDirectory`, at `sync/infrastructure/`, whose KDoc,
  code and the gate all agree; `coordinator/` is the only sink;
  `acceptedDebt` is empty. The gate scans fully-qualified names, not just
  imports, and catches wildcard imports.
- **The lock-placement rows are exact.** All six `ChannelService` lines
  and four `MaterializationService` lines match the code; the scrubber's
  test suite is adversarial (nested comments, delimiters in strings, raw
  strings); nothing else in the application or domain layers holds a
  primitive.
- **The engine's ports are domain-owned and narrow.** `PeerDirectory` has
  three methods, each the exact call the engine makes; `EntryRepository`,
  `ChannelRepository`, `TimePort`, `MessagePort`, `LocalNodeRepository`
  are all defined inward. `GossipEngine` and `ChannelService` never
  reference each other; the coordinator's lambda is the only join.
- **One home for each invariant.** `requireIdentifier` is the single
  identifier rule, called from all three id types' `init`; `compareUtf8`
  is the single byte-order comparison behind `NodeId.compareTo` and
  `LogEntry`'s author tiebreak; the canonical order lives in
  `LogEntry.compareTo` and the repository contract states it once; the
  out-of-order rule is stated once and carried as data.
- **Cancellation discipline is uniform.** Every `catch (e: Exception)` is
  preceded by a rethrow of `CancellationException`; the `NonCancellable`
  block around append-and-notify is argued in place and is the right
  tool; `runIsolatedPerState` gives every materializer its turn and
  suppresses rather than drops later failures.
- **Value objects encapsulate.** `VersionVector` copies on construction and
  exposes an unmodifiable view; `IncomingMessage` hand-rolls
  `ByteArray` equality; `WireTypes.classifyFrame` partitions the marker
  space exhaustively with a named reason per branch.
- **The harness runs real code.** `TestNetwork`/`TestNode` wire real
  coordinators over real in-memory adapters through public API only; the
  contract test is dogfooded by the in-memory adapter; the Gradle
  dependency direction is correct; architecture tests run in CI with no
  filters.
- **`ReactivePusher` is a real separate reason to change**, owns only
  *when*, and documents the race behind each of its four entry points.
- **The gap-reporting split is deliberate, not duplicated**: the solicited
  gate appears twice (`GossipEngine.kt:503,642`) because stalled-range
  recording must not be dedup-gated, with Dart's identical split.

## Adjusted and discarded claims

- **Discarded:** T5's claim that CLAUDE.md leaves the gate's `src/main`
  scope undocumented; `CLAUDE.md:100` states it. The `testing` row half
  of that finding survives as part of KCA1-48.
- **Re-graded down:** T5's contract-test gap (Major → Moderate, support
  machinery with one adapter in the world, about to be fixed by Part B);
  T5's comment-scan asymmetry and missing known-limits block (Moderate →
  Minor, documentation); T1's `EntriesMergedCallback` placement and
  `sizeBytes` estimate (Moderate → Minor, cheap and the estimate is a
  storage heuristic, not wire sizing); T4's double `PeerOperationSkipped`
  (Moderate → Minor).
- **Re-graded up:** T2's unguarded channel repository and T3's
  `createChannel` check-then-act merged and raised to Major once the
  server's default wiring and per-joiner `createChannel` calls were
  confirmed; T3's `ReactivePusher` flush hole and T4's bootstrap-probe
  observation merged and raised to Moderate once the scope was confirmed
  to have no exception handler.
- **Merged duplicates:** the wall-clock pattern (four reports → KCA1-8);
  the concrete-codec dependency (T3 + T4 → KCA1-2); stateful domain
  services (T1 + T2 + T4 → KCA1-14); dead vocabulary (T1 + T2 → KCA1-32);
  stream identity (T2 F1, F11 + T4 F14 → KCA1-20).
- **Reachability notes added:** the server ignores priority and reports
  zero pending sends (KCA1-12, KCA1-41 inert there); the server registers
  five materializers and persists cursors (KCA1-6, KCA1-9, KCA1-11
  reachable); the server does not consume `stateStream` or `healthStatus`
  (KCA1-10, KCA1-16 hazards); Dart raises none of the seven unused error
  types (KCA1-32 parity-consistent).
- **Citations:** none fabricated. T3's lock-placement row citation
  (`:71-79`) covers the materialization row only; the `ChannelService`
  row is `:59-70`. T4's line ranges for `Channel.kt` and `EventStream.kt`
  were confirmed as given.

## Recommendations

| R | What | Findings | Effort |
|---|------|----------|--------|
| R1 | Guard the channel store; `createChannel` and `compactStream` under the locks | KCA1-1 | S |
| R2 | Fix the stale cap comment on PR #9 | KCA1-39 | XS |
| R3 | Bookkeeping before notification; exception handler on the scope; report dropped events | KCA1-6, KCA1-17, KCA1-27 | S |
| R4 | Engines depend on ports; no self-construction; break the membership cycle | KCA1-2, KCA1-3, KCA1-4, KCA1-40 | M |
| R5 | A clock reading on `TimePort`; events take `at`; stamp in the application | KCA1-8, KCA1-23 | M |
| R6 | Register or port the four divergences: `FoldCursor`, sync-with-new-peer, `removeChannel`, incarnation chain | KCA1-9, KCA1-19, KCA1-28, KCA1-37 | S (rows) / M (ports) |
| R7 | Wire or delete: config knobs, dead vocabulary, `entriesForAuthorAfter`, `StreamConfig` | KCA1-16, KCA1-21, KCA1-32 | S |
| R8 | Extract the merge path and request/digest computation from the engine; restate E2 | KCA1-5 | L |
| R9 | Materialization: state stream, debt-row scope, cursor sentinel, dispose | KCA1-10, KCA1-11, KCA1-36 | S |
| R10 | Pure domain: transition table on the aggregate; the six stateful services; `GenerationScheduler` out of `shared/domain` | KCA1-13, KCA1-14, KCA1-15 | L |
| R11 | Stream identity on the aggregate; facades read through the service | KCA1-20, KCA1-18 | M |
| R12 | Codec envelope in one place; dialect arithmetic in its dialect | KCA1-22 | M |
| R13 | Narrow `LocalNodeRepository`; simulators into `gossip-kt-testing`; contract-test coverage | KCA1-24, KCA1-25, KCA1-26 | M |
| R14 | Minor sweep: KCA1-29 to KCA1-35, KCA1-38, KCA1-41 to KCA1-50 | as listed | S |

**Suggested order.** R1 and R2 first: R1 is the only reachable defect and
R2 belongs on the open PR. R3 next, since all three are small and each
closes a silent path on the production server. R4 and R5 before anything
larger, because the extraction in R8 and the purity work in R10 both get
cheaper once the engines take ports and the clock is injected. R6 and R7
are bookkeeping that can land any time and should land before the
domain-model audit, which will otherwise re-find them. R8 through R13
are design batches, each its own spec. R14 rides along with whichever
batch touches the file.

## Coverage

| Territory | Files | Lines | Read by |
|-----------|-------|-------|---------|
| `shared/` (domain + infrastructure) | 44 | 2,223 | T1, in full |
| `sync/domain` + `sync/infrastructure` | 50 | 2,959 | T2, in full |
| `sync/application` (engine, service, materialization, pusher) | 4 | 1,954 | T3, in full |
| `membership/` + `coordinator/` | 32 | 2,725 | T4, in full |
| Architecture tests, `support/` harness, wire tests, `gossip-kt-testing`, Gradle, CLAUDE.md, README | 16 | 3,284 | T5, in full |
| opendoor-api (`sync/` package, materializers, lifecycle) | — | — | orchestrator, by grep, for reachability only |

Every file under `src/main` of both Gradle modules was some reader's
responsibility. **Not read:** the remaining 85 test files under
`src/test` (`sync/`, `integration/`, `shared/`, `membership/`,
`coordinator/`), enumerated only; they are outside the boundary gate's
scan by design and outside this rubric, and the code-quality pass should
take them. The Dart twin was read where a finding names a divergence,
not audited.

## Addendum (batch A, 2026-09-23)

**KCA1-55 — The coordinator's public `errors` flow had no producer.**
Found while fixing KCA1-17: `Coordinator.kt:150` declared `_errors` and
exposed it as `errors`, and nothing in `src/main` emitted into it; Dart
feeds its error stream from the error callback (`coordinator.dart:386`).
Minor, Kotlin-only; fixed in batch A by one reporter feeding both.

**Ruling 9 revised during batch A.** The whole-branch review showed that a
suspending emit on the events flow lets a collector that calls back into
the coordinator (the server's side-effect processor does) wait on itself
once the buffer fills. Batch A therefore gives the coordinator an
unbounded internal queue and one forwarder: producers never suspend,
events are delivered in order and never dropped once a collector is
attached, and a stalled collector grows the queue, reported once at WARN
past a thousand pending. This is the Dart twin's semantics; the rulings
page carries the precision note.

**Fixes landed (gossip-kt PR #10, merged 2026-09-23 as 4a53e72, suite 1,093 → 1,107 after six external review rounds):**
KCA1-1, KCA1-6, KCA1-17, KCA1-27, KCA1-55, and KCA1-47 pulled forward
from batch F: `CachingChannelRepository` is deleted (an external review
showed its read-through cannot be serialized under the lock rule, and
nothing wired it). Two observations for later
batches: `EntryAppended` events from concurrent appends to one stream may
be observed out of sequence order (the wire path and the fold are
unaffected); compaction serializes against local appends only, and a
backfilled entry merged between compaction's read and its removal can
land below the raised floor (pre-existing; the merge path is the engine
extraction's territory, KCA1-5).

## Addendum (batch B, 2026-09-24)

**Fixes landed (gossip-kt PR #11, merged 2026-09-24 as 3506a68, head cd762dd,
suite 1,107 → 1,125):** KCA1-2, KCA1-3, KCA1-4, KCA1-8, KCA1-23, KCA1-29, KCA1-40.

- KCA1-8 and KCA1-23: a narrow `Clock` port (`nowMs`, `now(): Instant`)
  that `TimePort` extends; `HlcClock` and `PendingPullTracker` take only the
  reading. Every domain event takes `at` as a required argument, aggregates
  take `now` as data and read no clock, the two services stamp from their
  injected clock through one private helper each. `ClockPlacementTest`
  forbids every JVM and Kotlin wall-clock read outside `infrastructure/`
  (the ten `java.time` factories in call and method-reference form, the
  `System` reads, `java.time.Clock`, `Date`/`Calendar`, `TimeSource`,
  `TimeMark` and its reads, the `measure*` helpers, kotlinx-datetime's
  `Clock.System`) over both source trees with an empty debt map;
  `RealTimePort.now()` is the one sanctioned read. Under a simulated clock,
  every event and error stamp equals the simulation.
- KCA1-2 and KCA1-40: both engines take `MessageCodec` with no default and
  the shared `LogCallback` with severity; the engine's private `LogLevel`
  and the coordinator's two adapters are gone. Ruling taken during the
  batch: the detector logs its four status transitions at INFO and
  everything else at DEBUG, and has no WARNING line — an undecodable frame
  is the coordinator's error report. (The plan text said "malformed frames
  at WARNING"; the shipped shape is the one stated here.)
- KCA1-4: `PendingPing`/`PendingPingRegistry` are membership domain
  aggregates and the wrapper depends inward; `LayerDirectionTest` states
  the rule (domain references domain; application never references
  infrastructure) and ends the batch with an empty map.
- KCA1-3 and KCA1-29: ten `Synchronized*` wrappers subclass their `open`
  pure classes and override every public member under one monitor, each
  with a reflection pin, and `SynchronizedWrapperCoverageTest` pins the
  shape itself (every `Synchronized*` class subclasses a `domain/` class
  and has a pin). Every application constructor takes the pure type with no
  default and constructs nothing; `Coordinator.create` wires every wrapper.
  `SynchronizedPeerRegistry` is a plain monitor: the coroutine `Mutex`, the
  `withLock` escape hatch and the racy read-then-clear pair are gone;
  `drainUncommittedEvents(publish)` takes, clears and publishes in one call
  under the registry's monitor, so batch A's ordering guarantee for peer
  events holds by construction. The backlog item
  `kt-application-types-against-domain` closes.

**Timing against main, stated on purpose.** News and anti-entropy credit
are unchanged from batch A; every event is published at the same point
relative to its mutation as on main; the only stamp shift is an event's
`at` now being read before the storage write rather than after (invisible
to consumers). The registry's lock changed from a coroutine mutex to a
monitor, so a waiting caller parks its thread for the length of an
in-memory map operation instead of yielding. Three wrappers re-enter their
own monitor through an overridden member (`GossipTimingPolicy`,
`PendingPullTracker`, `ProbeTimingPolicy`), which is why the wrappers are
monitors and not mutexes; each says so.

**Observations for later batches.** `open` domain classes make their
invariants overridable — the accepted cost of ruling 3's shape (batch E may
revisit). `PendingPing` carries a `CompletableDeferred` into `domain/`
(batch E, with KCA1-14). `healthStatus` reads the peer and reachable counts
in two calls with no snapshot (a monitoring read; a combined query is the
shape if exactness is ever wanted). `PeerRegistry.uncommittedEvents` and
`clearUncommittedEvents` are now test-only production API (batch C sweep;
register row). The text-scanning clock gate cannot see a clock read through
an imported type alias; its KDoc assigns that to review, and closing it
would mean resolving types. Two wall-clock flakes recurred during the batch
and are recorded on the flaky-tests item with a diagnosis for the
reactive-push pair.

**Consumer notes for the server bump after batch F.** `Coordinator.create`'s
signature is unchanged. The server constructs none of the services whose
constructors changed (`ChannelService`, `PeerService`, the engines). The
server's INFO logger will start carrying the detector's peer status
transitions; nothing moves to WARN. An unreachable peer that answers the
periodic probe logs two INFO lines (recovery recorded twice, a pre-existing
shape). Batch A's acceptance item stands: surface the events backlog depth
and measure the collector's throughput in a room.

**Flow-back to Dart (register rows added with this addendum):** the 45
direct `DateTime.now()` reads and the absence of a clock-placement gate
(KCA1-8/23); the detector's log severities (KCA1-40). Homed to the
flow-back sweep.

## Addendum (batch C, 2026-09-24)

**Fixes landed (gossip-kt PR #12, merged 2026-09-24 as 629935a, head b93354a,
suite 1,125 → 1,152):** KCA1-9, KCA1-16, KCA1-19, KCA1-20, KCA1-21, KCA1-24, KCA1-28,
KCA1-32, KCA1-37.

- KCA1-32, KCA1-28, KCA1-24 and the `maxConnections` half of KCA1-16: the
  seven unraised `SyncErrorType` values, `BufferOverflowError`,
  `TransformSyncError`, `BufferOverflowOccurred`, `NonMemberEntriesRejected`,
  `SyncErrorOccurred` (owner-confirmed refinement of ruling 6: no producer
  on either twin, so deleted rather than given one), `StreamConfig`,
  `ChannelAggregate.isMember`, `CoordinatorConfig.maxConnections` and the
  whole incarnation chain are gone; `LocalNodeRepository` has Dart's shape
  (the finer split by concern stays the shared follow-up ruling 6 names). A
  sixth architecture pin, `RetiredSurfaceTest`, raw-text-scans both source
  trees and both test trees for every retired name.
- The rest of KCA1-16: `CoordinatorConfig` validates `suspicionThreshold ≥ 1`,
  `unreachableThreshold > suspicionThreshold`, `unreachableProbeInterval ≥ 1`
  and `startupGracePeriod ≥ 0`; `startupGracePeriod` gained its reader (below);
  `HealthStatus` carries `state` and derives `isHealthy` from it;
  `adaptiveTimingEnabled` stays gossip-only because the probe policy has no
  adaptive switch by construction (documented, not threaded).
- KCA1-37: `ChannelService.removeChannel` and `Coordinator.removeChannel`,
  Dart's order (clear entries, dispose materializer state, delete the
  aggregate, emit `ChannelRemoved`), under the channel lock and every stream
  lock; `appendEntry` re-checks stream existence under the stream lock it now
  shares with removal; `MaterializationService.disposeChannel` is suspend and
  waits out an in-flight fold under the state's own mutex, removing the exact
  state it snapshotted.
- KCA1-19: `GossipEngine.syncWithPeer` sends one digest on `peers.add` while
  running (news recorded first, as Dart); the startup grace hold is set for an
  add the registry acted on, before or after `start()`, and cleared early when
  the bootstrap probe is answered; `FailureDetector.holdProbing(peer, duration)`
  owns the deadline arithmetic.
- KCA1-9: `FoldCursor` in `sync/domain/values` carries timestamp, author and
  sequence in `LogEntry`'s order (`NodeId.compareTo`, the same unsigned byte
  order the server's `COLLATE "C"` produces); legacy timestamp-only strings
  parse with their old tie rule; a rejected author segment is corruption
  (full rebuild), not a crash.
- KCA1-20 and KCA1-21: `EntryRepository` loses `streamIds` and
  `entriesForAuthorAfter`; `clearStream` retires the key; `Channel.getStream`
  and `resourceUsage` read the aggregate; the published contract test gains
  `getTailTimestamp` (null on empty; last in total order; a tie returns it)
  and states that key retirement is adapter-checked.

**Timing against main, stated on purpose.** `appendEntry`'s missing-stream
error is emitted after the stream lock is granted rather than before queuing,
and one repository read moved under the E3-exempt append lock (same-stream
appends serialize it; a Postgres read on the server). `ChannelRemoved` is
published after the delete, under the locks, through the non-suspending
queue. Adding a peer while running does register → hold → probe → digest;
a peer added before `start()` is held for `startupGracePeriod` (default
10 s) unless its bootstrap probe is answered, where before it was
probe-eligible from the first round; re-adding a known reachable peer
neither sets nor extends a hold. `removeChannel` holds the channel and
stream locks while a materializer's in-flight `fold`/`save` finishes. The
cursor paths are unchanged in order. Lock graph: channel → stream →
materializer state → leaf monitors, one total order, no cycle.

**Observations for later batches.** The engine's inbound merge path
bypasses the service's locks, so a delta already past the engine's channel
check when `removeChannel` runs can land an entry the removal never sees
(the compaction-vs-merge class; batch D). A materializer whose `fold`/`save`
hangs now wedges appends to that channel under `removeChannel` (D: bounded
wait or a `StateMaterializer` contract sentence). `getTailTimestamp` returns
an `Hlc` only, so the engine's tail-tie rule still forces a rebuild on every
timestamp tie; a full-position tail would make it exact (D/E). A removal
racing the auto-compaction pass emits one benign "Compaction skipped" error
(D). `nextUnreachableTarget` consults no probing hold (harmless; the
recovery probe carries the grace window). Gradle keeps `:test` up to date
after a comment-only source change, so the six source-scanning gates do not
re-run on such a change — declare the scanned trees as test inputs (F); the
retired-surface pin's `\b` match cannot see a renamed revival (F, KDoc).
The flaky-tests item gains the burst-coalescing engine test.

**Consumer notes for the server bump after batch F.** `PgEntryRepository`,
`MarksCachingEntryRepository` and the test `RecordingEntryRepository` drop
`streamIds` and `entriesForAuthorAfter`; `PeerDto` drops `incarnation`;
`PgLocalNodeRepository` drops its two incarnation methods; persisted cursor
strings grow to `Hlc(p:l)|author|seq` (well inside the 200-character column)
and existing ones keep parsing; `CoordinatorConfig(maxConnections = …)` no
longer compiles; `HealthStatus` gains `state`; the seven error values are
gone; `PeerRegistry.addPeer`/`PeerService.addPeer` return `Boolean`
(source-compatible). Behaviour: every WebSocket connection's `peers.add`
now sends that phone a digest at once and holds probing for 10 s unless the
bootstrap probe is answered, so a phone that connects and stays silent is
condemned 10 s later than before; a remove-then-add per reconnect restarts
the hold legitimately. The events-queue acceptance item from batch A stands.

**Register rows added with this addendum:** the dead vocabulary Dart still
declares (flow-back); the no-op re-add hold (flow-back); the bootstrap-probe
retry (Kotlin sweep candidate); the digest to a removed peer (parity,
exempt); `|` inside a node id versus the cursor form (parity, exempt). The
incarnation row and the test-only accessors row close.

**Review rounds on PR #12 (2026-09-24).** Two external rounds and one
owner-requested architecture review (cohesion, coupling, DDD, CA), every
claim verified against the head before ruling. Landed: every `Duration` the
config carries must be finite and `holdProbing` saturates (an infinite grace
overflowed the hold deadline into "already expired"); `FoldCursor` rejects a
non-positive sequence at construction and in parsing; a fold queued on a
state's mutex before disposal no longer runs after it — `disposed` is set
under the mutex and one helper is the only place the class takes a state's
mutex; the stream locks are acquired iteratively with reverse release (the
recursive form overflowed at a few thousand streams and released nothing on
a mid-acquisition failure). From the architecture review: the registry's
admission is a named domain outcome (`PeerAdmission`: added, recovered,
already reachable) rather than a Boolean threaded through three layers; the
detector owns the grace knob and the admission rule (`admitPeer`), so the
composition root wires it unconditionally instead of branching; the fold
cursor parses positionally (`|` is a legal identifier character) and its
legacy timestamp-only form is constructible only by parsing; the lock
hierarchy (channel ⊃ stream, one order) is stated where the locks live; the
`Channel` facade reads members and streams through the service and no
longer holds a repository; the aggregate answers `hasStream` itself; two
KDoc claims were corrected (why the service raises `ChannelRemoved`; the
engine's per-channel snapshots — a buffered push may go out once, stale pull
marks are dropped only at engine stop or peer removal). Deferred with a
recorded home: two-phase disposal so removal does not wait on application
materializer code under the locks, and `GossipEngine.clearPendingFor(channel)`
(D); a cheaper health read model (later); moving the retired-surface pin out
of the architecture package to match declarations, and one shared source
scanner for the six gates (F). A third external round then found that a
cancellation during the disposal wait left a channel with an erased log,
and that a materializer registered during disposal survived it; removal is
now two-phase (a cancellable, all-or-nothing quiesce, then a
non-cancellable discard → clear → delete → emit span with no wait inside),
and registration is refused for a missing channel under the channel lock,
which makes the straggler impossible by construction. Consumer notes
gained: `addPeer` returns `PeerAdmission`; `FailureDetector` takes
`startupGracePeriod` (defaulted); `EventStream.registerMaterializer` and
`ChannelService.registerMaterializer` are `suspend`.

## Addendum (batch D, 2026-09-25)

**Fixes landed (gossip-kt PR #13, merged 2026-09-25 as 800c05f, head f406d25,
suite 1,152 → 1,218):** KCA1-5, KCA1-38, KCA1-42.

- KCA1-5: `GossipEngine` (1,060 → ~800 lines) keeps the round loop, message
  routing and sending. `DeltaMerger` owns the merge path — solicited floor
  adoption, contiguity, gap reporting and stalls, sort, HLC advance,
  append-and-notify, continuation — with today's side-effect order kept
  statement for statement (the review's eleven-row table is in the batch
  ledger); from the version-vector read through the merged callback it runs
  under the stream's lock after an under-lock re-check of the channel and
  stream, and the floor adoption runs under the same lock in its own span.
  `PullPlanner` owns digest building, pull planning (each pull sent as it is
  planned, today's interleaving, pinned) and the page seam that is
  `hasMore`'s only producer; pagination is not implemented. Contiguity
  selection is a pure domain service (`ContiguitySelector`). One
  `StreamLocks` holder replaces the two lock maps inside `ChannelService`;
  the composition root wires it into the service and the engine; it has
  deliberately no way to drop a lock; the `LockPlacementTest` row moved
  with it. Ruling 10 named the second service `DigestBudgeter`; it is
  `PullPlanner` because it holds none of Dart's `DigestBudgeter`'s byte
  budgeting (precision note on the rulings page).
- KCA1-38: `foldEntries` requires a batch in `LogEntry` order and says why
  (the cursor is the batch's last entry); `StateMaterializer`'s contract
  says a fold that blocks stalls the stream and must not call back into the
  library.
- KCA1-42: `EntriesMergedCallback` lives in `sync/application`.
- Carried items closed: the merge path shares the stream lock, so the limit
  batch C documented on `removeChannel` and `quiesce` is gone; the
  compaction-vs-merge race is closed and turned out to be a double fold
  (the batch-A observation "a merged entry can land below the raised floor"
  was wrong: the floor never exceeds the version vector); a removal racing
  the auto-compaction pass no longer emits a spurious error; the engine
  forgets a removed channel (`clearPendingFor`: pull marks, stalled ranges,
  reported gaps, buffered pushes — called inside the removal's locked span,
  after the delete and before the event, so a recreation of the same id
  cannot lose its fresh state; an external review round found the
  after-the-lock version) and the reactive flush re-checks the channel
  before each send.

**Timing against main, stated on purpose.** Every merge-path row is in its
original position; rows five to ten (and the floor adoption, in its own
span) now wait for and exclude a local append, compaction or removal of the
same stream, and the single collector delays the next inbound frame by that
local operation's length, bounded by repository IO plus one materializer
fold; the planner waits on the same lock only in the rare
authorship-claim branch. The continuation decision runs inside the same
span (a third external round found a removal could slip between the
apply and the mark); the continuation is returned to the engine and sent
immediately with `sendDeltaRequest` unchanged. A pull's dedup clock
still starts at its own send. The engine's constructor gains the shared
lock holder — the one stated deviation from the spec's "engine tests
unchanged" pin (three construction sites gain one argument, no assertion
changed).

**Observations for later batches.** `GossipEngine` still carries twenty
constructor parameters and its own wiring, and `flushPendingPushes`'s
fan-out sits outside `ReactivePusher` (E/F). `StalledRangeRegistry` is now
shared by three application services (E). Whether `StreamLocks` belongs in
`infrastructure/` behind a domain-facing port (F). A pull mark in the
common no-adoption branch can outlive a removal until the tracker's timeout
(bounded; pre-existing). `MergeOutcome.mergedNewEntries` has no production
reader on either twin (parity debt).

**Consumer notes for the server bump after batch F.** `Coordinator.create`
is unchanged; the server constructs the coordinator, not the engine. After
the second external review round the per-stream planning step runs under
the stream lock with an under-lock channel re-read, so the server now pays
one `ChannelRepository.findById` per stream digest per inbound digest
(was one per channel digest) — a Postgres read that item 10's re-measure
should look at; if it shows, a cached or existence-only read is the fix.
`ChannelService.foldMergedEntries` now refuses an unsorted batch.
`EntriesMergedCallback` moved packages (only if the server names it).

## Addendum (batch E, 2026-09-25)

**Fixes landed (gossip-kt PR #14, merged 2026-09-25 as 9704c96, head 9b07f21,
suite 1,218 → 1,255):** KCA1-13, KCA1-14, KCA1-15.

- KCA1-14: the six stateful domain services are gone as a shape. `HlcClock`,
  `GossipTimingPolicy`, `PendingPullTracker`, `ProbeTargetSelector`,
  `ProbeTimingPolicy` and `LoopGeneration` are pure objects over immutable
  values (`Hlc`, `GossipTiming`, `PendingPulls` with `RttTracking`,
  `ProbeSelection`, `ProbeTiming` with `ProbeTimingConfig`, `Generation`):
  each transition is a function from (state, inputs) to (state, result),
  time and randomness are inputs, and each has a property-style test. The
  value lives in one generic holder, `SynchronizedState<T>`, the only
  implementation of the `StateCell<T>` port (`update` runs a transition as
  one step against the current value; `read` runs a query); the
  application layer composes value, object and cell, and the six bespoke
  `Synchronized*` wrappers plus `SynchronizedPendingPingRegistry` are
  deleted. `LocalHlc` (sync/application) is this node's clock over a
  `StateCell<Hlc>` and the clock port, reading the wall clock inside the
  deciding step on purpose, with the port's leaf obligation stated. The
  pending-ping registry the batch-B ledger carried splits the same way:
  `PendingPings` records what is outstanding; the deferreds an Ack
  completes are the detector's, in a cell of their own, completed outside
  any monitor. The wrapper-coverage gate admits exactly two shapes:
  `open` aggregate + `Synchronized*` subclass + reflection pin, and the
  one holder. The recorded `PendingPullTracker` smell closes on this side.
- KCA1-13: `FailureThresholds` is a validated value; the transition table is
  on `Peer` (`probeFailed(thresholds)`, `contacted(atMs)`), and
  `PeerRegistry.recordProbeFailure` / `updatePeerContact` apply it under
  the wrapper's one lock and return the resulting status, so the detector
  no longer reads, decides and writes across three lock acquisitions; the
  race is pinned (twenty concurrent failures, one transition each rung).
  The detector's dead default thresholds are gone; `Coordinator.create` had
  passed the configured ones since 9042b80.
- KCA1-15: `LoopScheduler` is a port in `shared/domain/interfaces`
  (`start(Loop)`, `stop`, `isRunning`); `GenerationScheduler` is its
  adapter in `shared/infrastructure` over the time port and a scope;
  `LoopGeneration` stays pure in the domain.
- Beyond the plan, from the reviews: the leaf-port obligation the deleted
  clock wrapper used to state is restated on `LocalHlc` and on the
  `StateCell` contract (with the stated exception for a value that carries a
  handle completed outside the cell); the unreachable-probe counter is a
  cell; one private apply-and-announce in the registry; a once-only
  duplicate-Ack pin; `PendingPingRegistry` sits with the services.

**Timing against main, stated on purpose.** Twelve side-effect rows moved;
the review's table is in the batch ledger. The ones a consumer could see:
a duplicate `start()` on a running scheduler was a restart at main (the
generation bumped, the pending delay went stale, a fresh delay armed under
the newly passed loop) and is now a no-op that discards the incoming loop —
the plan's "start-idempotence stays" premise was wrong about main, the new
behaviour is the stricter one, and it is unreachable through the
coordinator, engine or detector, each of which guards `isRunning` first.
A failed probe that crosses a threshold now publishes `PeerStatusChanged`
before the INFO verdict line (was after) and dispatches once (was twice);
the log's count token is the crossed threshold, equal to the peer's count at
every reachable crossing. The clock reads that fed the pull tracker and the
ping registry moved out of their monitors to the caller (an input), except
the pending ping's send stamp, which a review round hoisted after a task
had moved it in; `tryMark` marks at the instant it judged (one read, not
two). `updatePeerContact` writes contact, count and status as one value and
then queues the event (was event, then a second write; not observable —
events drain after the call), and reports the status the contact left so
the detector's recovery line is decided by the write that made it, not by
a read before it; a status write that changes nothing now stores an equal
copy (was skipped; no identity check or event depends on it). HLC restore builds the cell from the saved
value instead of constructing and then restoring (same state). Everything
on the probe round, `probe()` and its cleanup, Ack handling, pull
mark/release/complete, HLC issue and receive, scheduler tick/stop, gossip
pacing, both lifecycles and error reporting is at its original call point
with its original conditions.

**External review rounds.** Round 1 (on b43fcf2) asked for the pull
gate's clock read to move back inside the update, as the deleted wrapper
had it. Refused with the limit written on the contract (3039c76): a
reading taken by the caller just before the step can be stale by one
thread pause, which can hold a mark that expired during the pause for one
more digest round or shorten a mark or a round-trip sample by that pause —
against deadlines of seconds, and never a mark that outlives its request.
The one mark site runs under the stream lock, so nothing competing lands
in the pause; a completion that does only clears the mark. An in-step port
read is granted to `LocalHlc` alone, whose stamps must never go backwards.

**Owner-requested controller review (2026-09-25).** The whole production
diff read against main once more, statement for statement: the arithmetic
of all six services and the transition table is verbatim, every call point
is where it was, the config's threshold validation is the same rule the
new value requires, and the restored clock starts from main's default. One
mistake found and fixed (9b07f21): the transition collapse had reworded the
INFO verdict line; main's exact wording is restored, with the threshold as
the count token (equal at every crossing), and pinned so a refactor cannot
move it again. No parser in the server repository depended on it.

**Observations for batch F.** `PeerRegistry.recordProbeFailure` returns the
status entered while `updatePeerContact` returns the status left — the same
`PeerStatus?` shape with opposite meaning, each stated on its KDoc; a
from/to value would be the honest return for both, and it touches the
registry, its wrapper, the service, the detector and four test classes, so
it goes with F's detector items before the bump. `DeltaMerger` and `GossipEngine` are typed
against the concrete `LocalHlc` because `HlcProvider` is a shared port and
`receive` is sync-only (deliberate; recorded). `handleAck` takes two cell
reads where main took one (interleavings traced in the Task 8 review; at
worst one late RTT sample, never a verdict). `Coordinator` builds the
compaction scheduler even when no interval is configured (one generation
bump on a closed gate). Carried from D: `GossipEngine`'s constructor and
the flush fan-out; `StalledRangeRegistry` shared by three services;
`healthStatus`'s two reads; `ContiguityGap` self-validation; `StreamLocks`'
home; the shared gate scanner; Gradle test inputs; a silently-skipped-test
gate.

**Consumer notes for the server bump after batch F.** Constructor changes
are root-only (`FailureDetector` takes thresholds, a grace period and three
cells — pings, awaiting acks, rounds since the last unreachable probe;
`GossipEngine`, `DeltaMerger`, `PullPlanner` take `LocalHlc`, a
`StateCell<PendingPulls>` and `StreamLocks`); `Coordinator.create` is
unchanged. `PeerRegistry.updatePeerContact` and `PeerService.recordPeerContact`
return `PeerStatus?` (the status left; null for an unknown peer). Removed or re-meant public surface, to grep for at the bump:
`FailureDetector.checkPeerHealth` is gone and `recordProbeFailure` now
transitions and logs where it only incremented; `PeerOperationSkipped.operation`
for an unknown-peer failure reads `recordProbeFailure` (was
`incrementFailedProbeCount`) — a published event payload; the seven deleted
wrappers. Newly public or moved types, only if the server names them:
`PendingPing` (values), `IntervalMode`, `RttTracking`, `PendingPulls`,
`PendingPings`, `ProbeSelection`, `ProbeTiming`, `ProbeTimingConfig`,
`Generation`, `FailureThresholds`, `StateCell`/`Transition`, `LoopScheduler`;
`PendingPingRegistry` and `PendingPings` live under `membership/domain/services`.
A duplicate `start()` is a no-op (above). No wire, storage or event-sequence
change.

## Addendum (batch F, 2026-09-26)

**Fixes landed (gossip-kt PR #15, merged 2026-09-26 as 25ac67e, head dda41a4, suite
1,255 → 1,269 across both modules — root 1,208, testing 61):** KCA1-22, KCA1-25, KCA1-47 (the
remainder), KCA1-48, KCA1-49. Recorded as already closed by earlier work,
not by this batch: KCA1-24 (`LocalNodeRepository` matched Dart's shape after
batch C, and ruling 6 made the finer split a shared follow-up), KCA1-26
(`getTailTimestamp` contract coverage landed with batch C), KCA1-35
(`ChannelService.dispose` is a one-liner since `StreamLocks`, batch D),
KCA1-50 (the README's counts were already gone).

- KCA1-22: frame classification was already `WireTypes`' alone; the envelope
  width now travels on the framing the classifier returns
  (`FrameFraming.V1.envelopeWidth`, `V2.envelopeWidth`; the undecodable case
  has none), so neither codec facade spells the width. The two sync dialects
  share their digest and version-vector codec (`SyncWireCommon`, six
  functions that were byte-identical copies) and each owns its expansion
  arithmetic (`SyncWireV1.maxEntryPayload = usable / 4`,
  `SyncWireV2.maxEntryPayload = (usable / 4) * 3`); the facade subtracts the
  envelope overhead and dispatches. Golden and conformance fixtures unchanged.
- KCA1-47: `ChannelAggregate.copy()` — a snapshot behind fresh collections,
  no uncommitted events — for the in-memory repository, which no longer
  reconstitutes from outside the aggregate. `reconstitute` stays for
  persistence adapters.
- KCA1-25: `InMemoryMessageBus`, `InMemoryMessagePort` and the seven-file
  harness (`TestNetwork`, `TestNode`, `Scenario`, `FixedClock`,
  `TestInstant`, `GuardedMemberPin`) live in `gossip-kt-testing`
  (`testing/bus`, `testing/harness`); the artifact ships neither (jar
  listing: zero entries). `InMemoryTimePort` stays. The boundary gate's
  `testing` row names `coordinator` and `membership` too, because a harness
  that drives whole nodes is a consumption root like the composition root
  it constructs; the lock and clock gates learned the module's adapter
  trees.
- KCA1-48, 49 and the carried gate items: one `SourceTrees` scanner for the
  gates (roots, project-root guard, walk, comment scrub); `BoundaryTest`
  blanks comments, states its limits (type aliases, reflection, strings) and
  pins the ACL concession to `MembershipPeerDirectory.kt` alone, failing a
  listed file that stops reaching across; the wire fixture loads guard the
  project root; `RetiredSurfaceTest` states that a renamed revival is not
  seen; both test tasks declare the scanned trees as inputs so a
  comment-only change re-runs the gates; and a seventh gate,
  `TestShapeTest`, fails any `@Test` method that returns a value (JUnit 5
  skips it silently — the batch E lesson, now mechanical); the check itself
  is `TestShape` in the testing module's harness, walks a module's compiled
  test classes and their ancestors (the inherited contract tests included),
  and both modules run it over their own tests. Each was proved
  by mutation before and after: a KDoc naming another context failed the
  old gate and passes the new; a stray reach from a second infrastructure
  file passed the old gate and fails the new, naming the allowlist; a
  value-returning test ran 12 of 13 declared cases under the old suite and
  fails the new gate by name.

**Timing against main, stated on purpose.** Nothing observable moved: the
codec's bytes are pinned by the fixtures; the aggregate copy is the same
snapshot the adapter made by reconstituting; the moved classes have no
production caller. The whole-branch review's table is therefore empty and
was still written.

**Consumer notes for the server bump after batch G.** The server's
`DigestExchangeReadsNoMarksTest` constructs `InMemoryMessageBus` from
`shared.infrastructure`; it imports
`com.neutrinographics.gossip.testing.bus.InMemoryMessageBus` after the bump
and the server's build adds `testImplementation` on `gossip-kt-testing`
(absent today). `ChannelAggregate.copy()` only if named. No wire, storage,
event or constructor change.

**Review rounds.** The whole-branch review found one Important item — the
skipped-test gate could not see the testing module's own tests and said the
module had none — and eight Minors; the fix wave made the check the
harness's, run by both modules (probes red in each), keyed the allowlist
project-relative like its sibling gates, and corrected three KDoc claims,
one of which (that a string literal is not seen) the plan itself had
prescribed wrongly. Not taken, recorded: a stale check for the adapter-tree
exemption (the trees exist by construction); a `Decodable` sub-interface
to finish ruling 13 by construction (a design change, later); the
self-referential delegation test (the fixed-value budget test is the pin).
A `DeltaMergerTest` serialization case flaked once under load and joins the
flaky-tests item.

**Owner-facing.** Ruling 14's Dart premise was wrong (Dart's bus is in the
library); the register carries the row for the owner's call. Batch G (the
minor sweep) is on the roadmap as its own item before the bump.

## Addendum (batch G, 2026-09-26)

**Fixes landed (gossip-kt PR #16, merged 2026-09-27 as b72569e, head 69fec9e, suite
1,269 → 1,282 across both modules — root 1,219, testing 63):** KCA1-30, 31, 33, 34, 36, 41, 43,
44, 45, 46, and the batch E/F observations (the registry's return-shape
asymmetry, the compaction scheduler built when compaction is off,
`ContiguityGap` self-validation, `healthStatus`'s two reads). KCA1-51 closes
as parity (both twins keep the retention policies under
`sync/domain/services`).

- Membership: a status move is one value, `PeerStatusChange(from, to)`,
  nullable when nothing moved; `PeerRegistry.updatePeerContact` and
  `recordProbeFailure` return it, the detector reads `to` for the verdict
  and `from` for the recovery line (both INFO lines unchanged, pinned).
  `PeerOperationSkipped.operation` is the enum `PeerOperation` (KCA1-30).
- Coordinator: one `stopEngines()` (engine, detector, compaction — the same
  order at the three sites; KCA1-31); the compaction scheduler exists only
  when an interval is configured (`LoopScheduler?`); `healthStatus` counts
  from one registry snapshot.
- Sync: a channel that vanishes between listing and read is logged at
  WARNING and still advertised empty (KCA1-33); the materialization service
  is required — the only production construction always passed one, so the
  three policies for its absence collapse to none (KCA1-34); one
  `hasSendCapacity` predicate (KCA1-41); `ContiguityGap` requires what a gap
  is; an empty persisted cursor restores as a start, not a rebuild, and the
  materializer contract says so (KCA1-36 — kt wrote `""` for "nothing
  folded" and read it as corruption; Dart never writes one).
- Shared: the RTT timeout defaults have one home (KCA1-45); `LogEntry.sizeBytes`'s
  comment says what the heuristic is (the formula is Dart's, unchanged;
  KCA1-43); `HlcProvider`'s KDoc names application services (KCA1-46); the
  `MessagePort.send` priority contract is stated and the in-memory bus
  honours it on a held link (KCA1-44).

**Timing against main, stated on purpose.** The three stop paths are in
their original order (engine, detector, compaction) at their original
points. `healthStatus` takes one registry read where it took two — the two
counts can no longer disagree. A coordinator without a compaction interval
builds no scheduler (it built one and never started it). A vanished channel
now produces one WARNING line where it produced nothing. A materializer
restored from an empty cursor folds from the start instead of being fully
rebuilt — the same folds, without the reset. The in-memory bus (test
dependency) delivers HIGH before NORMAL when a held link is released;
production transports are unchanged. Nothing else moved.

**Review rounds.** The whole-branch review found one Important — the
empty-cursor rule is consumer-visible and was missing from the bump list
(added above, with the server's `UserMaterializer` named) — and six Minors,
five taken in one fix wave (a deleted pin retargeted to the stream-existence
branch it still proves; the bus's `route` loses a priority default nothing
needed; `startCompaction` loses a guard and its how-comment; `stopEngines`'s
KDoc loses "inverse"; one shared inert-materialization fixture with its
reason) and one recorded (the event and the return value spell the same
transition twice — a register row for the next structural batch). The
`DeltaMergerTest` serialization case failed in five of roughly ten full
runs of this batch and passed in isolation every time; the flaky-tests item
records the frequency.

**Owner-requested controller review (2026-09-27).** Every production hunk
read against main for cohesion, coupling and the layer rules: the new values
validate themselves, the registry returns a domain value whose two ends its
one application consumer reads, nothing in `application/` names
`infrastructure/`, and the simulator's priority lives in the test-dependency
adapter over a shared domain value. Three KDocs fixed (69fec9e): one told
history instead of intent, one value documented its own reader, and the
shared kernel's clock port named a sync application class — a coupling in
prose the boundary gate rightly does not see. Recorded for the next detector
touch: the status-to-threshold mapping in the detector's verdict line is
`FailureThresholds`' knowledge.

**Observations left.** `ChannelService.entryRepository` remains the one
nullable dependency, with `StorageSyncError` branches for its absence — the
same kind of policy the materialization one was, but part of the public
error surface; a joint decision with Dart, not a sweep item.

**The server bump (after this batch).** Everything batches A–G changed that
the server can see, collected once:
- Build: add `testImplementation` on `gossip-kt-testing`; the server's
  `DigestExchangeReadsNoMarksTest` imports
  `com.neutrinographics.gossip.testing.bus.InMemoryMessageBus` (F).
- Repositories: `PgEntryRepository`, `MarksCachingEntryRepository` and the
  test `RecordingEntryRepository` drop `streamIds` and
  `entriesForAuthorAfter`; `PgLocalNodeRepository` drops its two incarnation
  methods; `PeerDto` drops `incarnation` (C). `ChannelAggregate.copy()`
  exists; `reconstitute` stays for the Postgres adapter (F).
- Config and health: `CoordinatorConfig(maxConnections = …)` no longer
  compiles; `HealthStatus` gains `state`; `CoordinatorConfig` validates its
  thresholds and durations (C).
- Events: the seven dead `SyncErrorType` values and the never-produced
  events are gone (C); `PeerOperationSkipped.operation` is the enum
  `PeerOperation` — a server match on the old string switches (E rename, G
  type); `PeerRegistry.addPeer`/`PeerService.addPeer` return `Boolean` (C).
- Registry and service returns, only if the server calls them:
  `updatePeerContact`/`recordPeerContact` and `recordProbeFailure` return
  `PeerStatusChange?` (E, then G); `FailureDetector.checkPeerHealth` is gone
  and `recordProbeFailure` transitions and logs (E).
- Persisted cursors grow to `Hlc(p:l)|author|seq` (fits the column);
  existing ones keep parsing (C). An empty persisted cursor now restores as
  a start — the same folds from the beginning without the reset — where it
  forced a full rebuild before (G); the server's `UserMaterializer` persists
  the cursor string it is handed and loads it back as is, so a user channel
  with nothing folded yet stops being rebuilt on every start; a materializer
  whose `initial` reports "nothing saved" as `null` is unaffected.
- Behaviour: every WebSocket `peers.add` sends a digest at once and holds
  probing 10 s unless the bootstrap probe answers (C); detector transitions
  log at INFO (B); one `ChannelRepository.findById` per stream digest per
  inbound digest — watch it in the re-measure (D); a duplicate `start()` is
  a no-op (E); `ChannelService.foldMergedEntries` refuses an unsorted batch
  (D); the priority a server port ignores is now stated as advisory (G).
- Types moved or newly public, only if the server names them: `EntriesMergedCallback`
  (D); `PendingPing`, `IntervalMode`, `RttTracking`, `PendingPulls`,
  `PendingPings`, `ProbeSelection`, `ProbeTiming`, `ProbeTimingConfig`,
  `Generation`, `FailureThresholds`, `StateCell`/`Transition`,
  `LoopScheduler`, `PendingPingRegistry` under `membership/domain/services`
  (E); the seven deleted `Synchronized*` service wrappers (E).
- Acceptance from batch A stands: surface the events backlog depth and
  measure the collector's throughput in a room.
