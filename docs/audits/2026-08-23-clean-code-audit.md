# Clean Code Audit — `packages/gossip`

**Date:** 2026-08-23
**Scope:** `packages/gossip` only — all of `lib/` (12,575 lines, 63 files) and all of `test/` (28,913 lines, 138 files). Transport packages (`gossip_nearby`, `gossip_bluey`) not in scope.
**Rubric:** Clean Code — intention-revealing naming, one-job functions/classes, one abstraction level, CQS, DRY (knowledge duplication, not textual similarity), comments-say-why, information hiding / tell-don't-ask, explicit contextual error signaling (incl. the repo's own no-silent-errors rule), and tests as first-class code (AAA, F.I.R.S.T., one concept per test, harness quality). Explicitly **not** re-audited: protocol correctness (owned by the 2026-07-06/07-08 audits), wire scheduling (WIRE4), and Clean Architecture / DDD boundaries (ARCH3).
**Baseline:** [2026-07-08 comprehensive audit](2026-07-08-comprehensive-audit.md) (its MIN-*/OBS-* series is the closest prior clean-code coverage) and [2026-08-20 wire-scheduling audit](2026-08-20-wire-scheduling-audit.md).
**Method:** 10 parallel deep-read auditors by territory (5 production: sync/application, sync/domain+infrastructure, membership, shared kernel + public barrel, coordinator; 5 test: sync/application tests, sync/domain+infra tests, membership+architecture tests, coordinator+support+root tests, integration+shared tests), each reading its territory **in full**. Gates run by the orchestrator: `dart test` (1033 tests, all green), `dart analyze` (no issues). **Every finding below was personally re-verified by the orchestrator against today's source** (branch `working-connection`); adjusted and re-graded claims are listed in their own section. No fabricated citations were found — every spot-checked quote matched the file.

**IDs:** `CC5-n`, audit ordinal 5, following `COR3-n`/`WIRE4-n` convention.

---

## Verdict

This is a healthy codebase by Clean Code standards — clearly better than most of its size, and visibly the product of the last two months of audit-driven discipline. The strengths are real and structural: comments overwhelmingly explain *why* (often naming the exact race or bug class they forestall), errors carry rich actionable context and the no-silent-errors rule is honored essentially everywhere in production code, value objects validate their invariants with `ArgumentError.value` and reasons, fake time and seeded randomness make ~29k lines of tests deterministic with almost no wall-clock sleeps, and the newer test files (contiguity, compaction-floor, budget, lifecycle, adverse-network) are genuinely exemplary — `reason:` strings that teach the distributed-systems consequence of a failure.

The findings cluster into four themes, none of which is "this code is bad" and all of which are "this code is carrying avoidable future cost":

