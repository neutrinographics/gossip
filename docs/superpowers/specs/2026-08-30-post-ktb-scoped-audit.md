# Scoped post-KT-B audit (2026-08-30)

Pre-KT-C checkpoint after the wire-versioning batch, KT-A, and KT-B. Four questions,
scoped by agreement: this is not a re-review of already-reviewed code. Sibling of the
[foundation audit](2026-08-29-foundation-audit.md).

**Audited state:** gossip `working-connection` @ 8fc0165 · gossip-kt `feature/compaction`
@ 6ee2b03 · OpenDoorApp `wire-floor-translation` @ 25546213 (PR #485 open). All three
trees clean at audit time.

**Verdict:** the built work is sound and the records are honest. All gates green at the
expected counts (Q4). The wire is fully v1-compatible with the deployed fleet, but a
server deploy needs an opendoor-api adaptation PR first — the structure mirror broke
the server's build, its Postgres repository misses the two new floor methods, and its
error/log callbacks are unwired (Q1). Documentation drift across three batches:
two items, both fixed in this commit (Q2). The KT-C seam is sound — no missing
wire-ups; nine plan decisions enumerated, one with correctness stakes (the
unsynchronized in-memory repository vs a timer-driven compaction loop) that the KT-C
plan rules on explicitly (Q3).

---

## Q4 — Fresh gates (all green, counts measured)

| Suite | Expected | Measured | Result |
|---|---|---|---|
| gossip core (`packages/gossip`, `dart test`) | 1254 | **1254** | all pass |
| gossip_nearby (`flutter test`) | — | **189** | all pass |
| gossip_bluey (`flutter test`) | — | **228** | all pass |
| `melos run analyze` (all packages) | 0 issues | **0 issues** | clean |
| gossip-kt (`./gradlew cleanTest test`, forced rerun, XML-counted) | 764 | **764** (0 failures, 0 skipped) | all pass |
| OpenDoorApp (`flutter test test/features/sync`) | 360 | **360** | all pass |

Method note: the first kt run came back fully `UP-TO-DATE` (Gradle cache) — a cached
green is not a gate, so it was re-run with `cleanTest` and counted from the JUnit XML.

## Q1 — Deploy-safety of feature/compaction @ 6ee2b03

**Verdict: wire-safe, but NOT deployable as a bare submodule bump — the server does not
compile against 6ee2b03.** Full change-by-change table with file:line evidence on both
sides: `.superpowers/audit-2026-08-30/q1-deploy-safety.md` (session working notes,
git-ignored).

**The build gate (the one RISK finding).** opendoor-api consumes gossip-kt as a
composite source build (`includeBuild`), and the structure mirror renamed every package
the server imports — 27 distinct imports across 17 main-source files, all resolving to
packages that no longer exist (`gossip.shared.*`, `gossip.entries.*`,
`gossip.messages.ProtocolCodec` — deleted, `gossip.transport.port.*`, …). Beyond
imports, the server's own `PgEntryRepository` no longer implements the grown
`EntryRepository` interface: `getCompactionFloor` and `adoptVersionFloor` are missing,
and the engine calls both on live paths — they need real Postgres persistence (a floors
table/column), not stubs, or the contiguity-stall and authorship-floor protections are
silently defeated the day anything compacts. The fix is mechanical but mandatory.

**Post-fix, the wire is v1-compatible with the deployed fleet in both directions** —
verified against the deployed app's old `ProtocolTranslator` and the pinned Dart codec
@ 73f6a580, including:

- Single-entry v1 envelopes (chattier: N+N frames instead of 1+1) decode identically
  through the old translator's generic map iteration — SAFE.
- Floor emission is genuinely DORMANT (server never calls compact, no auto-compaction
  exists yet, deployed apps have their compaction timer commented out); if a floor were
  ever emitted, the old translator silently drops the unknown key — no crash.
- The duplicate-throw contract flip is contained: the contiguity guard filters
  duplicates before the repository, and the coordinator receive loop catches and
  survives the residual path.
- The new strictness (ingestion guard, contiguity guard) converts the OLD code's
  silent-corruption failure modes (blind appends past sequence holes, phantom-channel
  rows) into refuse-and-retry modes — strict improvements.
- Payload signedness (signed→unsigned ints), empty-response suppression, PingReq
  `originalRequester` synthesis, pull-expiry timing (fixed 5s → adaptive 2–30s,
  per-peer keying): all verified compatible; the timing change is mesh-visible but
  benign (parallel pulls, filtered on arrival; disconnects now release pendings).

**Strong recommendation (found by the audit, not previously recorded):** the server
passes **neither `onError` nor `onLog`** to `Coordinator.create` — every diagnostic
this branch added (decode errors, contiguity-gap stalls, authorship-floor warnings,
ingestion refusals) is currently invisible. Wire both callbacks to slf4j in the same
PR as the import fix, or the first real stall will present as "sync silently stopped
for one author" with an empty log.

**Bottom line:** merging feature/compaction is safe for the mesh; deploying it requires
an opendoor-api adaptation PR (imports + two Pg floor methods + callback wiring). These
are owner-side preconditions now recorded against the wire spec's §5.3 step 4 in the
campaign backlog.

## Q2 — Record drift across wire batch + KT-A + KT-B

**Verdict: records match reality.** Twelve documents checked against code, git history,
and PR #14's merged state (full working notes:
`.superpowers/audit-2026-08-30/q2-record-drift.md`). The wire spec's §5.3/§7/§11 match
shipped code; the §5.3 step-3 gate is recorded exactly where its own instruction said;
all 8 divergence-register rows harvested at T8 exist with resolving cross-references;
both kt plan files carry their prescribed supersession notes; the CHANGELOG's cap
disclosure matches `coordinator_config.dart`/`event_stream.dart`; the campaign backlog
correctly shows wire batch + KT-A + KT-B closed with KT-C next.

