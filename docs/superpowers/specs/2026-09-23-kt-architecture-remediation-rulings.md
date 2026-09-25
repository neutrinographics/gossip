# Kotlin architecture remediation — rulings for review

The fixes for the [gossip-kt architecture audit](../../audits/2026-09-23-kt-architecture-audit.md)
(approved by the owner, 2026-09-23), taken as one program before the
digest-scoping work resumes. This page carries only the decisions that
need the owner's eye: the batch shape, the design choices where the
audit's fix direction has a real alternative, and the parity
bookkeeping. The implementation plans follow it and are execution
material, not for review.

The owner's standing rule for this program: the two libraries are going
for full parity, so every fix that Kotlin takes and Dart still lacks is
recorded for follow-up, and every fix that copies a shape Dart already
has says so. The parity sweep below sorts all 54 findings into three
classes: **port** (Dart is already right, Kotlin copies it), **shared**
(both twins have the smell; Kotlin fixes it now, Dart follows), and
**Kotlin-only**.

Acceptance is fixed in advance: the Kotlin suite green with the pins
below in; both architecture gates green with their debt rows shrunk, not
grown; a new machine check forbidding wall-clock reads outside
infrastructure and the composition root; no application file constructs
a `Synchronized*` wrapper or names a concrete codec; the server bumped
once at the end, live-device validated through the tunnel per the
runbook, with the health line unchanged; and a roadmap item holding the
Dart flow-back list.

## The parity sweep

**Port from Dart** (Dart has the shape; Kotlin copies it): KCA1-5
(`DeltaMerger`, `DigestBudgeter`), KCA1-6 (bookkeeping before the
notification), KCA1-9 (`FoldCursor`), KCA1-12 (the detector owns the
Ping reply; Dart's `failure_detector.dart:693`), KCA1-16 (grace period
wired through `holdProbing`; `isHealthy` is `state == running`;
`maxConnections` does not exist), KCA1-19 (`_syncWithNewPeer`), KCA1-20
and KCA1-21 (Dart's `EntryRepository` has neither `streamIds` nor
`entriesForAuthorAfter`; the aggregate owns stream identity), KCA1-23
(`TimeSource`), KCA1-28 (Dart retired the incarnation chain with the
relay), KCA1-37 (`removeChannel`, which is what emits `ChannelRemoved`),
KCA1-40 (one `LogLevel`), KCA1-43 (Dart's `sizeBytes` doc already says
"storage-quota heuristic, NOT the wire size"), KCA1-44 (Dart documents
priority as transport-optional).