1. **Two god classes at the core.** `GossipEngine` (1,883 lines, ~22 constructor parameters, at least seven separable jobs) and `FailureDetector` (1,086 lines, 14 banner-comment sections, five jobs) are each a table of contents for what should be collaborating objects. The seams are already visible; nothing needs redesign, only extraction.
2. **Subtle machinery duplicated instead of named.** The keyed serial-task chain (the exact pattern that produced this project's memorialized `whenComplete` self-deadlock) is hand-rolled **five times** in four files, each slightly different. The probe lifecycle (sequence → track → send → await → cleanup) is written out five times inside `FailureDetector`. The generation-token scheduler exists three times. RTT clamp bounds exist twice. None of these has a name, so none can be fixed once.
3. **Documentation that contradicts the code it sits on.** The sharpest instance is public API: `Channel.removeMember`'s doc promises "revoking access" while the class doc 40 lines up (and ADR-007, and an integration test) state membership gates nothing. Three public doc examples don't compile — including the ones for `MessagePort` and `StateMaterializer`, the package's two primary extension points. Interface docs point implementers at the exact bug the same file's invariants section forbids.
4. **A two-tier test suite.** The post-audit test files are excellent; the older strata carry ~93 hand-rolled `Coordinator.create` blocks, byte-identical duplicated helpers, magic event-loop pump counts, cleanup that only runs on success, and a stratum of tautological tests (two literally assert `expect(true, isTrue)`). The harnesses that fix all of this exist and are only partially adopted — and the membership harness's one documented injection affordance is silently dead wiring.

Counts: **0 CRITICAL · 5 MAJOR · 24 MODERATE · 18 MINOR · 8 OBSERVATION** after merging duplicates across auditors and excluding items the 2026-07-08 audit already owns (those are dispositioned below, not re-reported).

---

## Baseline disposition

Clean-code-adjacent findings from the 2026-07-08 comprehensive audit, re-verified against today's source. (Correctness/perf items and transport items are out of scope here.)

| Prior finding | Today | Evidence |
|---|---|---|
| COR3-3 (no `onError` wired in facade) | **Fixed** | `coordinator.dart:281,286,320,337` all wire `_handleError` |
| COR3-8 (`EntryRepository` pre-fix contract docs) | **Fixed** | Contract now documents monotonic high-water marks and duplicate-throws (`entry_repository.dart:34-63`) — but see CC5-15: two *method* docs under it still contradict the ordering invariant |
| COR3-16 (`createChannel` silently resets) | **Fixed** | `channel_service.dart:149-153` returns early when the channel exists |
| MIN-1 (`disposeAll` live-map iteration) | **Fixed** | `materialization_service.dart:141-148` snapshots before awaiting |
| MIN-3 (oversized push skipped silently) | **Open** | `gossip_engine.dart:588` — bare `continue`, no trace log; also `:577-578` discards drained batches when no partners are reachable |
| MIN-4 (compaction unobservable; `StreamCompacted` never fired) | **Open** | `StreamCompacted` still has zero construction sites in `lib/` |
| MIN-5 (`Hlc.tryParse` leaks `ArgumentError`) | **Open** | `hlc.dart:148-154` catches only `FormatException`; the constructor throws `ArgumentError` for `logical > 65535`, which the parse regex admits |
| MIN-6 (retention constructors unvalidated) | **Open** | `retention_policy.dart:73,103,147` — `TimeBasedRetention`/`CountBasedRetention`/`CompositeRetention` are const ctors with no guards (classes renamed since the prior audit) |
| MIN-7 (phantom domain surface) | **Open** | `StreamConfig`, `ChannelDelta` (still with broken `==`/`hashCode`), `MergeResult`, `BufferOverflowOccurred` all still exported and production-dead — see CC5-16/CC5-38 for new detail on the doc damage they cause |
| MIN-8 (`VersionVector` ctor aliasing) | **Open** | `version_vector.dart:28-29` still stores the caller's map by reference; explicit-zero equality mismatch also unchanged |
| MIN-9 (`EventStream.getAll()` → `List<dynamic>`) | **Open** | `event_stream.dart:119` — `ChannelService.getEntries` returns typed `List<LogEntry>`; the facade erases it |
| MIN-13 (`InMemoryTimePort` diverges from contract) | **Open** | `in_memory_time_port.dart:63-67` — `schedulePeriodic` still ignores its interval |
| MIN-22 (doc drift: `Coordinator.events`, `RttEstimate` defaults) | **Open** | `coordinator.dart:893-897` still lists 4 of ~15 events; `rtt_estimate.dart:136` still says "min=200ms" against a 500 ms constant |
| OBS-3 (responder digest rotation) | **Fixed** | Shipped with the compaction scenario coverage (roadmap, `94e515a..e9f055e`) |
| OBS-8 (barrel exports aggregates with mutators) | **Open** | `gossip.dart:108` still exports `ChannelAggregate` |
| OBS-9 (vestigial surface: `entriesForAuthorAfter`, equal `CompactionResult` fields, dead `selectRandomPeer`) | **Open** | All three re-verified present; the engine's dead `selectRandomPeer` is folded into CC5-14 |

**Reversals: none.** The pattern is exactly what the recommendations predicted: everything routed through R2/R5/R8/R9/R13 landed and held; the R14 "sweep" bucket (MIN-*) has not been executed and is where most of the open baseline lives.

---

## 🟠 MAJOR

### CC5-1. `GossipEngine` is at least seven jobs in one 1,883-line class

`gossip_engine.dart:85` onward. The class owns: round scheduling (generation tokens + jitter), quiescence pacing, digest building with byte-budget fitting and two rotation cursors, delta paging, the merge pipeline (contiguity guard, floor adoption, HLC update, out-of-order detection), reactive-push debouncing, pending-request tracking with its own RTT estimator, and gap-diagnostic dedup. The constructor (`:305`) takes ~22 parameters; fields are declared mid-file next to their feature (`_mergeQueue` at `:1628`, `_reportedGaps` at `:1771`) because the class has become a collection of feature modules. Each feature is a distinct reason to change; a maintainer touching push debouncing scrolls past digest budgeting and merge logic.
**Fix direction:** extract collaborators along the seams the code already draws: `DigestBudgeter` (`_flattenDigests`/`_fitDigests` + cursors), `PendingPullTracker` (pending map + `_deltaRttTracker` + timeout), `ReactivePusher` (`_pendingPush` + debounce + flush), `DeltaMerger` (merge queue + contiguity + gap reporting). No behavior change; the tests largely already target these seams.

### CC5-2. `FailureDetector` mixes five jobs at different abstraction levels

`failure_detector.dart:89-1086` — 14 banner-comment sections (`:90,151,171,235,279,331,382,602,692,816,908,952,1002,1037`) index: (a) the scheduling loop, (b) probe-target selection policy (holds, freshness suppression, round-robin cursor), (c) three SWIM roles (prober, responder, intermediary), (d) RTT/timeout math, (e) transport plumbing. A banner table of contents at this density is the class asking to be split.
**Fix direction:** extract a `ProbeScheduler`, a `ProbeTargetSelector` (the three inlined eligibility policies at `:561-580` go with it), and the adaptive-timeout policy; the detector keeps protocol orchestration.

### CC5-3. The probe lifecycle is written out five times inside `FailureDetector`

`failure_detector.dart:412, 456, 506, 787, 880` — five sites each re-implement "allocate `_nextSequence++` → `_trackPendingPing` → send → await with per-peer timeout → cleanup in `finally`" (verified: all five present). The success test `gotIndirectAck || pending.completer.isCompleted` is likewise duplicated (`:522`, `:753`). This codebase's own history (individually-correct fixes interacting into COR3-1) shows what a missed edit in one of five copies of protocol choreography costs.
**Fix direction:** one `Future<bool> _probe(NodeId target, {bool allowForwarded = false})` encapsulating the dance; the five call sites become policy-only.

### CC5-4. Public membership docs promise access control the protocol does not enforce

`channel.dart:92-108`: `removeMember`'s doc — "The member will no longer receive updates or be able to write to streams. Used when: Revoking access" — with the same file's class doc (`:44-46`) stating membership is "**local metadata only** - it does not gate synchronization at the protocol level (see ADR-007)", confirmed by `sync_events.dart:167` and pinned as intended behavior by `test/integration/lifecycle/channel_operations_test.dart:194-238`. `members` ("peers that can read and write") and `addMember` ("will be able to read and write") carry the same false promise. A developer who trusts the method doc ships a privacy bug: the removed peer keeps receiving every update.
**Fix direction:** reword the three method docs to "edits replicated local metadata; does not stop the peer's replication — see ADR-007 for enforcement guidance."

### CC5-5. Test-suite construction sprawl: the builders exist and are not used

The suite hand-rolls `Coordinator.create(...)` **93 times** (71 in `coordinator_test.dart`, 16 in `monitoring_test.dart`, 6 in `peer_channel_index_test.dart` — counts verified), while three sibling files each define a *private* `createCoordinator()` helper that is itself copy-pasted (`coordinator_lifecycle_test.dart:35`, `coordinator_error_wiring_test.dart:23`, `coordinator_timing_passthrough_test.dart:131`). The same pattern repeats per territory: a byte-identical 18-line `createEngine` helper duplicated across `gossip_engine_test.dart:30-47` and `gossip_engine_message_handling_test.dart:29-46` (both files import the harness and use it only for later groups); the 3-line `PeerRegistry` arrange repeated ~27 times in `peer_registry_test.dart`; the 6-line `LogEntry` literal ~20 times in `in_memory_entry_repository_test.dart` while its sibling semantics file demonstrates the `entryOf()` builder; a 16-line fixture pasted three times in `event_stream_test.dart:363-451`. Consequence: a `Coordinator.create` signature change touches ~100 sites, and roughly a thousand lines of the suite are setup noise.
**Fix direction:** one shared coordinator builder in `test/support/` (with optional `bus`/`timePort`/`config` and built-in `addTearDown(dispose)`), harness adoption in the two big engine files, `setUp`/builders in the three files named above.

---

## 🟡 MODERATE

### Production — duplication of subtle machinery

- **CC5-6. The keyed serial-task chain is hand-rolled five times in four files.** `gossip_engine.dart:1609-1623` (`_mergeQueue`), `channel_service.dart:363-374` (`_appendQueue`), `materialization_service.dart:71-78` + `materializer_state.dart` (`opChain`), `peer_service.dart:108-123` and `:143-153` (persist and delete, duplicated within one class). Each copy differs subtly: the engine derives a separate `chainEntry` future; the channel service chains off the raw task; the materialization chain has no map cleanup and no `identical` guard. This is precisely the pattern class behind the memorialized `whenComplete` self-deadlock — a fix to one copy must be remembered four more times. **Fix:** one `KeyedTaskChain` (or `SerialTaskQueue`) utility in `shared/`, used by all five sites.
- **CC5-7. The generation-token scheduler is implemented three times.** `GossipEngine` (`:172-178, 473-501`), `FailureDetector` (`:185-191, 696-727`), and the Coordinator's auto-compaction loop (`coordinator.dart:415-454`), whose own comment admits "same pattern as the engine schedulers". The facade thereby also acquires a scheduling responsibility on top of composition. **Fix:** a shared `GenerationScheduler`, or move the compaction loop into sync beside `compactAll`.
- **CC5-8. The materialization publish protocol exists in three inconsistent versions.** `_initialize` saves → mutates → emits and documents why ("a failed save leaves the state unpublished", `materialization_service.dart:244-249`); `_fullRebuild` mutates `cursor`/`cachedState`/`isInitialized` *before* saving (`:266-276`); the incremental path mutates inside `_incrementalFold` before saving (`:188-196`). The comment claims a discipline two siblings break. Relatedly, `MaterializerState.emit` re-assigns `cachedState` that every caller already assigned (`materializer_state.dart:31-36`) — ownership of the invariant is split. **Fix:** one `_commit(matState, state, cursor)` fixing the order, `emit` becomes notify-only.
- **CC5-13. Timing-policy configuration is a field-triad puzzle in both engines.** `GossipEngine`: `_adaptiveTimingEnabled` + `_staticGossipInterval` + `_staticIntervalProvided` combined at `:370-376`. `FailureDetector` additionally stores **dead defaults**: `_pingTimeout = pingTimeout ?? 500ms` (`:144-145`) is only ever read when `_staticPingTimeoutProvided` is true (`:291,304,323` — verified all reads guarded), so the `?? 500ms` literally never takes effect and lies to the reader about the real fallback (the RTT tracker). **Fix:** a small sealed timing type (`Static(duration)` / `Adaptive()`) for the engine; nullable `Duration?` fields replacing flag+default pairs in the detector.
- **CC5-24. The codec's size estimator re-inlines the digest wire shape.** `sync_message_codec.dart:190-198` duplicates the map literal of `_encodeStreamDigests` (`:141-150`). If the digest shape changes, the engine's 32 KB budgeting silently diverges from actual encoding — the exact drift `encodedEntrySize` avoids by reusing `_encodeLogEntry`. **Fix:** a single `_encodeStreamDigest` used by both.

### Production — functions and dispatch

- **CC5-9. Both message loops mislabel every downstream failure as a corrupt message.** The engine's `_handleIncomingMessage` catch (`gossip_engine.dart:991-1002`) and the detector's (`failure_detector.dart:841-851`) each span decode *and* full handling; an exception thrown by registry updates or the app's event sink is reported as "Malformed … message" with `messageCorrupted` — sending an operator down the wrong path. The engine's doc additionally claims malformed messages are "silently ignored" (`:873-874`) while the code emits. **Fix:** catch decode separately (`messageCorrupted`) from handling (`protocolError`); fix the doc.
- **CC5-10. `_handleIncomingMessage` is a 129-line dispatch mixing abstraction levels.** `gossip_engine.dart:875-1003`: decode, metrics, liveness feeding, four-way `is`-dispatch, and — inside the `DigestRequest` branch — an inline shared-channel filtering policy. **Fix:** extract `_onDigestRequest` / `_onDigestResponse` / `_onDeltaRequest` / `_onDeltaResponse`.
- **CC5-11. `_computeDeltaRequests` interleaves five concerns in a 108-line nested loop.** `gossip_engine.dart:1319-1427`: missing-stream skip, pending-dedup with expiry, mark-pending-before-await (a reentrancy invariant), sequence-floor adoption, dominance decision. **Fix:** extract the per-stream body; the floor-adoption block (`:1379-1407`) is self-contained.
- **CC5-12. `maxDeltaResponseBytes` budgets far more than delta responses.** Verified used against `DigestRequest`s (`:752-753`), reactive pushes (`:588`), and digest responses — and it's a public field an embedder may tune under its narrow name. The oversized-digest error message even reads as a category error ("digest … cannot fit maxDeltaResponseBytes", `:817-818`). **Fix:** rename (`maxMessageBytes`/`transportBudgetBytes`) with a deprecation shim, or document the real role at the declaration.
- **CC5-14. The `selectRandomPeer` fossils.** Two methods with the same wrong name: the detector's is *live* — doc says "round-robin over a shuffled order" (`failure_detector.dart:544-557`), and it's a query-named command that advances `_probeOrderIndex` and reshuffles; the engine's is *dead* — no `lib/` caller (verified), kept alive by one test, doc still describing pre-WIRE4 random selection (`gossip_engine.dart:1107-1114`; the leftover was already noted in the prior audit's baseline). **Fix:** rename the detector's to `nextProbeTarget()`; delete the engine's.

