# CC5 Batch D Follow-up — Test-Foundation Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the six test-side items Batch D's outcome record routed forward (M1, M2, M3, M5, M7, M8) so Batch E's detector extraction lands on a suite with no known vacuous pins, no formula-mirroring assertions, enforced builder semantics, and wire goldens that cover nested payloads.

**Architecture:** Test-only batch — every edit lives under `test/`; zero production files change. The suite is its own safety net: after every task the full suite stays green, and no assertion may be weakened — assertions are strengthened, or deleted with a vacuity proof in the task report.

**Tech Stack:** Pure Dart (`packages/gossip`), `dart test`/`dart analyze`/`dart format`, melos gates.

**Spec:** The "Batch D — outcome record" section of `docs/superpowers/plans/2026-08-24-cc5-batch-d.md` (items M1, M2, M3, M5, M7, M8). All file:line references were re-verified against the working tree on 2026-08-26.

## Global Constraints

- All commands run from `packages/gossip/`.
- Branch `cc5-batch-d-followup` from `working-connection`; merge only with repo-root `melos run test` + `melos run analyze` green and `dart format --output=none --set-exit-if-changed lib test` exit 0 in `packages/gossip`. Do NOT run `melos run format` (gossip_bluey formatter drift is a separate roadmap item).
- **Assertion discipline (Batch D's rule, still binding):** strengthening is free; deleting requires a vacuity proof in the task report; weakening is forbidden. Every strengthened assertion carries a mutation proof — temporarily break the pinned property in production or the codec, show RED, revert, show GREEN. Show actual command output for both sides.
- Docs/comments say why, not how. No plan shorthand (`M1`, `FD1`…) in shipped comments — audit IDs (`CC5-n`) are allowed, they resolve in `docs/audits/`.
- Suite count may only rise or stay level (this batch deletes no tests, only redundant assertion lines).
- Commit style: `test:` naming CC5 IDs where one applies; footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## Design decisions (pre-filled; binding unless Joel vetoes)

- **FD1 — builder enforcement throws `ArgumentError`, not `assert`.** Unconditional (independent of assert flags), carries a message naming both parameters, and matches the precedent of `TestNetwork.create`'s duplicate-name `ArgumentError` (Batch A, CC5-53). Deviation from the outcome record's `assert` suggestion is deliberate for those two reasons.
- **FD2 — vacuous-pin disposition rule.** A `pumpUntil(P); expect(P)` pair: **delete** the `expect` when a following, genuinely falsifiable assertion on the same subject exists or when the `expect` merely restates `P` (fold any `reason:` prose into the `pumpUntil` `describe:` so diagnostics keep the why); **strengthen** the `expect` into a claim `pumpUntil` does not already guarantee when it is the test's only assertion (two sites qualify: `coordinator_lifecycle_test.dart:277`, `metrics_observability_test.dart:117`).
- **FD3 — M8 gets a comment, not a harness seam.** Adding an `onEvent` pass-through to `FailureDetectorTestHarness` for one call site is API growth on a file Batch E will be reshaping anyway; the record only asked for the missing why-comment.
- **FD4 — the monitoring pin uses the documented heuristic as a literal.** `LogEntry.sizeBytes` is `52 + payload.length` (documented as a storage-quota heuristic, `log_entry.dart:74`); the test pins the literal total so it is independent of the production formula. If the heuristic ever changes deliberately, this test breaking is the desired signal.

## Batch map

| Task | Scope | Routed item |
|---|---|---|
| 1 | Builder `nodeId`/`localNodeRepository` mutual exclusion | M2 |
| 2 | Vacuous `pumpUntil(P); expect(P)` pairs — delete or strengthen, 8 sites | M3 |
| 3 | Cleanup that survives failed assertions | M5 |
| 4 | Monitoring storage pin decoupled from the production formula | M7 |
| 5 | Nested-payload wire goldens | M1 |
| 6 | M8 comment + gates + audit addendum | M8, bookkeeping |

Tasks 1–5 are mutually independent; 6 runs last.

---

### Task 1: Builder enforcement — `nodeId` and `localNodeRepository` are mutually exclusive (M2)

**Files:**
- Modify: `test/support/coordinator_builder.dart` (signature at ~line 67, doc at ~lines 39–43)
- Test: `test/support/test_support_test.dart`

**Interfaces — Produces:** `createTestCoordinator({String? nodeId, ...})` — `nodeId` becomes nullable, `null` means the previous default `'local'`. Throws `ArgumentError` when both `nodeId` and `localNodeRepository` are supplied. All other parameters unchanged.

Grounding (verified 2026-08-26): no existing call site passes both `nodeId:` and `localNodeRepository:` in one call, and none passes both `bus:` and `localNodeRepository:`, so the guard breaks nobody.

- [ ] **Step 1: Write the failing test** in `test/support/test_support_test.dart`, alongside the existing builder self-tests:

```dart
test('supplying both nodeId and localNodeRepository throws ArgumentError', () {
  // The builder ignores nodeId when a repository is supplied (repository
  // identity wins, mirroring Coordinator.create). A caller passing both
  // believes nodeId took effect — reject the call instead of silently
  // honoring only half of it.
  expect(
    () => createTestCoordinator(
      nodeId: 'alice',
      localNodeRepository: InMemoryLocalNodeRepository(nodeId: NodeId('bob')),
    ),
    throwsArgumentError,
  );
});
```

- [ ] **Step 2: Run it to verify it fails.** `dart test test/support/test_support_test.dart --name "mutually|throws ArgumentError"` → the new test FAILS (the current builder accepts both and returns a coordinator).
- [ ] **Step 3: Implement.** In `coordinator_builder.dart`: change `String nodeId = 'local'` to `String? nodeId`; first statement of the function body:

```dart
if (nodeId != null && localNodeRepository != null) {
  throw ArgumentError(
    'Pass either nodeId or localNodeRepository, not both: the builder '
    'ignores nodeId when a repository is supplied (the repository\'s own '
    'resolved identity wins, mirroring Coordinator.create).',
  );
}
final localNode = NodeId(nodeId ?? 'local');
```

Update the doc paragraph at ~lines 39–43: replace the "…[nodeId] is ignored and the repository's own resolved identity wins…" clause with the new contract (supplying both is an `ArgumentError`). Add one sentence naming the remaining sharp edge: when [localNodeRepository] is combined with [bus], the message port registers under `'local'` — a repository resolving to any other identity will never receive traffic; extend the builder before writing such a test. (No current caller combines them; enforcement there would be speculative.)

- [ ] **Step 4: Run to green.** `dart test test/support/` → all pass. Then `dart test` (full suite) → all pass, count unchanged except +1.
- [ ] **Step 5: Analyze, format, commit.**

```bash
dart analyze && dart format --output=none --set-exit-if-changed lib test
git add -A && git commit -m "test: builder rejects nodeId alongside localNodeRepository (CC5-5 follow-up)"
```

### Task 2: Vacuous visible assertions after `pumpUntil` (M3)

**Files:**
- Modify: `test/coordinator/coordinator_lifecycle_test.dart` (~201, ~277), `test/coordinator/coordinator_error_wiring_test.dart` (~31), `test/coordinator/coordinator_sync_activity_test.dart` (~65), `test/sync/application/metrics_observability_test.dart` (~117), `test/sync/application/gossip_engine_scheduling_test.dart` (~322, ~448), `test/sync/application/materialization/materialization_reentrancy_test.dart` (~136)

Each site does `await pumpUntil(() => P, describe: …); expect(P, …)`. The `expect` can never fail — if `P` is false, `pumpUntil` throws first with its own diagnostic; if true, the `expect` passes. That static argument is the vacuity proof for every deletion below; state it once in the task report and list the sites.

- [ ] **Step 1: Six deletions (FD2).** At each site, delete the redundant `expect` and fold its `reason:` prose into the `pumpUntil` `describe:` string (append as a parenthetical clause) so the failure message keeps the why:
  - `coordinator_lifecycle_test.dart:~201` — delete `expect(done, isTrue, reason: 'listeners must get onDone instead of leaking forever')`; describe becomes `'the materializer state stream calling onDone after dispose (listeners must not leak forever)'`.
  - `coordinator_error_wiring_test.dart:~31` — delete `expect(errors, isNotEmpty, …)`; the following `expect(errors.first, isA<ChannelSyncError>())` is the real pin and stays.
  - `coordinator_sync_activity_test.dart:~65` — delete `expect(coordinator.gossipSyncActivity.outstandingPulls, equals(1))`; the assertions after `removePeer` (pulls drop to 0, quiescent) are the real pins and stay.
  - `gossip_engine_scheduling_test.dart:~322 and ~448` — delete the `expect(received.whereType<DeltaResponse>().any(…), isTrue, reason: …)` that repeats the predicate; fold each `reason` into the respective `describe`.
  - `materialization_reentrancy_test.dart:~136` — delete `expect(done, isTrue, reason: 'the replaced state must be disposed (awaited, not dropped)')`; describe becomes `'the replaced state stream closing (the old state must be disposed — awaited, not dropped)'`.
- [ ] **Step 2: Two strengthenings (FD2) — the deleted expect was the only assertion.**
  - `coordinator_lifecycle_test.dart:~277` (transport stream error): replace `expect(errors, isNotEmpty, …)` with a pin of what actually arrives. The engine's `incoming` `onError` handler emits `PeerSyncError` with `SyncErrorType.protocolError` (`gossip_engine.dart:659-663`); the detector listens on the same broadcast stream, so first confirm by running what `errors.first` is, then pin:

```dart
expect(
  errors.first,
  isA<PeerSyncError>().having(
    (e) => e.type,
    'type',
    SyncErrorType.protocolError,
  ),
  reason:
      'a transport error must surface via the errors stream as a '
      'protocol-level error, not kill SWIM/gossip listening as an '
      'unhandled zone error',
);
```

  - `metrics_observability_test.dart:~117` (saveClockState failure): the emission site is `gossip_engine.dart:1897-1907` — `StorageSyncError(SyncErrorType.storageFailure, 'Failed to persist HLC clock state: …')`. Replace the `expect(errors, isNotEmpty, …)` with:

```dart
expect(
  errors.first,
  isA<StorageSyncError>()
      .having((e) => e.type, 'type', SyncErrorType.storageFailure)
      .having(
        (e) => e.message,
        'message',
        contains('Failed to persist HLC clock state'),
      ),
  reason: 'a storage failure must be logged or emitted, never silent',
);
```

  (Adjust the `.having` property names to the actual `SyncError` field names — verify in `lib/src/shared/domain/errors/sync_error.dart` before writing.)
- [ ] **Step 3: Mutation proofs for both strengthenings.** For each: temporarily change the emitted error at the production site (e.g. swap `SyncErrorType.protocolError` → `SyncErrorType.messageCorrupted` at `gossip_engine.dart:663`; swap the message string at `:1904`), run the one test, show RED with the new assertion's failure message, revert, show GREEN. Include both outputs in the task report.
- [ ] **Step 4: Full suite, analyze, format.** `dart test && dart analyze && dart format --output=none --set-exit-if-changed lib test` — green, count unchanged.
- [ ] **Step 5: Commit.**

```bash
git add -A && git commit -m "test: visible assertions after pumpUntil can actually fail (CC5-25 follow-up)"
```

### Task 3: Cleanup that survives failed assertions (M5)

**Files:**
- Modify: `test/coordinator/coordinator_lifecycle_test.dart` (~265 test body, plus the ~201 test's trailing `sub.cancel()`), `test/membership/application/failure_detector_test.dart` (~413–416), `test/sync/application/materialization/materialization_reentrancy_test.dart` (trailing `sub.cancel()` if present)

CC5-26's principle: cleanup registered at resource creation runs when a later assertion throws; trailing cleanup lines do not.

- [ ] **Step 1:** `coordinator_lifecycle_test.dart` ~265 ('a transport stream error is emitted, not silently fatal'): this is one of the four sanctioned direct `Coordinator.create` sites, so the builder's automatic teardown doesn't apply. Add `addTearDown(coordinator.dispose);` immediately after the `create` call and delete the trailing `await coordinator.dispose();` (double-dispose is safe — pinned by the builder self-tests).
- [ ] **Step 2:** `failure_detector_test.dart` ~413–416: move `await intermediarySub.cancel(); await targetSub.cancel(); h.stopListening();` into teardown registered at each resource's creation point: `addTearDown(intermediarySub.cancel)` / `addTearDown(targetSub.cancel)` immediately after each subscription is created, and `addTearDown(h.stopListening)` right after the harness is built (confirm `stopListening` is idempotent or tolerant of the detector already being stopped — read it first; if it is not, note that in the report and keep it in `addTearDown` anyway since teardown runs exactly once).
- [ ] **Step 3:** Same treatment for the trailing `await sub.cancel();` lines in the two tests Task 2 touched (`coordinator_lifecycle_test.dart` ~201, `materialization_reentrancy_test.dart` ~136): register `addTearDown(sub.cancel)` at subscription creation, delete the trailing line. These are the same hazard at sites this batch already edits; list them in the report. Touch nothing beyond the files named in this task.
- [ ] **Step 4: Full suite, analyze, format** — green, count unchanged.
- [ ] **Step 5: Commit.**

```bash
git add -A && git commit -m "test: cleanup registered at creation survives failed assertions (CC5-26 follow-up)"
```

### Task 4: Monitoring storage pin independent of the production formula (M7)

**Files:**
- Modify: `test/coordinator/monitoring_test.dart` (~93–100)

The test appends payloads of 3 and 5 bytes across two channels, then computes its expectation by calling the same `entryRepo.sizeBytes` the production path sums — a mirror, not a pin. `LogEntry.sizeBytes` is `52 + payload.length` (`log_entry.dart:74`), so the true expectation is `(52 + 3) + (52 + 5) = 112`.

- [ ] **Step 1:** Replace the mirror computation and both assertions with a literal pin:

```dart
// 52-byte per-entry overhead + payload length (LogEntry.sizeBytes — the
// documented storage-quota heuristic). A literal, not a call into the
// same repository the production path sums: if it mirrored the formula,
// a bug in the formula would cancel out of both sides. (52+3)+(52+5).
expect(usage.totalStorageBytes, equals(112));
```

Delete the now-subsumed `expect(usage.totalStorageBytes, greaterThan(0))` (vacuity: `equals(112)` is strictly stronger) and the `expectedBytes` computation. If the `entryRepo` local then has no remaining readers, drop the variable and let the builder default the repository.
- [ ] **Step 2: Run the test — green as-is.** `dart test test/coordinator/monitoring_test.dart` → PASS (the literal matches today's behavior).
- [ ] **Step 3: Mutation proof — this is the exact defect being closed, demonstrate it.** Temporarily change `52` to `60` in `LogEntry.sizeBytes` (`log_entry.dart:74`). The OLD mirror assertion would have stayed green (both sides drift together — that is M7); the NEW literal pin goes RED. Show the RED output, revert, show GREEN. Include in the report the one-line note that the old form was verified green under this same mutant before the rewrite (check out the pre-task file state to demonstrate, or argue it statically: both sides call the same accessor).
- [ ] **Step 4: Full suite, analyze, format** — green, count unchanged.
- [ ] **Step 5: Commit.**

```bash
git add -A && git commit -m "test: storage-usage pin is a literal, not a mirror of the production formula (CC5-27 follow-up)"
```

### Task 5: Nested-payload wire goldens (M1 — completes CC5-30)

**Files:**
- Modify: `test/sync/infrastructure/sync_message_codec_test.dart` (extend the wire-format goldens group, ~line 405 onward)

Batch D pinned the envelope (type byte + top-level key set) for all seven message types, but every fixture used empty `digests`/`entries`, so the nested key names remain co-drift-blind: a rename of a `LogEntry`, `ChannelDigest`, or `StreamDigest` wire field on both codec sides round-trips green today. These goldens close that. Nested shapes (verified against `sync_message_codec.dart:128-173`):

- `ChannelDigest` → `{'channelId': String, 'streams': List}`
- `StreamDigest` → `{'streamId': String, 'version': Map<String,int>}` (version-vector: author → seq)
- `LogEntry` → `{'author': String, 'sequence': int, 'timestamp': {'physicalMs': int, 'logical': int}, 'payload': base64 String}`
- `DeltaRequest.since` → version-vector map; `DeltaResponse.floor` → version-vector map, key present only when non-empty
- Membership messages carry no nested structures — sync codec only.

- [ ] **Step 1: Write the four goldens** (they PASS immediately — goldens pin current behavior; their power is proven by mutation in Step 3). Use literal expected values throughout, per the group's existing comment: an independently-sourced literal is the only thing that catches a both-sides drift.

```dart
test('DigestRequest nested digest encodes channelId/streams/streamId/'
    'version with version-vector entries as author→seq', () {
  final request = DigestRequest(
    sender: NodeId('peer1'),
    digests: [
      ChannelDigest(
        channelId: ChannelId('ch1'),
        streams: [
          StreamDigest(
            streamId: StreamId('s1'),
            version: VersionVector({NodeId('peer1'): 5}),
          ),
        ],
      ),
    ],
  );

  final json = jsonOf(codec.encode(request));
  final digest = (json['digests'] as List).single as Map<String, dynamic>;
  expect(digest.keys.toSet(), equals({'channelId', 'streams'}));
  final stream = (digest['streams'] as List).single as Map<String, dynamic>;
  expect(stream.keys.toSet(), equals({'streamId', 'version'}));
  expect(stream['version'], equals({'peer1': 5}));
});

test('DigestResponse nested digest uses the same wire shape as '
    'DigestRequest', () {
  final response = DigestResponse(
    sender: NodeId('peer1'),
    digests: [
      ChannelDigest(
        channelId: ChannelId('ch1'),
        streams: [
          StreamDigest(
            streamId: StreamId('s1'),
            version: VersionVector({NodeId('peer1'): 5}),
          ),
        ],
      ),
    ],
  );

  final json = jsonOf(codec.encode(response));
  final digest = (json['digests'] as List).single as Map<String, dynamic>;
  expect(digest.keys.toSet(), equals({'channelId', 'streams'}));
  final stream = (digest['streams'] as List).single as Map<String, dynamic>;
  expect(stream.keys.toSet(), equals({'streamId', 'version'}));
  expect(stream['version'], equals({'peer1': 5}));
});

test('DeltaRequest since encodes as a version-vector map of author→seq', () {
  final request = DeltaRequest(
    sender: NodeId('peer1'),
    channelId: ChannelId('ch1'),
    streamId: StreamId('s1'),
    since: VersionVector({NodeId('peer1'): 3, NodeId('peer2'): 7}),
  );

  final json = jsonOf(codec.encode(request));
  expect(json['since'], equals({'peer1': 3, 'peer2': 7}));
});

test('DeltaResponse entry encodes author/sequence/timestamp/payload with '
    'an Hlc timestamp object and base64 payload; a non-empty floor '
    'encodes as a version-vector map', () {
  final response = DeltaResponse(
    sender: NodeId('peer2'),
    channelId: ChannelId('ch1'),
    streamId: StreamId('s1'),
    entries: [
      LogEntry(
        author: NodeId('peer1'),
        sequence: 1,
        timestamp: Hlc(1000, 2),
        payload: Uint8List.fromList([1, 2, 3]),
      ),
    ],
    floor: VersionVector({NodeId('peer1'): 3}),
  );

  final json = jsonOf(codec.encode(response));
  final entry = (json['entries'] as List).single as Map<String, dynamic>;
  expect(
    entry.keys.toSet(),
    equals({'author', 'sequence', 'timestamp', 'payload'}),
  );
  expect(entry['author'], equals('peer1'));
  expect(entry['sequence'], equals(1));
  expect(entry['timestamp'], equals({'physicalMs': 1000, 'logical': 2}));
  expect(entry['payload'], equals('AQID')); // base64 of [1, 2, 3]
  expect(json['floor'], equals({'peer1': 3}));
});
```

Adjust constructor argument names to the real signatures (e.g. `DeltaResponse`'s `floor` parameter — check how the existing floor round-trip test at ~line 130 constructs it; `Hlc`'s positional order — the harness tests use `Hlc(1000, 0)`). Semantics and expected literals must stay exactly as written here.
- [ ] **Step 2: Run them — green.** `dart test test/sync/infrastructure/sync_message_codec_test.dart` → PASS.
- [ ] **Step 3: Mutation proof.** Temporarily rename the `'author'` key to `'a'` in BOTH `_encodeLogEntry` and `_decodeLogEntry` (`sync_message_codec.dart:162` and `:311`) — the existing round-trip tests stay green (that is exactly the co-drift blindness), the new golden goes RED. Show output; revert; green. Include the round-trips-stayed-green observation in the report — it is the proof these goldens add power the round-trips lack.
- [ ] **Step 4: Full suite, analyze, format** — green, count +4.
- [ ] **Step 5: Commit.**

```bash
git add -A && git commit -m "test: wire goldens pin nested payload keys — CC5-30 fully closed"
```

### Task 6: M8 comment, gates, audit addendum

**Files:**
- Modify: `test/membership/application/failure_detector_error_handling_test.dart` (~308–320 comment), `docs/audits/2026-08-23-clean-code-audit.md` (append addendum)

- [ ] **Step 1 (M8):** The fourth hand-rolled detector setup ('a handler failure is reported as protocolError…', ~308–372) already explains its seam choice but not why it bypasses `FailureDetectorTestHarness`. Append one sentence to the existing comment block: `// Stays hand-rolled: the harness constructs its own PeerRegistry and exposes no onEvent seam, so a throwing registry sink is inexpressible through it.`
- [ ] **Step 2 (gates):** Repo root `melos run test` + `melos run analyze` green; `packages/gossip` `dart format --output=none --set-exit-if-changed lib test` exit 0.
- [ ] **Step 3 (addendum):** Append "## Remediation — Batch D follow-up (2026-08-26)" to the audit in the established style, ≤20 lines: commit range; items closed (M1 → CC5-30 now fully closed including nested payload keys; M2, M3, M5, M7, M8 from Batch D's outcome record); the exact suite arithmetic (expected 1076 → ~1082: +1 builder guard, +4 nested goldens, +1 if any other test is added — state the real numbers); note that zero production files changed; name the mutation proofs run (error-type swaps, the `52→60` heuristic mutant, the `author→a` codec rename) and that the Task 4/5 mutants were verified to leave the OLD assertions green — the defect class these closures remove.
- [ ] **Step 4: Commit.**

```bash
git add -A && git commit -m "docs: record Batch D follow-up in the CC5 audit; fourth detector setup explains itself (CC5 batch D follow-up)"
```

- [ ] **Step 5 (controller):** Final whole-branch review reproducing at least one mutation proof per task that claims one, then finishing-a-development-branch (merge into `working-connection`), then update the memory resume state (Batch D follow-up done; NEXT = Batch E).

## Self-review notes

- Spec coverage: M1 → Task 5; M2 → Task 1; M3 → Task 2; M5 → Task 3; M7 → Task 4; M8 → Task 6. All six routed items owned. NOT in scope, deliberately: the coordinator trace-dropping sites (`coordinator.dart:482`, `:698` — production changes, Batch C's record routes them to "the next sweep", i.e. Batch H's surface work), the materializer rebuild-marker (roadmap item, contract change), and any harness API growth (FD3 — Batch E territory).
- This batch's defect class is the same as Batch D's — deleting coverage while claiming to strengthen it — countered the same way: the static vacuity argument is stated per deletion, both strengthenings and both new-power pins (Tasks 4/5) carry mutation proofs with shown output, and the final review reproduces proofs rather than accepting them.
- Type consistency: `createTestCoordinator`'s new `String? nodeId` (Task 1) is consumed nowhere else in this plan — Tasks 2–5 never pass `nodeId`. The golden fixtures use only constructors already exercised by the existing round-trip tests.
- Order: Tasks 1–5 are independent; 6 must run last (its addendum states the final arithmetic and its review covers the whole branch).