**Shared** (both twins; Kotlin now, Dart recorded): KCA1-8 (Dart has
45 `DateTime.now()` reads in the same files), KCA1-13 (thresholds and
transitions in Dart's detector, `failure_detector.dart:520-540`),
KCA1-14 (Dart's `HlcClock`, `GossipTimingPolicy`, `PendingPullTracker`,
`ProbeTargetSelector`, `ProbeTimingPolicy` are the same stateful
services; `LoopGeneration` is Kotlin-only), KCA1-15 (Dart's
`GenerationScheduler` sits in `shared/domain/services` holding a
`TimePort`), KCA1-24 (Dart bundles identity and clock state in one
port too), KCA1-27 (Dart's pusher has the same `unawaited(_flush)` hole),
KCA1-32 in part (`NonMemberEntriesRejected` is dead in both; the seven
error types are unraised in both), KCA1-25 in part (Dart ships its
in-memory time port from `lib/` as a public testing aid, and keeps its
message bus under `test/`).

**Kotlin-only**: KCA1-1, 2, 3, 4, 7, 10, 11, 17, 18, 22, 26, 29, 30,
31, 33, 34, 35, 36, 38, 39, 41, 42, 45, 46, 47, 48, 49, 50, and the four
observations.

## Rulings

1. **Sequencing.** PR #9 merges first (it carries the audit's one PR
   item, KCA1-39, as 2ae48d5). Then item 9's Part B — the server bump
   with the ORDER BY, the frame ceiling and the workaround removal —
   ships alone, as planned, so production gets the total order now and
   that release keeps its short suspect list. The audit batches follow
   on gossip-kt, and one further server bump carries them all, with one
   live-device validation. (The alternative, folding Part B into the
   audit bump, saves one validation and costs the ordering fix a week
   or more in production.)

2. **Batch shape.** Six gossip-kt PRs off main, in this order, each
   its own plan, TDD, reviewed the item 9 way:
   - **A — reachable and small:** KCA1-1 (guarded channel store, a
     `SynchronizedChannelRepository` in `sync/infrastructure/`;
     `createChannel` and `compactStream` under the locks), KCA1-6,
     KCA1-17, KCA1-27.
   - **B — ports and clock:** KCA1-2, 3, 4, 40 (rulings 3 and 4);
     KCA1-8, 23 (ruling 5).
   - **C — surface and bookkeeping:** KCA1-9, 16, 19, 20, 21, 24, 28,
     32, 37 (rulings 6 to 9) and the register rows.
   - **D — engine extraction:** KCA1-5 (ruling 10).
   - **E — pure domain:** KCA1-13, 14, 15 (rulings 11 and 12).
   - **F — codec, kernel, gates:** KCA1-18, 22, 25, 26, 47, 48 (rulings
     13 and 14).
   The Minor findings not named above ride with whichever batch touches
   their file; what is left rides F. Every batch ends with both gates
   green and no new debt row.

3. **Engines depend on the port; nothing in the application layer
   constructs infrastructure.** `GossipEngine` and `FailureDetector`
   take `MessageCodec`, no default. Every `Synchronized*` collaborator
   becomes a constructor parameter typed against the pure class with no
   default, wired in `Coordinator.Companion` — the tracked item's own
   fix sketch, now paid in full, and its backlog item closes. The
   membership cycle closes by moving `PendingPingRegistry` (and
   `PendingPing`) to `membership/domain`: a registry of outstanding
   probes is a domain concept, and the wrapper then depends only inward.
   A new architecture pin: no file under an `application/` package
   references a `Synchronized` type or a concrete codec.

4. **One log vocabulary.** The engine's nested `LogLevel` goes; both
   engines take the shared `LogCallback`, severity included; the
   coordinator's two mapping functions go with it. The server's log
   adapter is unaffected (it already maps the shared enum).

5. **The clock is a port, read once, in the application.** A narrow
   `Clock` interface in `shared/domain/interfaces` (`nowMs` and
   `now(): Instant`); `TimePort` extends it; readers that need only a
   reading (`HlcClock`, `PendingPullTracker`, the error stamps) take
   `Clock`. Domain events take `at` as a required constructor argument
   with no default; the application service stamps it from its `Clock`.
   Errors are stamped the same way through one private helper per
   service. A new machine check, `ClockPlacementTest`, forbids
   `Instant.now()`, `System.currentTimeMillis()` and
   `System.nanoTime()` outside `infrastructure/` packages and
   `coordinator/`, with the same debt-row shape as the lock test and an
   empty map. Dart flow-back: `TimeSource` gains the `DateTime` reading
   and the 45 reads move.

6. **The dead surface goes, on both sides.** Deleted from Kotlin: the
   seven unraised `SyncErrorType` values, `BufferOverflowError`,
   `TransformSyncError`, `BufferOverflowOccurred`,
   `NonMemberEntriesRejected`, `ChannelAggregate.isMember`,
   `StreamConfig`, `maxConnections`, and the incarnation chain
   (`updatePeerIncarnation`, the wrapper's two methods,
   `PeerService`'s persistence, `LocalNodeRepository.get/saveIncarnation`,
   `Peer.incarnation` if nothing else reads it). `ChannelRemoved` and
   `SyncErrorOccurred` stay and gain their producers (ruling 7).
   `LocalNodeRepository` then matches Dart's shape (identity plus clock
   state); the finer split by concern is a shared follow-up, not this
   program. Dart flow-back: the seven error types and
   `NonMemberEntriesRejected`.