### Production — contracts and docs that misdirect implementers

- **CC5-15. `EntryRepository` method docs contradict the class ordering invariant.** `entry_repository.dart:116-118`: "ordered by timestamp … sorted by HLC timestamp" — while the Ordering Guarantees section (`:34-39`) states sorting by timestamp alone is NOT sufficient and names the cross-device divergence that results. `entriesSince` repeats the weak claim. IDE hover shows the method doc, not the section; a conformance-kit implementer ships exactly the forbidden bug. **Fix:** restate the full `compareTo` order at method level.
- **CC5-16. Repository docs mis-home version vectors.** `channel_repository.dart:11-15` says each `ChannelAggregate` includes "Version vectors per stream (sync state)" — the aggregate holds only members and streams (`channel_aggregate.dart:52-53`); VVs live in `EntryRepository`, where hard invariants govern them. Same stale claim at `entry_repository.dart:13-14`. A persistent-`ChannelRepository` implementer would persist sync state in the wrong store. **Fix:** correct both lists.
- **CC5-17. Public doc examples don't compile.** (a) `message_port.dart:79-82`: the Implementation Example's `send` override omits the interface's named `priority` parameter (`:136-140`) → `invalid_override` for every transport author who copies it. (b) `state_materializer.dart:25-27`: `implements StateMaterializer<int>` with no `save` — the concrete default (`:85`) is only inherited via `extends`; the first-contact example for the main extension point fails to compile. (c) `real_time_port.dart:23-27`: `Coordinator.create(localNode: …)` — no such parameter exists. Plus `rtt_estimate.dart:37` assigns a method tear-off where a call is meant, and the `gossip.dart` quick start uses `utf8`/`Uint8List` without showing the needed imports. **Fix:** compile-check the examples (a doc-snippet test or careful sweep).
- **CC5-18. `PeerRepository` guidance contradicts itself across two files.** The interface: default `InMemoryPeerRepository` is "the recommended choice for most apps" (`peer_repository.dart:18-19`, and `Coordinator.create` really does default to it). The implementation: "**Use only for testing and prototyping**" (`in_memory_peer_repository.dart:11`). Also `findReachable`'s doc ("Used when selecting peers for gossip rounds") is false — gossip selects from `PeerRegistry`; in `lib/`, only `save`/`delete`/`clearAll` are ever called (verified), and under the file's own status-never-persisted contract `findReachable()` is semantically `findAll()`. **Fix:** rewrite the implementation doc to match the settled contract; delete or honestly document the unused query members.
- **CC5-19. A documented-as-supported configuration emits an error on every operation.** `peer_service.dart:27-30`: "When null, peers are not persisted (in-memory only)" — but `_persistPeer`/`_deletePeer` emit a `StorageSyncError(storageFailure)` on every add/remove in that mode (`:97-106`). Either it's valid (then this is alarm noise training users to ignore the error channel) or it isn't (then the field doc is wrong). **Fix:** pick one; if valid, no emit (at most a one-time log).
- **CC5-23. Untyped `Exception` at domain guards, with test-side fallout.** `channel_aggregate.dart:164-166` and `peer_registry.dart:182` throw bare `Exception(...)` for local-node protection; the facade documents "Throws [Exception]" (`coordinator.dart:631`). Tests are consequently forced into the weakest possible matchers — `throwsA(isA<Exception>())` (`channel_test.dart:82-85`), `throwsA(isA<Object>())` (`membership_message_codec_test.dart:70`) — which cannot distinguish the guard from an unrelated crash. The same input class is a silent no-op in `addMember` but a throw in `removeMember` — two conventions for one invariant. **Fix:** typed errors (`StateError` or a domain exception) and one documented convention; then strengthen the matchers.

### Production — facade discipline

- **CC5-20. The Coordinator absorbs its services' policy and reaches through their internals.** It computes the failure detector's probing-hold deadline from the *detector's own clock* (`coordinator.dart:639-642`: `_failureDetector!.timePort.nowMs + grace`), and `getAdaptiveTimingStatus` (`:836-865`) implements min-SRTT selection/variance pairing/global-fallback in the facade via `peer.metrics.rttEstimate`, `detector.rttTracker.*`, `engine.messagePort.*` chains. Timing-domain rules now live in the composition root. **Fix:** `FailureDetector.holdProbing(id, Duration)`; a status snapshot exposed by the owning contexts.
- **CC5-21. Channel lifecycle event emission is split between two owners.** `ChannelCreated` is emitted by `ChannelService` via `onEvent`; `ChannelRemoved` is constructed by the Coordinator (`coordinator.dart:583-588`) because `ChannelService.removeChannel` emits nothing. Anyone adding a lifecycle event must know to check both modules. **Fix:** emit `ChannelRemoved` from the service via the same path.
- **CC5-22. `ChannelService` leaks as a public field on both exported facades.** `channel.dart:79-80`, `event_stream.dart:89-90` — `ChannelService` is deliberately unexported, but every app holding a `Channel` gets one anyway and can bypass `Coordinator.removeChannel`, leaving `_channelFacades` stale and skipping `ChannelRemoved`. **Fix:** `@internal` at minimum; better, keep the reference out of the public shape.

### Tests