Two findings, both fixed in this audit's commit:

1. **Homeless carried item (real):** the kt partition-primitive recommendation
   (KT-B T7 review) pointed at the campaign register as its home, but the register had
   no row for it. Row added to `docs/backlog/kt-wire-versioning-campaign.md`.
2. **Roadmap undercount (minor):** the divergence-register line said "two rows" need
   Dart-side normalizing; it is four (it missed the pre-existing frame-dispatch and
   decode-failure-contract rows). Corrected in `docs/roadmap.md`.

Non-finding worth recording: all three completed plan files have zero checked
checkboxes — deliberate convention (the SDD ledger, not the plan file, is the
completion record), consistent across both repos. Not drift.

## Q3 — KT-C seam assumptions

**Verdict: the seam is sound — six of eight assumptions hold outright; the two partials
are plan decisions, not blockers.** Full map and evidence:
`.superpowers/audit-2026-08-30/q3-ktc-seam.md` (Dart reference at exact file:line, kt
verification at 6ee2b03).

Assumptions that HOLD (evidence in the working notes): the repository floor primitives
(`removeEntries` raises the floor atomically, `getCompactionFloor`, `adoptVersionFloor`,
KT-A's monotonic marks and retention guards); all four retention policy types with the
KeepAll default applied in `ChannelService`; the floor→peer connection needs **zero new
wiring** (KT-B's `reportableFloor` reads the repo at serve time, so raising the floor
locally is immediately visible to lagging peers); `compactStream` already resets
materializers and publishes `StreamCompacted` through the existing domain-event flow;
`Coordinator.start` idempotence (KT-B) covers a new loop.

PARTIAL — the KT-C plan must decide (nine decisions enumerated in the working notes;
the load-bearing ones):

1. **Scheduler shape.** kt has no `GenerationScheduler`; its loop idiom
   (`schedulePeriodic` + cancelable handle) forecloses Dart's forking hazard by
   cancellation — but cannot express Dart's tick-vs-scheduling error asymmetry, and a
   tick throw on the current idiom dies silently in the SupervisorJob while `isRunning`
   keeps lying. Side finding: kt's gossip loop computes its adaptive interval once at
   start (`GossipEngine.kt:132`) where Dart recomputes per cycle — a latent twin
   divergence regardless of KT-C.
2. **`compactAll` must pre-filter.** kt's `compactStream` emits errors on its skip
   paths where Dart returns null silently — a naive periodic loop would emit an error
   every tick forever. And kt's `RetentionPolicy` lacks `retainsAll`, so without adding
   it, every tick loads every entry of every KeepAll stream just to prune nothing.
3. **Config disable idiom.** `CoordinatorConfig.init` and `schedulePeriodic` both
   `require` positive intervals (KT-A); Dart disables auto-compaction via
   null/zero. The two patterns collide and need an explicit representation.
4. **Threading — the one with correctness stakes (spot-verified by the controller, not
   just the agent):** the coordinator scope is multi-threaded `Dispatchers.Default`
   (`Coordinator.kt:137`), `InMemoryEntryRepository` has no synchronization at all, and
   the engine already touches the repository from both the receive path (`appendAll`,
   `GossipEngine.kt:426`) and the periodic round path (VV reads, :557/:613). The race
   class **exists today**; a timer-driven `compactAll` adds structural mutation
   (list removal + floor merge) to it. KT-C's plan must pick a stance explicitly
   (guard the repo per the registered kt monitor pattern / serialize onto the receive
   path / accept-and-document).

Also surfaced: the old kt compaction plan's remaining out-of-scope items — digest-level
floor advertisement, skip-below-peer-floor on serve, snapshot sync — are KT-D routing
candidates, not KT-C prerequisites; and its "currently manual only, matching Dart" note
is stale (Dart gained its periodic compaction loop in the 2026-07 audit remediation,
`b483f1d`; CC5-7 later moved it onto `GenerationScheduler` — this line originally
misattributed it to CC5, corrected at KT-C close) — KT-C's docs task should truth it.

## Findings routed

| Finding | Route |
|---|---|
| Server deploy preconditions (import fix, Pg floor persistence, callback wiring) | Two owner-side rows added to `docs/backlog/kt-wire-versioning-campaign.md`'s campaign register, attached to the migration playbook's step 4. |
| Homeless partition-primitive item (Q2) | Row added to the same campaign register. |
| Roadmap undercount of Dart-normalization register rows (Q2) | Corrected in `docs/roadmap.md` (two → four). |
| kt loops freeze their adaptive interval at start (Q3 side finding) | New "Per-cycle interval recomputation" row in `docs/backlog/kt-normalize-twin-divergences.md`; KT-C ports the scheduler, loop migration is the follow-up. |
| Unsynchronized `InMemoryEntryRepository` vs concurrent callers (Q3, pre-existing race class, controller-verified) | Ruled on in the KT-C plan (repository monitor guard per the registered kt pattern) — see the plan's Global Constraints and its dedicated task. |
| Old kt compaction plan's stale "matching Dart" note; KT-D routing candidates (digest-level floor advertisement, skip-below-peer-floor, snapshot sync) | KT-C plan's docs task truths the note and records the routing. |

No fix dispatches were needed — nothing surfaced in already-reviewed code; the RISK
finding lives in the not-yet-adapted server, and the correctness-stakes item is future
work KT-C now designs for.