7. **The missing Dart behaviours are ported, not registered.**
   `removeChannel` on the service and the coordinator (emitting
   `ChannelRemoved`, calling `disposeChannel`); an immediate digest to a
   newly added peer (`_syncWithNewPeer`); the startup grace period
   through the existing hold; `isHealthy` computed from the run state;
   `FoldCursor` as a value object with the legacy timestamp-only parse
   rule so persisted cursors keep working. None of these needs a
   register row because after the batch there is no divergence.

8. **Stream identity belongs to the aggregate.** `EntryRepository`
   loses `streamIds` and `entriesForAuthorAfter`; the facades read
   stream lists through `ChannelService` from the aggregate, as Dart's
   do; `clearStream` retires the stream's key; `resourceUsage` walks the
   aggregate's streams. The published contract test gains
   `getTailTimestamp` (null on empty; the last entry in total order)
   and the positive `streamIds` tests are retired with the method. The
   server's two repositories drop the two overrides and the Postgres
   query in the audit bump.

9. **Coordinator events do not drop.** Every producer of
   `coordinator.events` is a suspending call site, so the emission
   becomes `emit`, and the flow keeps its buffer only as slack, never as
   a drop policy. The error flow keeps `tryEmit` (callers are not all
   suspending) and a refused emission falls through to the log callback
   at ERROR, so nothing is ever silent. The server's health ledger then
   counts every merge.

10. **The engine splits along Dart's seams.** `DeltaMerger` (the merge
    path of `handleDeltaResponse`: filter, settle, floor, contiguity,
    gaps, sort, append-and-notify, continuation) and `DigestBudgeter`
    (digest building, delta-request computation, and the response-side
    budget that gives `hasMore` a producer) become sync application
    services with Dart's names and responsibilities; the engine keeps
    the round loop, message routing and sending. Parity record E2 is
    restated to what is still true: no `KeyedTaskChain`, because the
    single-collector receive loop serializes handlers. Pagination is
    not implemented in this batch; the budgeter gives it a home.

11. **Domain services hold no state.** For each of `HlcClock`,
    `GossipTimingPolicy`, `PendingPullTracker`, `ProbeTargetSelector`,
    `ProbeTimingPolicy` and `LoopGeneration`, the state becomes an
    immutable value object and the behaviour becomes pure functions
    from (state, inputs) to (state, result); the value lives in one
    generic infrastructure holder (`SynchronizedState<T>` with
    `update { }` and `read { }`), replacing the six bespoke wrappers;
    the application composes the two. The failure detector's thresholds
    and the status transition table move onto the peer aggregate the
    same way: `Peer.transition(now, thresholds)` returns the new peer
    and the event, and the registry applies it under its one lock, which
    closes the read-decide-write race. The recorded `PendingPullTracker`
    smell closes with this batch. Dart flow-back: the same six splits
    (five in Dart; `LoopGeneration` has no Dart twin) and the transition
    table.

12. **The scheduler is a port and an adapter.** `LoopScheduler` becomes
    an interface in `shared/domain/interfaces` (start, stop, the
    generation contract); `GenerationScheduler` moves to
    `shared/infrastructure` as its adapter over `TimePort` and a
    `CoroutineScope`; `LoopGeneration` stays pure in the domain under
    ruling 11. Dart flow-back: the same move.

13. **The codec trio shares one envelope.** Frame classification and
    the envelope layout live in `WireTypes` alone; the two sync
    dialects share an envelope base the way Dart's emissions share a
    mixin; each dialect owns its own expansion arithmetic
    (`maxEntryPayload(usable)`), and `SyncMessageCodec` only subtracts
    the envelope and dispatches. The wire fixtures pin that no byte
    changes. `CachingChannelRepository` is dropped (nothing wires it)
    and the aggregate gains `copy()` for the one adapter that copies.

14. **Simulators and gates.** `InMemoryMessageBus` and the `support/`
    harness move to `gossip-kt-testing` (Dart keeps its bus under
    `test/`); `InMemoryTimePort` stays in `shared/infrastructure` as
    Dart's does; the server adds a `testImplementation` dependency on
    the testing module in the bump. `BoundaryTest` gains a known-limits
    block and a one-file allowlist for the ACL concession; CLAUDE.md
    gains the `testing` row; the wire fixture loads gain the
    project-root guard; the README drops its counts.