- **CC5-25. Magic event-loop pump counts couple tests to the engine's await depth.** Hand-rolled `for (…) await Future<void>.delayed(Duration.zero)` loops with unexplained counts 2/3/5/8/12 (`coordinator_merge_fold_error_test.dart:77-79`, `coordinator_compaction_test.dart:56,101`, `gossip_engine_test.dart:1032-1036`, `gossip_engine_digest_budget_test.dart:434-436`, harness-internal `flush(3)` at `gossip_engine_test_harness.dart:367,390,409`, more). One added await hop in production flips these red — or worse, lets an `isEmpty` assertion pass vacuously. The suite already contains both robust idioms (`pumpEventQueue()`; the bounded condition-poll in `gossip_engine_catchup_test.dart:249-254`). **Fix:** a harness `settle()` (condition-poll with iteration cap) and `pumpEventQueue()` elsewhere.
- **CC5-26. Cleanup runs after assertions, so it doesn't run on failure — suite-wide.** ~60 integration tests across 12 files end with `await network.dispose();` after the expects (e.g. `causality_test.dart` — all 13 tests, zero `tearDown` in file, verified); ~25 engine tests end with the `sub.cancel(); engine.stop(); h.stopListening();` trailer; no membership file has a `tearDown` and the harness's `dispose()` has zero callers (verified by grep). The correct idioms exist in-suite (`congestion_test.dart` try/finally; `basic_sync_test.dart` group `setUp`/`tearDown`). **Fix:** `addTearDown(...)` at construction (pairs with CC5-5's shared builder).
- **CC5-27. Test names promise behavior the assertions don't check (pattern).** Verified representatives: 'reachablePeers returns **only** reachable peers' with no unreachable peer in the fixture (`coordinator_test.dart:751-764`); 'probe round uses per-peer timeout' asserting only `failedProbeCount == 0`, which passes under either timeout (`failure_detector_adaptive_timeout_test.dart:168-182`); 'skipped with a **distinct** error' asserting only `errors, isNotEmpty` (`gossip_engine_digest_budget_test.dart:174-209`); 'calculates storage bytes **across all channels and streams**' over one channel/one stream asserting `greaterThan(0)` (`monitoring_test.dart:97-119`); 'create accepts custom config' never observing the config (`coordinator_test.dart:907-924`). **Fix:** strengthen the scenario or rename to what is checked.
- **CC5-28. Tautological and misdirected tests.** `domain_event_test.dart` — both tests assert `expect(true, isTrue)` (verified; the claims could be made real with a local `extends` declaration). `sync_error_test.dart:116-128` — eleven `values, contains(...)` assertions that cannot fail at runtime. `coordinator_test.dart:865-905` — two `null as dynamic` tests asserting the language's `TypeError`, verifying no library behavior. `coordinator_test.dart:853-863` — 'create throws when localNode is empty' throws `ArgumentError` from `NodeId('')` *before* `Coordinator.create` runs, so create-side validation is unexercised. Plus the constructor-echo strata (`digest_request_test.dart`/`digest_response_test.dart` byte-for-byte clones, `adaptive_timing_status_test.dart` 'supports const construction', `peer_test.dart:60-64` passing the value it claims is defaulted, `ack_test.dart`/`ping_test.dart`). ~400 lines of suite that protect nothing. **Fix:** delete or make real.
- **CC5-29. `CompositeRetention`'s union semantics are untestable by its own test.** `retention_policy_test.dart:157-196`: in the 'keeps entries retained by ANY policy' fixture every entry is kept by both policies or dropped by both (the inline comments admit it — verified), so a regression from union to intersection passes green; the dedup test uses two `KeepAllRetention`s and has the same blindness. `compact()`'s defining semantic is unpinned. **Fix:** one entry retained by exactly one policy (old but author's-latest). *(Re-graded from the finder's MAJOR: production is correct today; this is a hazard, not a live defect.)*
- **CC5-30. Wire pinning is decode-side only for three of four sync messages.** `sync_message_codec_test.dart` never asserts `encoded[0]` anywhere (verified — `jsonOf` strips the type byte unchecked); DigestRequest/DigestResponse/DeltaRequest are covered only by `decode(encode(x))` round-trips, which stay green if encoder and decoder co-drift — the exact "forbidden" wire break `WireTypes` warns about. The legacy-frame tests show the right golden style for byte 6. **Fix:** golden-assert the type byte and JSON key set per message.
- **CC5-31. The membership harness's documented affordance is dead wiring, and its waits hang instead of failing.** (a) `failure_detector_test_harness.dart:207-240`: "Pass [messagePort] to use a custom MessagePort implementation" — but the factory always builds its own bus, so an injected port lives off-bus and `sendPing`/`expectPing` silently do nothing (verified in the factory body); consequence: three hand-rolled full detector setups in `failure_detector_error_handling_test.dart:289-397` and a parallel bus in `failure_detector_test.dart:186-195`. (b) `capturePing`/`expectPing` (`:132-143`) complete only on arrival — no timeout, no diagnostic; two files carry comments acknowledging the hang hazard, and this project has a documented history of opaque test hangs. **Fix:** accept a port *decorator* applied to the harness's own port; race the completer against a generous timeout that fails with "no Ping arrived — was the probe suppressed?".
- **CC5-32. Detector tests that branch on unseeded randomness.** `failure_detector_test.dart:393-407` wires one of two different topologies depending on which peer random selection picked (with a never-cancelled subscription on one branch); `failure_detector_recovery_test.dart:57-73` loops "up to 12 rounds" to outwait selection nondeterminism. The suite's own good pattern (seeded `Random` with the seed choice documented — `probe_selection_test.dart:20-23`) is the fix.
- **CC5-33. `channel_service_test.dart` hand-rolls 168 lines of degenerate fakes.** `:19-186`: `FakeChannelRepository`/`FakeEntryRepository` duplicate the real in-memory implementations every sibling file uses — except `entriesSince` returns `[]`, `sizeBytes` returns 0, and `removeEntries`/`adoptVersionFloor` are silent no-ops, so any future test routed through those paths misleads instead of erroring. **Fix:** delete the fakes, use the real in-memory repos.
- **CC5-34. `TestNetwork`'s query helpers mutate the node under observation.** `test_network.dart:664-685`: `entryCount`/`entries` call `getOrCreateStream`, so an assertion accessor can create the stream (default retention) on the observed node — its digests then advertise a stream it never legitimately had, inside the very convergence checks these helpers serve. The doc note admits the side effect without removing it. **Fix:** read via a non-creating path.
- **CC5-35. Scenario ownership is duplicated across the suite.** Entry-repository contracts asserted in both `in_memory_entry_repository_test.dart` and `..._semantics_test.dart` with near-identical rationale comments; `message_handling_test.dart`'s "Message loss and recovery" group re-tests scenarios owned by `partition_sync_test.dart`/`churn_sync_test.dart` (one test is even named for an asymmetric partition it doesn't perform, with a stale "not directly possible" comment — `partitionOneWay` exists); interval-pacing pinned in both `gossip_engine_test.dart` and `gossip_engine_interval_pacing_test.dart`; `gossip_experiment_test.dart` is two strict subsets of `coordinator_test.dart` under a scaffolding name whose lib-side twin TODO.md records as already deleted. **Fix:** consolidate each scenario into an owning file; delete the experiment file.

---

## 🟢 MINOR

