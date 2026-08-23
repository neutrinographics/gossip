# CC5 Clean-Code Remediation — Campaign Plan (Batch A detailed)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remediate all findings of the 2026-08-23 clean-code audit (CC5-1..63 plus the open baseline items), batch by batch, each batch on its own branch with the whole gate green before merge.

**Architecture:** The audit report is the spec; each finding carries a verified fix direction. Work is sequenced into 8 batches (A–H) ordered so that cheap truth/hygiene lands first, shared utilities land before the classes that need them, and the test suite is strengthened immediately before the two big extractions land on it. This document fully details **Batch A**; Batches B–H each get their own plan file written when their turn comes (they depend on decisions and code from earlier batches), arguing from the audit + the Decisions section below.

**Tech Stack:** Pure Dart (`packages/gossip`), `dart test` / `dart analyze` / `dart format`, melos monorepo gates.

**Spec:** `docs/audits/2026-08-23-clean-code-audit.md` (findings CC5-1..63, baseline table, recommendations R1–R10)

## Global Constraints

- **Docs say why, not how** (Joel's standing rule): every doc comment written or touched in this campaign must state intent, contract, invariants, or consequence of misuse — never restate implementation steps. Pure restatements get deleted, not reworded. Reference standard: `takeTimestamp`'s doc, `MessagePort`'s failure contract, `entry_repository.dart`'s Critical Invariants section.
- One branch per batch (`cc5-batch-a` … `cc5-batch-h`), merged only with `melos run test` + `melos run analyze` green and `dart format` clean for the package.
- Behavior-changing fixes are test-first (failing test pinning the finding, then the fix). Doc-only and format-only changes need no new tests but must keep all 1033 existing tests green.
- `test/architecture/boundary_test.dart` must stay green — no new cross-context imports.
- No new public API surface unless a finding's fix requires it; removals of exported surface happen only in Batch H (D4) after explicit sign-off.
- Commit style: `docs:`/`refactor:`/`test:`/`fix:` prefixes as used in recent history; one finding-cluster per commit, message names the CC5 IDs.

---

## Design decisions (approve/veto at plan review; recommendations pre-filled)

- **D1 — CC5-19 (null `PeerService.repository`):** Recommend: null is a **valid config**. Delete the per-operation `StorageSyncError` emissions in `_persistPeer`/`_deletePeer`; keep the field doc as-is. No log spam replacement — the doc already states the mode. (Alternative: make repository required; rejected because `Coordinator.create` deliberately defaults it.)
- **D2 — CC5-23 (typed exceptions for domain guards):** Recommend: throw the already-exported-but-dead **`DomainException`** from `ChannelAggregate.removeMember` and `PeerRegistry.addPeer` local-node guards (revives MIN-7's dead class for its stated purpose instead of adding surface). Facade docs change from "Throws [Exception]" to "Throws [DomainException]". Then strengthen the two weak test matchers. (Alternative: `StateError`; either is fine, pick one and use it for both.)
- **D3 — public renames:** `maxDeltaResponseBytes` → `maxMessageBytes` is internal (engine not exported) — hard rename. `Coordinator.create(timerPort:)` → `timePort:` **is** public API — recommend hard rename in one commit across lib+tests+examples (consumers are in-repo apps; no deprecation shim). Veto here if any out-of-repo consumer exists.
- **D4 — exported dead surface (Batch H scope):** deleting `PeerRepository.findReachable`/`exists`/`count`, `entriesForAuthorAfter`, `VersionVector.set`/`increment`, `RttTracker.reset`, phantom types (`StreamConfig`, `ChannelDelta`, `MergeResult`, dead events) is a breaking sweep = the prior audit's R14. Recommend doing it as Batch H with its own plan; Batch A only fixes their *docs*.
- **D5 — CC5-35 test consolidation:** recommend deleting the weaker duplicates outright (`gossip_experiment_test.dart`, the `message_handling_test.dart` "Message loss and recovery" group, the 1KB large-payload duplicate, the `effectiveGossipInterval` group's overlap) rather than merging content. Coverage owners: partition/churn/scale/interval_pacing files.
- **D6 — doc-example verification:** recommend fixing the three non-compiling examples by hand now and adding the `comment_references` lint to `analysis_options.yaml` (catches dangling `[Type]` refs at analyze time). No snippet-compilation infra (YAGNI). `unawaited_futures` lint deferred to Batch D where its fallout is fixed.

## Batch map

| Batch | Branch | Recommendations | Findings | Plan |
|---|---|---|---|---|
| A | `cc5-batch-a` | R1 + R9 | CC5-4, 15, 16, 17, 18(docs), 36–45, 48–51(docs), 54; baseline MIN-22 | **this document** |
| B | `cc5-batch-b` | R2 | CC5-6, 7, 8 | written at batch start |
| C | `cc5-batch-c` | R3 | CC5-9, 19, 23, 52 (D1, D2) | written at batch start |
| D | `cc5-batch-d` | R7 + R6 | CC5-5, 25–33 | written at batch start |
| E | `cc5-batch-e` | R4 | CC5-2, 3, 14, 46, 47 | written at batch start |
| F | `cc5-batch-f` | R5 | CC5-1, 10, 11, 12, 13 (D3) | written at batch start |
| G | `cc5-batch-g` | R8 | CC5-20, 21, 22 | written at batch start |
| H | `cc5-batch-h` | R10 (= old R14) | baseline MIN-3..9/13, OBS-8/9, D4 removals | written at batch start |

Order: A → B → C → D → E → F → G → H. C and D are swappable; E/F must follow B (they consume its utilities) and ideally D (stronger suite).

---

# Batch A — doc truth, why-lens, and mechanical hygiene

All paths relative to `packages/gossip/`. No behavior changes except Task 8's mechanical refactors (covered by existing tests) and Task 9's test-support fixes.

### Task A1: Branch + format baseline

**Files:** all (formatter); `test/sync/application/gossip_engine_scheduling_test.dart:150-154`, `test/membership/application/failure_detector_scheduling_test.dart:62-66`

- [ ] **Step 1:** `git checkout -b cc5-batch-a`
- [ ] **Step 2:** `cd packages/gossip && dart format lib test`
- [ ] **Step 3:** Inspect the two previously-mangled blocks; the formatter fixes indentation but not the duplicated comment. In each file, keep the comment on its first occurrence in the file only (`gossip_engine_scheduling_test.dart` also has it at :120-121); delete the in-loop duplicate.
- [ ] **Step 4:** `dart test && dart analyze` — expect 1033 pass, 0 issues.
- [ ] **Step 5:** `git commit -am "style: format package; dedupe pasted scheduling-test comments (CC5-54)"`

### Task A2: Membership docs stop promising access control (CC5-4)

**Files:** Modify: `lib/src/coordinator/channel.dart:84-108`

- [ ] **Step 1:** Replace the three method docs. Exact new text:

```dart
  /// Returns the set of member node IDs in this channel.
  ///
  /// Membership is replicated local metadata (see ADR-007): it names who
  /// the app considers part of the channel, but the protocol does not
  /// gate synchronization on it. Enforcement is an application concern.
  Future<Set<NodeId>> get members async { ... }

  /// Adds a member to the channel's replicated metadata.
  ///
  /// This records intent for the app's own UI/logic; it grants nothing at
  /// the protocol level (see ADR-007).
  Future<void> addMember(NodeId memberId) async { ... }

  /// Removes a member from the channel's replicated metadata.
  ///
  /// This does NOT stop the peer from replicating the channel: any node
  /// still holding the channel keeps receiving and serving its entries
  /// (see ADR-007). Do not use this as access revocation — key rotation
  /// or app-level encryption is the tool for that.
  Future<void> removeMember(NodeId memberId) async { ... }
```

(`{ ... }` = existing bodies unchanged.)
- [ ] **Step 2:** `dart analyze && dart test test/coordinator/` — green.
- [ ] **Step 3:** `git commit -am "docs: membership facade docs state ADR-007 reality, not access control (CC5-4)"`

### Task A3: Fix the non-compiling public examples (CC5-17, D6)

**Files:** Modify: `lib/src/shared/domain/interfaces/message_port.dart:79-82`, `lib/src/sync/domain/interfaces/state_materializer.dart:25-27`, `lib/src/shared/infrastructure/real_time_port.dart:23-27`, `lib/src/shared/domain/value_objects/rtt_estimate.dart:37`, `lib/gossip.dart` (quick start), `analysis_options.yaml`

- [ ] **Step 1:** `message_port.dart` example `send` gains the interface's named parameter:

```dart
///   @override
///   Future<void> send(
///     NodeId destination,
///     Uint8List bytes, {
///     MessagePriority priority = MessagePriority.normal,
///   }) async {
///     await _adapter.sendToDevice(destination.value, bytes);
///   }
```

- [ ] **Step 2:** `state_materializer.dart` first example: `class CounterMaterializer implements StateMaterializer<int>` → `extends StateMaterializer<int>` (the concrete `save` default is only inherited via `extends` — state that in one doc sentence so the next editor doesn't "fix" it back).
- [ ] **Step 3:** `real_time_port.dart` example: `localNode: nodeId` → `localNodeRepository: InMemoryLocalNodeRepository(nodeId: nodeId)` (match the `gossip.dart` quick start).
- [ ] **Step 4:** `rtt_estimate.dart:37`: `estimate.suggestedTimeout;` → `estimate.suggestedTimeout()`.
- [ ] **Step 5:** `gossip.dart` quick start: add `import 'dart:convert';` and `import 'dart:typed_data';` lines to the example block.
- [ ] **Step 6:** `analysis_options.yaml`: add

```yaml
linter:
  rules:
    - comment_references
```

- [ ] **Step 7:** `dart analyze` — fix every dangling `[Ref]` it now reports by importing-for-doc or de-bracketing to plain text (expected sites per CC5-51/CC5-39/SH-F20: `sync_error.dart`, `domain_event.dart`, `time_source.dart`, `local_node_repository.dart`, `message_port.dart`, `channel_service.dart:327` `[Channel]`). Boundary rule: where the import is forbidden, de-bracket.
- [ ] **Step 8:** `dart test` green; `git commit -am "docs: compileable public examples; enable comment_references (CC5-17, CC5-39)"`

### Task A4: Port contracts stop misdirecting implementers (CC5-15, CC5-16, CC5-18 docs)

**Files:** Modify: `lib/src/sync/domain/interfaces/entry_repository.dart:13-14,116-118,131`, `lib/src/sync/domain/interfaces/channel_repository.dart:11-15`, `lib/src/membership/infrastructure/in_memory_peer_repository.dart:8-14`, `lib/src/membership/domain/interfaces/peer_repository.dart:49-59`

- [ ] **Step 1:** `entry_repository.dart` — `getAll` and `entriesSince` method docs each state the full order: "Returns entries in the full [LogEntry.compareTo] total order — timestamp, then author, then sequence. Timestamp alone is not sufficient: HLC ties ordered by arrival diverge across peers (see Ordering Guarantees above)." Fix the `:13-14` intro: the aggregate holds membership and stream metadata; version vectors are this repository's responsibility.
- [ ] **Step 2:** `channel_repository.dart:11-15` bullet list → "Channel ID · Member node IDs · Stream IDs and retention policies". Add: "Version vectors are NOT stored here — they are [EntryRepository]'s responsibility; persisting sync state in this store is the corruption path its invariants section forbids."
- [ ] **Step 3:** `in_memory_peer_repository.dart` — delete "Use only for testing and prototyping" and the SQLite/status-query guidance; new doc: this is the default and recommended repository (peers re-add on reconnection; status is never persisted by contract); a persistent implementation is only for app-level peer-history features.
- [ ] **Step 4:** `peer_repository.dart:49-59` — remove the false "Used when selecting peers for gossip rounds" (gossip selects from `PeerRegistry`); annotate `findReachable`/`findAll`/`exists`/`count` docs with: "Not called by the library; retained for app-side queries pending the Batch H surface review (D4)." Note the status-never-persisted consequence on `findReachable`.
- [ ] **Step 5:** `dart analyze && dart test` green; `git commit -am "docs: repository contracts match reality — ordering, VV home, default repo (CC5-15/16/18)"`

### Task A5: Coordinator + kernel doc drift (CC5-36, CC5-37, baseline MIN-22)

**Files:** Modify: `lib/src/coordinator/coordinator.dart:191-218,893-897,914-917`, `lib/src/coordinator/sync_state.dart:3-4`, `lib/src/shared/domain/value_objects/log_entry.dart:70-79`, `lib/src/shared/domain/value_objects/rtt_estimate.dart:135-136`, `lib/src/shared/domain/services/rtt_tracker.dart:51-52`, `lib/src/shared/domain/services/time_source.dart:5-8`, `lib/src/shared/infrastructure/in_memory_time_port.dart:44`, `lib/src/shared/domain/services/quiescence_pacer.dart:11-12`, `lib/src/coordinator/coordinator_config.dart` (prose-vs-fields pass per MIN-22)

Per-site (each also gets the why-lens: no step restatements survive the edit):
- [ ] **Step 1:** `start()` doc: delete both "(once integrated)"; `events` getter: replace the 4-item list with "Carries every [SyncEvent] and [MembershipEvent]; see those sealed families for the full set" ; `create` doc: add one line each for `random` ("inject a seeded Random for deterministic tests") and `onLog` ("receives diagnostic logs; also the fallback error sink after dispose" — forward-compatible with Batch C's CC5-52 fix).
- [ ] **Step 2:** `sync_state.dart`: `stopped` → "Not running: the initial state, and the state after stop()."
- [ ] **Step 3:** `log_entry.dart` `sizeBytes`: delete the fictional binary layout; new doc: "Storage-quota heuristic (52-byte fixed overhead + payload length). NOT the wire size — the codec computes exact encoded sizes; see [SyncMessageCodec.encodedEntrySize]." (de-bracket if comment_references complains across the boundary).
- [ ] **Step 4:** `rtt_estimate.dart:136`: "Defaults: min=200ms" → reference the constants: "Defaults: [_defaultMinTimeout] (500 ms) / [_defaultMaxTimeout] (10 s)" — or drop the numbers entirely so they can't drift again.
- [ ] **Step 5:** `rtt_tracker.dart:51-52`: replace restated numbers with "see [RttEstimate.initial] for the cold-start defaults".
- [ ] **Step 6:** `time_source.dart:5-8`: drop the anti-corruption-layer claim; "A read-only clock view over [TimePort] for consumers that must not schedule."
- [ ] **Step 7:** `in_memory_time_port.dart`: annotate `tick()` `@Deprecated('Use advance(); tick() only fires periodic callbacks')` and update the usage example (removes the "legacy" prose).
- [ ] **Step 8:** `quiescence_pacer.dart:11-12`: "(spec: 30 s, not configurable)" → "callers pass their scheduling ceiling; the library pins 30 s and exposes no knob".
- [ ] **Step 9:** `coordinator_config.dart`: read the class prose against its own fields; fix any remaining contradiction (MIN-22's residual).
- [ ] **Step 10:** `dart analyze && dart test` green (the `@Deprecated` may warn in tests that use `tick()` — update those call sites to `advance` where equivalent, else `// ignore: deprecated_member_use_from_same_package` with reason). `git commit -am "docs: coordinator+kernel drift sweep (CC5-36/37, MIN-22)"`

### Task A6: Membership + sync doc drift (CC5-38, CC5-39)

**Files:** Modify: `lib/src/membership/domain/value_objects/peer_status.dart:1-7`, `lib/src/membership/domain/events/membership_events.dart:58-63`, `lib/src/membership/application/peer_service.dart:69,86`, `lib/src/membership/domain/entities/peer.dart:20`, `lib/src/membership/domain/entities/peer_metrics.dart:18`, `lib/src/sync/domain/events/sync_events.dart:87,104,130-149,73`, `lib/src/sync/application/channel_service.dart:24,63,138,211,232,253,327`, `lib/src/sync/application/gossip_engine.dart:646,873-874,1566-1578` (+ the other two interval-policy doc copies)

- [ ] **Step 1:** `peer_status.dart`: describe this implementation — "suspected: ≥ failureThreshold consecutive failed probe rounds; unreachable: ≥ unreachableThreshold. Thresholds and transitions live in [FailureDetector]" (de-bracket per boundary).
- [ ] **Step 2:** `membership_events.dart` `PeerOperationSkipped`: "Fired only by [PeerRegistry.updatePeerStatus] on a missing peer. Other mutators deliberately no-op silently — one event per message from an unknown peer would grow without bound."
- [ ] **Step 3:** `peer_service.dart:69,86`: delete "Transaction: …" lines; replace with "Registry is the source of truth; persistence is best-effort and serialized per peer (see [_saveQueue])."
- [ ] **Step 4:** `peer.dart:20` → "Compared by full value equality."; `peer_metrics.dart:18` → "Value object with immutable value semantics." (class doc first line updated to say value object, not entity).
- [ ] **Step 5:** `sync_events.dart`: `EntryAppended`/`EntriesMerged` "Fired when:" name the real emitters (`ChannelService.appendEntry` / the coordinator's merge fan-out); `StreamCompacted`/`BufferOverflowOccurred` docs get an honest line: "Currently never emitted — wiring pending Batch H (MIN-4/MIN-7)"; `:73` `[Channel.addStream]` → `createStream`.
- [ ] **Step 6:** `channel_service.dart`: fix the five "[ChannelAggregate] aggregate" doublings; while in each doc, apply the why-lens — e.g. `:211` "Loads the [ChannelAggregate] aggregate, adds the member, and persists the change." → "Records the member in replicated channel metadata (see ADR-007 — no protocol gating) and emits [MemberAdded]." Same treatment for `:232` (remove) and `:253` (createStream: what the caller gets and when events fire, not the load/save steps).
- [ ] **Step 7:** `gossip_engine.dart`: `:646` becomes a one-liner "Performs a single gossip round (see [effectiveGossipInterval] for cadence)."; the interval policy prose lives ONCE on `effectiveGossipInterval`, the other two doc copies reference it; `:873-874` "silently ignored" → "dropped non-fatally and reported via [ErrorCallback] (DoS containment)"; `:1566-1578` rewritten as one doc with a single summary and the continuation-return contract (the stale "clears the pending request flag" sentence deleted).
- [ ] **Step 8:** `dart analyze && dart test` green; `git commit -am "docs: membership+sync drift sweep, why-lens on channel_service (CC5-38/39)"`

### Task A7: Unresolvable shorthand references (CC5-40)

**Files:** Modify: `lib/src/membership/application/failure_detector.dart:161-162` (+4 sibling sites), `lib/src/shared/domain/interfaces/message_codec.dart:2-4`, `lib/src/shared/domain/value_objects/wire_types.dart:1`, `lib/src/sync/domain/interfaces/peer_directory.dart:18-19`, `lib/src/sync/application/gossip_engine.dart` (class doc), `test/membership/application/failure_detector_pacing_test.dart:31-33`, `test/architecture/boundary_test.dart:4,35`

- [ ] **Step 1:** Add one line to `GossipEngine`'s and `FailureDetector`'s class docs: "Comment keys like COR3-n / WIRE4-n / H-n refer to findings in `docs/audits/`." Keep the existing keyed comments (they're a strength once resolvable).
- [ ] **Step 2:** Replace pure-shorthand justifications with their essence: `failure_detector.dart:161-162` "(final review, item 2)" → the actual rule ("hard cap = 4× the 30 s ceiling, so freshness alone can never suppress a probe for more than 2 minutes"); `message_codec.dart:2` delete the `// path updated in Task 5's move` import comment; "Part 2 spec" (both files) → the actual invariant already stated nearby; `peer_directory.dart:18-19` WIRE4-19 pointer → "Designed to be extended with piggybacked liveness data; keep the pass-through purity when extending."
- [ ] **Step 3:** `failure_detector_pacing_test.dart:31-33`: inline the one-sentence empirical result; drop the `task-6-report.md` pointer (gitignored, resolves nowhere else). `boundary_test.dart:4,35`: drop "fluent's CA2-3 pattern" / "Task 5's normalization" phrasing, keep the substantive sentences.
- [ ] **Step 4:** `dart analyze && dart test` green; `git commit -am "docs: make review-shorthand comments self-standing (CC5-40)"`

### Task A8: Mechanical hygiene — constants and one duplication (CC5-42, CC5-44)

**Files:** Modify: `lib/src/sync/application/gossip_engine.dart:264-267,807-810,1529-1533`, `lib/src/membership/application/failure_detector.dart:779`, `lib/src/sync/domain/services/hlc_clock.dart:72-75,123-126`, `lib/src/sync/application/channel_service.dart:408-418`

All behavior-preserving; existing tests are the safety net (timestamp path: `test/sync/application/channel_service_timestamp_test.dart`).
- [ ] **Step 1:** `gossip_engine.dart`: `static const int _channelEnvelopeOverheadBytes = 40;` (doc: what it covers and that the codec owns the real format) replacing the bare `40`; move the `+1` comment onto the `final cost = … + 1;` line; `_metricsWindowDurationMs` → `static const Duration _metricsWindow = Duration(seconds: 10);` (convert the two read sites; delete the value-restating comment).
- [ ] **Step 2:** `failure_detector.dart:779`: `static const int _indirectProbeFanout = 3;` in the Constants section (doc: SWIM's k); call site uses it.
- [ ] **Step 3:** `hlc_clock.dart`: `static const int _maxLogicalCounter = 0xFFFF;` + a private `_rolloverIfNeeded()` used by both `now()` and `receive()`.
- [ ] **Step 4:** `channel_service.dart` `_appendEntryNow`: replace the inlined timestamp+persist block with `final timestamp = await takeTimestamp();`.
- [ ] **Step 5:** `dart test && dart analyze` — full package green (1033 pass).
- [ ] **Step 6:** `git commit -am "refactor: named constants, HLC rollover helper, reuse takeTimestamp (CC5-42/44)"`

### Task A9: Test-support hygiene (CC5-34, CC5-53 TestNetwork items, CC5-35 experiment file)

**Files:** Modify: `test/support/test_network.dart:60,90-91,260-264,664-685`; Delete: `test/gossip_experiment_test.dart`

- [ ] **Step 1 (test-first for the accessor fix):** in a scratch run, change `entryCount`/`entries` to a non-creating read: `final stream = channel.getStream(streamId); if (stream == null) return 0; /* resp. const [] */` — the `Channel` facade's `getStream` returns null for missing streams (pinned by `test/coordinator/channel_test.dart:97-104`). Run the full integration suite; if any test relied on accessor-side stream creation it fails now and gets an explicit `createStream`/`write` in its arrange (that reliance is exactly the hazard CC5-34 names).
- [ ] **Step 2:** delete `_originalPorts` (`:60`); `heal()` reads `_nodes[name]!.messagePort.reregister()`.
- [ ] **Step 3:** `create()`: iterate with an index instead of `indexOf`; first line throws `ArgumentError('duplicate node names: …')` when `nodeNames.toSet().length != nodeNames.length`.
- [ ] **Step 4:** `git rm test/gossip_experiment_test.dart` (both tests are strict subsets of `coordinator_test.dart:28-51`; D5).
- [ ] **Step 5:** `dart test` — full suite green (now 1031±).
- [ ] **Step 6:** `git commit -am "test: TestNetwork reads don't mutate observed nodes; drop experiment file (CC5-34/35/53)"`

### Task A10: Batch gate + audit addendum

- [ ] **Step 1:** `melos run test && melos run analyze` from repo root (all three packages — confirms no cross-package fallout).
- [ ] **Step 2:** `cd packages/gossip && dart format --output=none --set-exit-if-changed lib test` — exit 0.
- [ ] **Step 3:** Append a "Remediation — Batch A" addendum to `docs/audits/2026-08-23-clean-code-audit.md` listing the CC5 IDs closed, per the repo's audit convention.
- [ ] **Step 4:** Merge `cc5-batch-a` per the finishing-a-development-branch workflow.

---

## Self-review notes

- Spec coverage: Batch A closes CC5-4, 15, 16, 17, 18(docs), 36, 37, 38, 39, 40, 42, 44, 54, MIN-22, plus the TestNetwork/experiment slices of 34/35/53. Every remaining finding is mapped to a batch in the table above; none is unowned.
- CC5-41/43/45/46/47/48/49/50/51 are deliberately **not** in Batch A: they are rename/API/behavior changes that belong with their subsystem batches (E for detector naming/annotations, F for engine naming, C for jitter validation + error paths, D for test-side items, H for surface removal) — putting them here would make the "safe docs+hygiene" branch carry behavior risk.
- Type consistency: names introduced here (`_channelEnvelopeOverheadBytes`, `_metricsWindow`, `_indirectProbeFanout`, `_maxLogicalCounter`) are private and referenced only within their own tasks.