15. **Dart flow-back is one roadmap item.** A new Code-health backlog
    item, "Dart half of the Kotlin architecture audit", lists every
    shared finding above with its Kotlin shipping commit, so the Dart
    work is a port of a proven shape, not a redesign. Priority is the
    owner's; the recommendation is Medium, after the digest work, since
    nothing in the list is a production defect on the phones. The
    divergence register gains no rows for anything this program
    closes; it gains one row per shared finding until the Dart half
    ships, and the two accepted divergences (ruling 16) as permanent
    rows.

16. **The materializer state stream becomes latest-wins on both
    sides; one divergence is accepted.** The stream conflates: `replay = 1`,
    drop oldest, and a completing dispose, so a subscriber always holds
    the newest state and a late subscriber gets the current one on
    subscribe. A materialized view is state, and a consumer that needs
    every fold reads the log. Dart takes the same shape (a latest-value
    holder with replay on listen and one pending value per subscriber,
    replacing the bare broadcast controller): the app already routes
    around the Dart stream because a late subscriber can miss the fold
    (`start_sync_for_user.dart`, "can miss emissions due to subscription
    timing"), and its two remaining consumers map state to a derived
    value, so latest-wins changes nothing they observe and removes the
    workaround. This is a shared item on the flow-back list, not a
    divergence. The one accepted, permanent divergence is
    `LoopGeneration` plus the `SynchronizedState` holder, which exist
    only in Kotlin because Dart is single-isolate.

## Pins the plans must carry

- Channel store: two coroutines creating the same channel and stream
  concurrently on the default repository leave the stream registered;
  `createChannel` racing `createStream` cannot lose the stream.
- Bookkeeping order: a materializer that throws still leaves news
  recorded, anti-entropy credited, and `EntriesMerged` emitted, and the
  error reaches `onError`.
- Scope handler: a throw inside the pusher's flush and inside the
  bootstrap probe reaches `onError`, never the default handler.
- Events: a slow collector of `coordinator.events` sees every event.
- Clock: `ClockPlacementTest` is green with an empty debt map; under
  `InMemoryTimePort` every event and error stamp equals the simulated
  clock.
- Ports: no `application/` file references `Synchronized`, a concrete
  codec, or constructs a collaborator; the two engines compile against
  `MessageCodec`.
- Cursor: an entry tying the persisted cursor's timestamp and sorting
  after it on the author is folded after a restart; a legacy
  timestamp-only cursor string still parses.
- New peer: adding a peer sends it a digest before the next round.
- Identity: after `clearStream`, the stream is absent from the
  aggregate's list and from `resourceUsage`; the contract test covers
  `getTailTimestamp` on empty and on a tie.
- Extraction: every existing engine test passes unchanged against the
  split; the wire vectors are byte-identical.
- Purity: each state value is a `data class`; each transition is a
  pure function with a property-style test (same inputs, same outputs,
  no mutation); the detector's transition race test passes under the
  aggregate.
- Dead surface: a source grep for each deleted name is empty on both
  Gradle modules; the server compiles after dropping its overrides.

## Open points for the owner

1. Ruling 1: Part B of item 9 ships before the audit batches
   (recommended), or folds into the audit bump.
2. Ruling 11: the pure split — immutable state values, pure transitions,
   one generic holder — (recommended), or relabel the six as
   entities/aggregates and keep the bespoke wrappers, which satisfies
   the letter of DDD at a fraction of the cost but leaves the shape the
   standing rule rejects.
3. Ruling 16: a conflated materializer state stream (recommended), or
   every-update delivery with the emission moved outside the mutex to
   match Dart exactly.
4. Ruling 15: the Dart flow-back item at Medium after the digest work
   (recommended), or scheduled before it.

## Review outcome

**Approved as recommended (owner, 2026-09-23).** Part B of item 9 ships
before the audit batches (ruling 1); the six stateful services take the
pure split with one generic holder (ruling 11); the materializer state
stream conflates, and after discussion the owner asked for the same
shape on the Dart side, so ruling 16 is restated above as a shared item
rather than an accepted divergence; the Dart flow-back item lands at
Medium after the digest work (ruling 15). PR #9 merges with nothing
further added. The plans follow this record, one per batch.

**Precision note (batch A execution, 2026-09-23).** Two refinements made
during batch A, recorded here because they change what the rulings
promise. Ruling 9 said the events flow becomes a suspending `emit` with
the buffer as slack. The whole-branch review showed that a collector
which calls back into the coordinator from inside its own `collect` (the
server's side-effect processor does exactly this on a group discovery)
would wait on itself once the buffer filled, and the node would stop.
Batch A therefore gives the coordinator an unbounded internal queue and
one forwarder: producers never suspend, events are delivered in order
and never dropped, a collector may call back in, and a collector that
stops draining grows the queue, which the coordinator reports at WARN
past a thousand pending events. This is the Dart twin's semantics (an
unbounded per-listener queue), so ruling 9's "backpressure" wording is
withdrawn; the flow-back list gains nothing from it. Ruling 2 named a
`SynchronizedChannelRepository` wrapper; batch A guarded the in-memory
adapter itself with the monitor the entry repository already uses, which
the audit's fix direction allowed ("a wrapper or a guarded adapter") and
which keeps the lock in the same layer with one class fewer.

**Precision note (batch C execution, 2026-09-24).** Ruling 6 said
`ChannelRemoved` and `SyncErrorOccurred` stay and gain their producers.
`ChannelRemoved` did (batch C's `removeChannel`). `SyncErrorOccurred` had
never been produced on either twin — both libraries deliver errors through
the error callback and the errors flow — and giving it a producer would put
every error on the events flow a second time, which no consumer asked for
and Dart does not do. Batch C therefore deletes it (its own commit), the
owner confirmed the refinement before execution, and the matching Dart
deletion joins the flow-back list. Ruling 7's grace hold: Dart holds on
every `addPeer`, including a no-op re-add of a known reachable peer, which
lets a caller that re-announces its peers renew the hold indefinitely;
batch C holds only for an add the registry acted on (new or revived) and
records the divergence as a Dart flow-back rather than matching it.

**Precision note (batch D execution, 2026-09-25).** Ruling 10 named the
second extracted service `DigestBudgeter`, after Dart's. Dart's
`DigestBudgeter` byte-budgets digest lists (`fitRequest`, `fitResponse`) and
Dart cuts delta pages in the engine's `_fitDeltaToBudget`; the Kotlin
service extracted in batch D holds neither — it holds digest building, pull
planning and the page seam that is `hasMore`'s only producer. It is
therefore `PullPlanner`, and Dart's name is kept for the byte budget when
the wire-efficiency phase brings it. Ruling 10's "merge path" also gained
one guarantee the ruling did not ask for: `DeltaMerger` holds the stream's
lock across the merge, shared with local appends, compaction and removal,
which is what closed the limits batches A and C had parked.

**Precision note (batch E execution, 2026-09-25).** Three refinements to
rulings 11 and 12. First, the generic holder sits behind a port: the
application layer is typed against `StateCell<T>` in `shared/domain/interfaces`
(`update` runs a transition against the current value as one step; `read`
runs a query), and `SynchronizedState<T>` in `shared/infrastructure` is its
one implementation — batch B's layer rule (application never names
infrastructure) applies to the holder as much as to the wrappers, and the
wrapper-coverage gate admits exactly one such holder. Second, randomness is
an input: `ProbeTargetSelector` takes the random draw as an argument rather
than owning a generator, so a selection is a pure function and a test needs
no seeding. Third, the pending-ping registry, which the batch-B ledger
carried into this batch, splits the same way with one placement decision:
the `PendingPings` value records what is outstanding, and the coroutine
deferreds an ack completes are owned by the failure detector in a cell of
its own, so the domain carries no coroutine type. The detector's transition
is spelled as two named transitions on the peer (`probeFailed`, `contacted`)
rather than one `transition(now, thresholds)`, because the two are decided
at different call points with different inputs; the registry applies each
under its one lock, which is what ruling 11 asked for.