- **CC5-36.** Stale facade docs: `start()` still lists "(once integrated)" bullets for long-integrated engines (`coordinator.dart:914-917`); `SyncState.stopped` documented only as the initial state though `stop()` transitions there (`sync_state.dart:3-4`); `Coordinator.create` doc omits `random` and `onLog` — its two least self-explanatory parameters (`coordinator.dart:191-218`).
- **CC5-37.** Misleading kernel docs: `LogEntry.sizeBytes` describes a fictional binary wire layout (int32/int64/length prefixes) when the wire is type-byte + JSON + base64, and claims "wire protocol sizing" when its uses are storage quota (`log_entry.dart:70-79`); `RttTracker` doc states the pre-halving 1 s/500 ms defaults (`rtt_tracker.dart:51-52`); `TimeSource` claims to be an anti-corruption layer over infrastructure when `TimePort` is itself a domain interface (`time_source.dart:5-8`); `InMemoryTimePort.tick` is "legacy" only in prose, not `@Deprecated` (`in_memory_time_port.dart:44`); `QuiescencePacer.ceiling` says "not configurable" on a required constructor parameter (`quiescence_pacer.dart:11-12`).
- **CC5-38.** Membership doc drift: `PeerStatus` describes canonical SWIM ("indirect probe in progress") rather than this implementation's threshold semantics (`peer_status.dart:1-7`); `PeerOperationSkipped` doc lists emitters (`updatePeerContact`, "etc.") that are all documented non-emitters — only `updatePeerStatus` fires it (`membership_events.dart:58-63`, emission verified singular at `peer_registry.dart:227`); `PeerService` "Transaction:" comments promise atomicity that doesn't exist (`peer_service.dart:69,86`); `Peer` "compared by identity … and state equality" self-contradiction and `PeerMetrics` calling itself an entity while implementing a value object (`peer.dart:20`, `peer_metrics.dart:18`).
- **CC5-39.** Sync doc drift: `EntryAppended`/`EntriesMerged` docs attribute emission to `EntryRepository` methods; actual emitters are `ChannelService`/`Coordinator` (`sync_events.dart:87,104`); "[ChannelAggregate] aggregate" boilerplate ×5 plus a dangling `[Channel]` reference to a class in another layer (`channel_service.dart:24-327`); `handleDeltaResponse` carries two fused doc generations including a stale claim (`gossip_engine.dart:1566-1578`); the adaptive-interval policy is restated in four doc comments, one with a search-and-replace grammar artifact ("called at adaptive:" — `gossip_engine.dart:646`, verified) proving the copies are already drifting.
- **CC5-40.** Comments keyed to unresolvable shorthand: "(final review, item 2)" (`failure_detector.dart:161-162`), "Task 5's move" / "Part 2 spec" (`message_codec.dart:2-4`, `wire_types.dart:1`, `boundary_test.dart:4,35`), "see task-6-report.md" (`failure_detector_pacing_test.dart:32` — the file exists locally but is **gitignored** under `.superpowers/`, so the reference resolves in no other clone), WIRE4-19 roadmap pointer in a port doc (`peer_directory.dart:18-19`), and 16 audit-key mentions in `gossip_engine.dart` with nothing naming where they resolve. One line in each class doc naming `docs/audits/` fixes the whole class of these.
- **CC5-41.** Vocabulary forks: `TimePort` type vs `timerPort` parameter/variable everywhere plus `nowMs` vs `nowMillis` (`coordinator.dart:214`, `time_source.dart:28`); "peer" vs "partner" inside the engine (`syncWithPeer`/`selectRandomPeer` vs `SyncPartner`/`_selectGossipPartner`); `probablePeers` — a pun on "probe-able" that reads as "likely" (`peer_registry.dart:132`); `_loadChannels` vs `_loadExistingChannels`, different jobs (`coordinator.dart:358,513`); near-twin wrapper names `_probeRound`/`performProbeRound` and `_handleDigestRequest`/`handleDigestRequest`; `EventStream.compact({bool resetState})` shadowing the `resetState()` method three declarations up and renaming to `resetMaterializers` one layer down (`event_stream.dart:178-204`); `recordProbeFailure` → `incrementFailedProbeCount` vocabulary fork on a one-line pass-through (`failure_detector.dart:647-650`).
- **CC5-42.** Magic literals and constant hygiene: the `40`-byte channel-envelope overhead (`gossip_engine.dart:810`) and a `+1` comment three lines from its subject (`:1529-1533`); `_metricsWindowDurationMs` as a raw int with a value-restating comment in a class of `Duration` tunables (`:264-267`); the SWIM fanout `3` at its single call site (`failure_detector.dart:779`); HLC's 16-bit limit as `65535` twice in code plus prose (`hlc_clock.dart:72,123`); three clamping styles for one operation (nested ternary `failure_detector.dart:325-327`, if-chain `:934-936`, `RttTracker._clampSample`).
- **CC5-43.** RTT clamp bounds (50 ms / 30 s) duplicated as private constants in `FailureDetector` (`:926-927`) and `RttTracker` (`:35-38`), with the detector's comment admitting the mirroring — plus the doc block fusion that leaves `_recordRtt` undocumented and its constants stranded 770 lines from the Constants section (`failure_detector.dart:912-929`).
- **CC5-44.** `_appendEntryNow` duplicates `takeTimestamp()`'s exact body — timestamp-with-fallback + persist-clock — while the crash-recovery rationale lives only on the helper (`channel_service.dart:411-418` vs `:513-518`, verified byte-equivalent). One-line fix.
- **CC5-45.** `PeerRegistry` re-implements "recover a peer" in `addPeer` and `updatePeerContact` with different mechanics (`peer_registry.dart:186-192` vs `:254-268`), and `updatePeerContact` alone manufactures `DateTime.now()` for its event while taking injected `timestampMs` for state — event/state timestamps diverge under fake clocks (`:258`).
- **CC5-46.** CQS and dead-surface residue: `registerMaterializer` returns a doc-admitted always-empty `List<DomainEvent>` (`channel_service.dart:542-550`); `_awaitAckWithTimeout`'s `sequence` parameter is never read (`failure_detector.dart:989-996`, verified); `checkPeerHealth` is a state-transitioning command named as a query (`:661-690`); `Coordinator._`'s `gossipEngine`/`failureDetector` parameters are required yet only ever receive `null` (`coordinator.dart:174-175,301-302`); `VersionVector.set`/`increment` and `RttTracker.reset` are production-dead public kernel members (verified no `lib/` callers); `FoldCursor`'s bare constructor permits the author-without-sequence mix that makes `isBefore` throw on `sequence!` (`fold_cursor.dart:27,49`); `hasStream` guard applied in `getState` but not `getStateStream`/`resetState` (`channel_service.dart:557-597`).
- **CC5-47.** Missing `@visibleForTesting` on the detector's test-only public surface — enforced today only by a banner comment ("public for testing", `failure_detector.dart:602-604`), while `coordinator.dart` shows the package already uses the annotation. Same gap on `PeerMetrics` (`@immutable` absent; three hand-copied 7-field constructions that a `copyWith` would collapse, `peer_metrics.dart:66-115`).
- **CC5-48.** `ChannelAggregate` details: constructor defaults `occurredAt` to `DateTime.now()` while every mutator requires it (`channel_aggregate.dart:59-65`); `hasMember(NodeId id)`/`hasStream(StreamId id)` shadow `this.id` with a different meaning (`:95,101`); `ChannelDigest.hashCode` XOR-folds (order-insensitive, self-cancelling) while `==` is order-sensitive, diverging from `StreamDigest`'s `Object.hash` (`channel_digest.dart:50-54`).
- **CC5-49.** Parallel `is`-dispatch chains in both codecs — `_getMessageType`/`_encodeMessageData`(/decode switch) must be edited in lockstep to add a message, and the membership codec throws the identical `'Unknown message type: …'` string for three distinct failure modes (`sync_message_codec.dart:61-81`, `membership_message_codec.dart:51-105`).
- **CC5-50.** `applyJitter` documents `[0, 1]` but silently floors negatives and accepts `fraction > 1` (which can yield negative `Duration`s) — the one range-checkable function in a kernel that otherwise throws `ArgumentError.value` for invalid ranges (`jitter.dart:12-16`).
- **CC5-51.** `InMemoryMessagePort` API surprises for its test consumers: `clearSimulatedPendingCounts` also zeroes the *global* count (`in_memory_message_port.dart:557-561`); `totalPendingSendCount` contradicts `pendingSendCount`'s documented per-peer-fallback semantics (`:564-575`); `deliver(destination, sender, …)` reverses the `(from, to)` order every other bus method uses — same-typed parameters, silent-swap hazard (`:366` vs `:142-155`). Also `EntriesMergedCallback` — not an error concept — lives at the bottom of `errors/sync_error.dart` (`:196`).
- **CC5-52.** Stack traces captured then dropped: handlers use `catch (e)` without `, st` (`gossip_engine.dart:852,991`, `channel_service.dart:700`), and `catchError((error, stackTrace)…)` sites forward only `error`; `_log` accepts a `StackTrace` these paths never feed. Post-dispose errors additionally vanish without trace in `Coordinator._handleError` (`coordinator.dart:374-378`) despite `onLog` being available as a fallback sink.
- **CC5-53.** Test hygiene smalls: real wall-clock sleeps where a pump exists (`error_emission_test.dart:151,195`; `in_memory_message_port_test.dart:92`; scripted 30/50 ms latencies in `peer_service_ordering_test.dart`); ~20 un-awaited `service.register(...)` calls in `materialization_service_test.dart` against a `Future<void>` signature its own sibling files await; un-awaited `advance` (`time_source_test.dart:13`) and `performGossipRound` (`gossip_engine_test.dart:278`); `dynamic` where `NodeId` is meant (`gossip_engine_pending_delta_test.dart:20`); the magic-109 `totalBytes` pin encoding the kernel's 52-byte overhead in a VO test (`channel_delta_test.dart:50-57`); seed-loop without `reason: 'seed $seed'` (`membership_peer_directory_test.dart:171-175`); `TestNetwork`'s redundant `_originalPorts` map and O(n²) `indexOf` seeding with silent duplicate-name overwrite (`test_network.dart:60,90-91`).
- **CC5-54.** Format drift: `dart format` would change 25 of 33 files in `test/sync/application` and 6 of 81 in `lib` (Dart 3.11.5; some churn may be formatter-version drift against sdk `^3.10.4`, but two blocks are objectively mangled copy-paste artifacts with comment lines outdented from their loops — `gossip_engine_scheduling_test.dart:150-154` and `failure_detector_scheduling_test.dart:62-66`, the same broken block pasted into two different files). The repo's own gate is `melos run format`.

---

## 🔵 OBSERVATION

- **CC5-55.** Mixed query shapes on the public facades — async getters, `getX()` methods, and bare-noun methods coexist (`channel.dart:88,111`; `event_stream.dart:119-184`); pick one convention.
- **CC5-56.** The snapshot-keys-then-`findById` idiom is re-implemented in three Coordinator methods with the CME subtlety re-explained twice (`coordinator.dart:517-523,607-613,772-777`).
- **CC5-57.** `PeerDirectory.recordMessageReceived(NodeId, int, int, int)` — three adjacent transposable ints, deliberately mirroring `PeerRegistry`; if the port is extended (the doc's own WIRE4-19 plan), switch to named parameters at both seams.
- **CC5-58.** Debug-only counters (`_acksReceived`/`_pingsSent`) live as detector instance state but feed only log strings (`failure_detector.dart:209-210`).
- **CC5-59.** `RttTracker.suggestedTimeout`'s four-branch null dispatch exists only because `RttEstimate` hides its defaults behind non-nullable parameters (`rtt_tracker.dart:101-111`).
- **CC5-60.** `SyncError` hierarchy repeats `type`/`cause` fields+docs across three subclasses, and `BufferOverflowError` takes five positional same-ish-typed arguments (`sync_error.dart:36-83,131-138`).
- **CC5-61.** Audit-traceability comments (COR3-n, WIRE4-n, H-n) are a genuine strength in test file headers, but 16 occurrences in `gossip_engine.dart` carry no pointer to where the keys resolve — one class-doc line naming `docs/audits/` makes them self-standing (overlaps CC5-40's fix).
- **CC5-62.** `boundary_test.dart` extracts modules by splitting on `'/'` — fails loudly (RangeError), not silently, on Windows separators; `package:path` would make the suite portable.
- **CC5-63.** Integration-test slack worth an intent comment where used: `anyOf(suspected, unreachable)` in deterministic scenarios (`peer_status_test.dart:49-53`), the mirrored private `congestionThreshold = 3` (`congestion_test.dart:8-11`), and drifting unexplained round budgets 5→40 in the older sync tests (the newer files derive every budget from a documented mechanism — that's the standard to hold).

---

## What is genuinely healthy (verified — protect on purpose)

- **Why-comments that carry invariants.** `_lifecycleEpoch` race rationale (`coordinator.dart:142-148`), the generation-token idiom explained at field and use site in both engines, `takeTimestamp`'s "a getter with state-mutating side effects is a trap" (`channel_service.dart:506-513`), `caching_channel_repository.dart:48-53` documenting the real Dart `whenComplete` self-deadlock and why the block form must stay, `in_memory_entry_repository.dart:159-163` explaining the interleaving window `appendAll` forecloses. **Zero commented-out code was found in any of the ten territories.**
- **Error handling as a contract.** `MessagePort`'s failure semantics ("Never complete a known-failed send as success", `message_port.dart:99-105`) turn the house rule into an enforceable port contract; every production `catch` in membership and sync either emits via `ErrorCallback` with peer/type/cause context or is documented deliberate policy; errors suggest remediation ("consider compaction or sharding", `gossip_engine.dart:816-821`); transport-stream `onError` handlers exist with comments explaining exactly what breaks without them.
- **The kernel's invariant discipline.** Every value object validates with `ArgumentError.value(value, name, reason)`; `Hlc.maxPhysicalMs` documents both the 48-bit packing and "~year 10889"; `RttEstimate` cites RFC 6298; `WireTypes` states "changing an existing value is a wire-format break and is forbidden" where the constants live; the null-vs-throw foreign-frame contract is crisp and honored by both codecs.
- **`entry_repository.dart`'s Critical Invariants section** — port documentation that states the *consequence* of each violation ("resurrection", "permanently invisible"), repeated at exactly the right method sites. The conformance-kit direction should build on this (after CC5-15's method-doc fix).
- **The ACL done right.** `membership_peer_directory.dart` is one membership import, documented pure forwards, mapping isolated in `_toPartner` — and its test file is a model contract suite (no mocks, real registry, seeded-Random equivalence instead of re-implementing selection).
- **Deterministic test infrastructure.** Fake time everywhere time matters; seeded `Random` with the *seed choice explained* (`probe_selection_test.dart:20-23`); `InMemoryMessageBus`'s documented, implemented-in-order condition pipeline; `test_network.dart`'s discoverability (usage examples, section banners, determinism rationale) is far above typical support code.
- **The post-audit test craft.** `reason:` strings that teach ("reusing seq 1-5 makes new entries permanently invisible to peers whose version vector already covers them"); anti-vacuity guards (`idle_quiescence_test.dart:110-119` asserts *not*-converged before asserting repair); wire tests that hand-build legacy frames with literal type bytes; race tests using gated completers instead of sleeps (`materialization_reentrancy_test.dart`); file headers binding tests to the audit finding they pin (COR3-14, COR3-3, COR3-16, WIRE4-5, M3). This is the standard the older strata should be raised to — not the other way around.
- **`boundary_test.dart`** — the machine-checked context rule is genuinely readable: the edge table is data with self-explanatory row comments, `..`-escapes are banned rather than resolved, and every violation message tells the reader what to do next.

---

## Adjusted / discarded claims

The verification pass changed the following; everything else above was confirmed as reported. **No fabricated citations were found** — every opened quote matched the source.

- **Re-graded down:** `EventStream.getAll()` type erasure (reader: MAJOR) → **baseline-open MIN-9**, owned by the prior audit; `Coordinator.events` doc gap (MODERATE) → baseline MIN-22; the oversized-push silent skip (MINOR) → baseline MIN-3. The dead-surface family (`StreamConfig`, `ChannelDelta`, `MergeResult`, dead events, `entriesForAuthorAfter`, `CompactionResult.noChange`) was reported by the sync-domain reader correctly pre-marked as known — dispositioned under MIN-4/MIN-7/OBS-9 rather than re-numbered.
- **Re-graded down:** the `CompositeRetention` union-blindness test (reader: MAJOR) → **CC5-29 MODERATE** — production is correct today; the ladder grades unreachable-today defects as the hazard they are. Similarly the `expect(true, isTrue)` file (reader: MAJOR) → folded into **CC5-28 MODERATE**.
- **Corrected detail:** the membership reader claimed `task-6-report.md` "does not exist in the repository (verified by search)". It **does** exist at `.superpowers/sdd/task-6-report.md` but is gitignored — the finding stands with corrected wording (unresolvable in any other clone), CC5-40.
- **Corrected detail:** the coordinator-tests reader quoted the 'localNode is empty' test as asserting `TypeError`; it actually asserts `throwsArgumentError` (that matcher belongs to the adjacent null-repository test). The substantive claim — the throw comes from `NodeId('')` and never reaches `Coordinator.create` — is confirmed, CC5-28.
- **Caveated:** the format-drift count (25/33 files) may be partially formatter-version drift (Dart 3.11.5 vs sdk `^3.10.4`); the two mangled comment blocks are unambiguous regardless, CC5-54.
- **Merged:** ~150 raw findings from ten readers merged to 55 by de-duplicating cross-territory reports of the same knowledge (keyed chains, generation schedulers, codec dispatch chains, `selectRandomPeer`, `timerPort`, pump counts, teardown pattern, tautologies).
- **Not independently adjudicated here:** each reader's "possible out-of-rubric defects" (18 items — e.g. the fold-path save-failure publish edge, `_flushPendingPushes` discarding drained batches when no partner is reachable, `FoldCursor`'s `|`-delimiter parse trap, the compaction loop dying on a *scheduling* failure while the coordinator reports `running`, `Hlc.subtract` throwing at the epoch under simulated time, `InMemoryMessageBus.register` last-write-wins silently deafening a prior port — which demonstrably bit one test). These are recorded as **candidates for the next correctness pass**, verified to exist in code but not graded under this rubric.

---

## Recommendations

| # | What | Findings | Effort |
|---|---|---|---|
| R1 | **Doc-truth sweep on the public surface**: membership-revocation wording, the three non-compiling examples, `EntryRepository` method-order docs, VV mis-homing, `PeerRepository` contradiction, plus the CC5-36..40 drift list and open MIN-22 | CC5-4, 15, 16, 17, 18, 36–40 | Small — docs only, highest trust-per-hour |
| R2 | **Shared async utilities**: one `KeyedTaskChain`, one `GenerationScheduler`, the `_commit` publish helper; adopt at all eleven sites | CC5-6, 7, 8 | Small–Medium |
| R3 | **Error-context batch**: split decode/handling catches in both loops, typed domain exceptions (then strengthen the weak test matchers), null-repo policy decision, post-dispose error fallback to `onLog`, thread stack traces | CC5-9, 19, 23, 52 | Small–Medium |
| R4 | **`FailureDetector` extraction**: `_probe` helper first (kills the ×5 duplication cheaply), then scheduler/selector split; rename `selectRandomPeer`, `checkPeerHealth`; `@visibleForTesting` | CC5-2, 3, 14, 46, 47 | Medium |
| R5 | **`GossipEngine` extraction**: handler split (`_onX`), `_maybeBuildDeltaRequest`, then the four collaborators; rename `maxDeltaResponseBytes`; sealed timing type | CC5-1, 10, 11, 12, 13 | Large — highest payoff, do after R2 lands the shared utilities |
| R6 | **Test-support consolidation**: shared coordinator builder with `addTearDown`, harness adoption in the two big engine files, harness `settle()`, membership-harness decorator + timeout, delete the degenerate fakes | CC5-5, 25, 26, 31, 33 | Medium — pays for itself in the next signature change |
| R7 | **Assertion-strength pass**: delete/realize tautologies, fix over-promising names, the union fixture, encode-side wire pinning, seed the dual-path tests | CC5-27, 28, 29, 30, 32 | Small–Medium |
| R8 | **Facade discipline**: `holdProbing(Duration)`, status snapshots from owning contexts, `ChannelRemoved` from the service, `@internal` on the leaked service fields | CC5-20, 21, 22 | Medium |
| R9 | **Mechanical hygiene**: `melos run format` (fix the two mangled blocks), magic-literal constants, `takeTimestamp` reuse, `TestNetwork` accessor side effect, scenario consolidation, delete `gossip_experiment_test.dart` | CC5-24, 34, 35, 41–45, 48–51, 53, 54 | Small, batchable |
| R10 | **Execute the prior audit's R14 sweep** — most of the open baseline (MIN-3/4/5/6/7/8/9/13, OBS-8/9) is one prescheduled batch that this audit re-confirms is still pending | baseline table | Small–Medium |

**Suggested order:** R1 → R9 → R2 → R3 (a few days of low-risk truth and hygiene that de-noise everything after) → R7 + R6 (the suite becomes cheap to change right before the code changes) → R4 → R5 (the extractions, now landing on tests that can absorb them) → R8 → R10 alongside any of it. Per the audit method: findings → owner approval → fixes test-first at root cause, one branch each; the whole gate green before merge.

---

## Coverage

Ten deep-read auditors, each responsible for reading its full territory; every `lib/` and `test/` file in the package was some agent's responsibility:

| Territory | Files/Lines | Agent read in full |
|---|---|---|
| `lib/src/sync/application/` | 5 files, 3,000 | ✅ |
| `lib/src/sync/domain/` + `infrastructure/` + barrel | 25 files, 2,637 | ✅ |
| `lib/src/membership/` | 14 files, 2,320 | ✅ |
| `lib/src/shared/` + `lib/gossip.dart` | 28 files, 2,762 | ✅ |
| `lib/src/coordinator/` | 9 files, 1,912 | ✅ |
| `test/sync/application/` | 33 files, 8,507 | ✅ |
| `test/sync/domain/` + `infrastructure/` | 20 files, 2,996 | ✅ |
| `test/membership/` + `test/architecture/` | 23 files, 5,038 | ✅ |
| `test/coordinator/` + `test/support/` + root tests | 22 files, 4,652 | ✅ |
| `test/integration/` + `test/shared/` | 40 files, 7,304 | ✅ |

Orchestrator ran the gates (`dart test`: 1033/1033 green; `dart analyze`: clean) and personally re-verified every finding's citation against source, including all cross-file duplication claims at both ends. Not covered: `example/` (out of scope, not audited), `docs/` prose, and the transport packages. No other gaps.

---

## Remediation — Batch A (2026-08-23)

Commits `11b2558..5e5cc15` on branch `cc5-batch-a`. Ten tasks (A1–A10), each independently reviewed against this report; two fix rounds total across the batch (A4: one finding — a missed VV-mis-homing site in `channel_repository.dart`'s intro; A6: four items — see correction below).

**Closed in full:** CC5-4 (with correction — see below), CC5-15, CC5-16, CC5-17, CC5-36, CC5-37, CC5-38, CC5-39, CC5-40, CC5-44, CC5-54, and baseline MIN-22's coordinator/kernel doc items.

**Closed as a docs-only slice** (API surface unchanged; removal decisions deferred to Batch H): CC5-18.

**Closed as a Batch-A slice** (remainder owned by Batch D): CC5-34 (`TestNetwork` non-creating reads — done), CC5-35 (`gossip_experiment_test.dart` deleted; scenario consolidation across the remaining owning files remains), CC5-53 (`TestNetwork`'s `_originalPorts`/seeding items — done; other test-hygiene smalls in the finding remain), CC5-42 (closed except the clamping-style unification clause — three clamp styles — which travels with CC5-43 to Batch E).

**Correction to this report's own text**, discovered during remediation (Task A6): CC5-4's fix direction, as written above, says the reworded docs should read "edits replicated local metadata" — that phrasing is itself wrong. Channel membership metadata is **local** and never crosses the wire (ADR-007; no member data appears in any codec). The shipped docs instead say "local channel metadata." Treat the fix-direction wording above as superseded by this correction, not as what was implemented.

**Also landed:**
- `comment_references` lint now enforced package-wide (was D6).
- `InMemoryTimePort.tick()` is now formally `@Deprecated` (previously "legacy" only in prose — CC5-37).
- Suite count changed 1033 → 1031: `gossip_experiment_test.dart` (CC5-35) deleted as a strict subset of `coordinator_test.dart`, dropping its two duplicate test cases.

Gates: `melos run test` (gossip 1031, gossip_nearby 189, gossip_bluey 228 — all green) and `melos run analyze` (clean, all three packages) both pass as of `5e5cc15`; `dart format --output=none --set-exit-if-changed lib test` in `packages/gossip` exits 0.

---

## Remediation — Batch B (2026-08-23)

Commits `65ed649..5cc249b` on branch `cc5-batch-b`. Eleven tasks (B3–B5 batched), two fix rounds (B8: vacuous pin de-vacuized with red-against-mutant evidence; B10: staleness-gated push-epoch bump restoring pre-refactor semantics).

**CC5-6 closed:** five hand-rolled keyed-chain sites → one `KeyedTaskChain` (`shared/domain/services`), 8 unit tests incl. a self-deadlock regression pin.

**CC5-7 closed:** three generation-token loops → one `GenerationScheduler` (7 unit tests); BD2 failure policy unified (tick errors continue, scheduling errors stop the loop); the compaction loop's stopped state is now queryable and pinned; BD3 (whether compaction should retry after a scheduling failure) routed to Batch C. Note: `GossipEngine` retains a small `_pushGeneration` epoch for the reactive-push debounce guard (non-loop use), staleness-gated to match pre-refactor semantics; the stale-late-scheduling-failure interleaving remains without direct test coverage (needs a late-failure time-port double — candidate for Batch D).

**CC5-8 closed:** one `_commit` (save → mutate → emit) across all three fold paths; `MaterializerState.emit` notify-only; 3 new failure-path tests deliver the previously documented-but-unhonored guarantee (behavior change: a failed save now leaves state unpublished; a failed save marks the materializer for re-initialization from the last committed snapshot (fixed at final review after the initial retry premise proved false for the incremental/rebuild paths — a fourth failure-path test pins new-batch recovery)).

**Suite count:** 1031 → 1051 (+8 chain, +7 scheduler, +4 commit-protocol incl. the final-review new-batch recovery pin, +1 BD2 pin).

Gates: `melos run test` (gossip 1050, gossip_nearby 189, gossip_bluey 228 — all green) and `melos run analyze` (clean, all three packages); `dart format --output=none --set-exit-if-changed lib test` in `packages/gossip` exits 0.

---

## Remediation — Batch C (2026-08-24)

Commits `6c412f3..dd16e29` on branch `cc5-batch-c`. Eight tasks (C1–C8; C1+C2, C3+C4, C6+C7 batched for review), zero fix rounds (two watchdog stalls resumed mid-task; no review finding entered a fix-round loop).

**CC5-9 closed:** both message loops (`GossipEngine`, `FailureDetector`) split decode failures (`messageCorrupted`, `'Malformed…'`) from handling failures (`protocolError`, naming the message type and sender); both catches now thread stack traces. Red tests exercised real downstream seams — a throwing `onEntriesMerged` callback and a throwing `PeerRegistry.onEvent` sink — not mocks of engine/detector internals.

**CC5-19 closed per D1:** a null peer repository is now a documented supported mode (in-memory-only); the per-operation `StorageSyncError` spam on add/remove is deleted. One existing pin was converted to a silence pin (old/new assertions listed in the task report).

**CC5-23 closed per D2:** both local-node guards (`ChannelAggregate.removeMember`, `PeerRegistry.addPeer`) now throw `DomainException` with unchanged messages; `DomainException`'s stale scenario list trimmed to the two it actually throws; the two matchers that only asserted `isA<Exception>()` were strengthened with `.having` refinements.

**CC5-52 closed per CD2, save three sites:** stack traces are now threaded at both message loops (`GossipEngine._handleIncomingMessage`, `FailureDetector._handleIncomingMessage`) and the engine/detector inventory sites (`syncWithPeer`, `_sendMessage`, `_safeSend`, and siblings); `Coordinator` stores `onLog` and routes post-dispose errors to it at `LogLevel.error` instead of dropping them; the `onLog` doc clause Batch A trimmed pending this fix is restored, now true. Three sites still drop the trace at HEAD: `channel_service.dart:678` deliberately — `ChannelService` has no log sink and CD2 forbids putting traces in `SyncError`, so the emitted `StorageSyncError` carries `cause` only, not the trace; `coordinator.dart:482` (`_handleEntriesMerged`) and `:698` (`probeNewPeer`) emit with `cause` but drop the trace despite the coordinator now having `_onLog` — candidates for the next sweep.

**BD3 closed as CD1:** compaction scheduling failures stop the loop deliberately rather than retrying — documented on `CoordinatorConfig.compactionInterval`; behavior already pinned by the Batch B test.

**Also landed:** the reactive-push wedge (a live scheduling failure permanently blocking `notifyLocalWrite`'s debounce) fixed and pinned, with `ScriptedDelayTimePort` added to `test/support` as a down payment on Batch D's late-failure double; the OOO-on-uninitialized-materializer residual fixed and pinned — now routes to a full rebuild.

**Suite count:** 1051 → 1059 (+4 catch-split, +1 null-repo silence, +1 onLog fallback, +1 wedge pin, +1 OOO pin).

Gates: `melos run test` (gossip 1059, gossip_nearby 189, gossip_bluey 228 — all green) and `melos run analyze` (clean, all three packages); `dart format --output=none --set-exit-if-changed lib test` in `packages/gossip` exits 0.

---

## Remediation — Batch D (2026-08-24)

Commits `10db7b5..d9d0c7e` on branch `cc5-batch-d`. Ten tasks (D2 split into a/b, D3 into a/b, D4 into a/b; D1 needed a mid-batch amendment). One fix round (D4b). Three watchdog stalls resumed with no lost work: D7, and — earlier in the campaign — Batch C's C3 and C5; all three resumed from staged/working-tree state with no commits lost.

**CC5-5 closed:** one `createTestCoordinator` builder in `test/support` replaces 116 of 120 hand-rolled setups; four sites stay direct, each commented with what it proves that the builder cannot (two null-repository validation tests, one omitted-default test, one `MessagePort` that must emit stream errors). The builder needed a mid-batch amendment — an escape hatch fired when 17 sites turned out to need repository references the original signature could not express.

**CC5-25 closed:** counted `Future.delayed(Duration.zero)` loops replaced by `pumpEventQueue()` (drain) or a new bounded `pumpUntil` (wait). Both harnesses' `flush([count])` helpers deliberately left as fixed counts — they back dozens of call sites each awaiting a different downstream effect, so no single predicate fits; documented at each.

**CC5-26 closed:** integration cleanup registered at network creation (78 sites) so it survives a thrown assertion; five files plus three groups correctly left on their existing setUp/tearDown convention.

**CC5-27 closed:** five over-promising test names either strengthened or renamed. One needed a fix round — a config-passthrough test seeded the same value as the consumer's own default, so it stayed green when the wiring was deleted.

**CC5-28 closed:** three `expect(true, isTrue)` tautologies made real or deleted; the enum checklist became one exact-set assertion; two constructor-echo clones deleted (codec round-trips assert a strict superset).

**CC5-29 closed:** the composite-retention fixture gained an entry retained by exactly one sub-policy, so union and intersection now give different answers.

**CC5-30 closed for the envelope, not the nested payload:** encode-side type bytes and exact JSON key sets pinned for all four sync and three membership message types, using integer literals deliberately (a constant reference would drift with the change it must catch). All seven golden pins construct their messages with empty `digests`/`entries` collections, so only the envelope keys are pinned — the nested payload keys (`LogEntry`'s fields, `ChannelDigest`'s/`StreamDigest`'s fields) remain co-drift-blind; closing that gap is a named follow-up.

**CC5-31/32/33 closed:** the dead harness injection parameter replaced by a decorator seam on the harness's own port; ping waits now fail fast with a diagnostic instead of hanging; two unseeded branching tests seeded and their dead branches removed; two degenerate fakes replaced by the real in-memory repositories.

**Routed items closed:** `PeerService`'s dead `onError` removed (three other classes' `onError` untouched); the detector's two failure sites promoted from debug to error to match the engine; three false "Throws [Exception]" doc claims corrected; the compaction post-restart pin now asserts the loop is live; and the stale-generation late-scheduling-failure interleaving Batch B could not net is now pinned, using the `ScriptedDelayTimePort` added in Batch C.

**Method note:** every deletion carried a vacuity proof and every strengthened assertion a mutation proof; reviews reproduced those proofs independently rather than accepting them.

**Suite count:** 1059 → 1076.

Gates: `melos run test` (gossip 1076, gossip_nearby 189, gossip_bluey 228 — all green) and `melos run analyze` (clean, all three packages) both pass as of `d9d0c7e`; `dart format --output=none --set-exit-if-changed lib test` in `packages/gossip` exits 0.

---

## Remediation — Batch D follow-up (2026-08-26)

Commits `af60301..056c739` + this commit, branch `cc5-batch-d-followup`. Six tasks: five had zero fix rounds; Task 1 took one docs-only fix round (its builder-doc caller-grounding claim was corrected). Zero `lib/` files changed in any committed diff.

Items closed, from Batch D's outcome record (`docs/superpowers/plans/2026-08-24-cc5-batch-d.md`, §Batch D — outcome record):
- **M1 → CC5-30 now fully closed:** non-empty golden fixtures extend the envelope pins to the nested payload keys the empty-collection goldens couldn't reach — `LogEntry`'s `author`/`sequence`/`timestamp{physicalMs,logical}`/base64 `payload`, `ChannelDigest`'s `{channelId,streams}`, `StreamDigest`'s `{streamId,version}`, `DeltaRequest.since`/`DeltaResponse.floor` version-vector maps.
- **M2:** the builder rejects `nodeId` alongside `localNodeRepository` via `ArgumentError` + message — chosen over the outcome record's assert suggestion for unconditional (release-mode) enforcement.
- **M3:** six vacuous pins deleted with the static vacuity argument per site; two strengthened to typed pins (`PeerSyncError`/`protocolError`; `StorageSyncError`/`storageFailure` + message).
- **M5:** cleanup registered at construction at both named sites, plus trailing `sub.cancel()`s in the tests touched along the way.
- **M7:** the storage-usage pin is now the literal `112`, independent of `LogEntry.sizeBytes`'s formula.
- **M8:** the fourth hand-rolled detector setup now states why it stays hand-rolled — the harness builds its own `PeerRegistry` and exposes no `onEvent` seam.

**Suite count:** 1076 → 1081 (+1 builder-guard test, +4 nested-payload goldens; M3/M5/M7 left the count level). No tests deleted.

**Mutation proofs run:** `protocolError`→`messageCorrupted` at the engine's stream-error emission; a message-string swap at the HLC-persist emission; `52`→`60` in `LogEntry.sizeBytes`; `'author'`→`'a'` on both codec sides — for the last two, the *old* assertions (the formula mirror; the round-trip tests) were verified to stay green under the mutant, exactly the co-drift/mirror defect class these closures remove. Reviews reproduced proofs independently (the wire-golden reviewer re-ran the codec mutant; the M3 reviewer re-verified vacuity per site).

Gates: `melos run test` (gossip 1081, gossip_nearby 189, gossip_bluey 228 — all green) and `melos run analyze` (clean, all three packages); `dart format --output=none --set-exit-if-changed lib test` in `packages/gossip` exits 0.

---

## Remediation — Batch E (2026-08-26)

Commits `2102810..762924d` + this commit, branch `cc5-batch-e`. Seven tasks (E1–E7), one fix round (E3: a while→if mutant survived the cursor-skip test; retargeted, no count change).

**Closed:** CC5-2 (jobs b and d extracted to `ProbeTargetSelector`/`ProbeTimingPolicy` in `membership/domain/services`; jobs c/e deliberately remain — they are the detector's own choreography; job a's scheduling mechanism was already Batch B's `GenerationScheduler`, so the audit's `ProbeScheduler` fix direction predates that extraction — a recorded deviation, not a gap), CC5-3 (five copy-pasted probe lifecycles → `_pingExchange` + `_probe`; the late-Ack grace invariant was proven pinned by exactly 2 pre-existing tests via an early-cleanup mutant, so the extraction carries zero test-file diffs), CC5-13 detector slice (the dead field-plus-flag `?? default` pairs deleted for single nullable `Duration?` fields; Batch F owns the engine's mirrored slice), CC5-14 (detector's `selectRandomPeer` renamed `nextProbeTarget`; the engine's dead `selectRandomPeer` deleted with its 2 keeping-alive tests — `PeerDirectory.selectRandomPartner`, its 1:1 delegate, has its own stronger direct-coverage suite), CC5-42 clamp clause + CC5-43 (one `clampDuration`; `RttTracker` publishes `minSample`/`maxSample` as the single source, replacing the detector's mirrored constants; the A-routed `_recordRtt` doc-block is reattached to the method it actually describes), CC5-46 (dead `sequence` param removed; `checkPeerHealth` → `updatePeerHealth`; `registerMaterializer` returns `Future<void>`; `Coordinator`'s constructor params privatized; `VersionVector.set`/`increment` and `RttTracker.reset` deleted as dead surface; `FoldCursor`'s assert now states both failure modes; `resetState` null-checks the materializer before the async `hasStream` read, for guard-order parity with `getState`), CC5-47 (`@visibleForTesting` on the six test-only-public detector members; `PeerMetrics` gets `@immutable` + `copyWith`).

**Deviation ledger:** E4's two accepted micro-deviations — one extra debug line in `_probeUnreachablePeer`'s rare late-direct-ack race (log-only, nothing reads log content); the timeout-sampling instant moved pre-send at `probeNewPeer`/`_handlePingReq` (a pure read, invisible under the suite's static timeouts).

**Note:** `VersionVector.set`/`increment` were exported public API (`lib/gossip.dart`) before this batch deleted them — semver-relevant; flagged to the owner, versioning policy pending.

**Routed to Batch H:** `PeerDirectory.selectRandomPartner` is now directly dead (zero production callers after the engine fossil's deletion) — dead-surface removal, not this batch's scope.

**Transport-error attribution pin (D-follow-up's open question):** `GossipEngine` and `FailureDetector` both listen on the same broadcast `MessagePort.incoming`, so one stream error deterministically reaches `coordinator.errors` twice (10/10 runs). But the two `PeerSyncError`s are byte-identical in every field but `occurredAt` — same peer, same type, same message text, even the same `cause` object by identity — so neither is attributable to its listener. The existing single-emission pin stays as-is; a comment at the test names the ambiguity instead of a count pin, which would be brittle against listener-set changes.

**Suite arithmetic:** 1081 → 1115 (E1 +5, E2 +13, E3 +18 — the fix round retargeted an existing test rather than adding one, E4 +0, E5 −7+5, E6 +0, E7 +0).

Gates: `melos run test` (gossip 1115, gossip_nearby 189, gossip_bluey 228 — all green) and `melos run analyze` (clean, all three packages); `dart format --output=none --set-exit-if-changed lib test` in `packages/gossip` exits 0.
