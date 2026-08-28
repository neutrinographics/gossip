# Comment Hygiene and Intra-File Organization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The campaign's closing act (roadmap: `docs/backlog/health-comment-hygiene.md`, scope settled by the owner): every comment in `lib/`/`test/` either states a why the code cannot express or is deleted; audit-ID citations are replaced by their substance; history commentary dies; comment-paragraphs over code blocks become intention-named functions; banner dividers retire; ADR references and true invariant comments stay.

**Architecture:** Behavior-preserving throughout. Comment edits are inert by definition; the comment-to-function extractions follow Batch F7's proven discipline — verbatim token motion into named private functions, zero logic edits, the unchanged suite as the net, reviewers reconstructing moved bodies. The only semantic changes are the three ride-along redundant-copy removals (each with a written equivalence argument) and mechanical test-NAME edits.

**Tech Stack:** Pure Dart (`packages/gossip`), `dart test`/`analyze`/`format`, melos gates.

**Spec:** `docs/backlog/health-comment-hygiene.md` (scope section, owner-settled). Inventory at branch base (`d782208`): 55 audit-ID citation lines in 13 lib files (ADR refs excluded — they stay); 46 banner lines in 4 files (`failure_detector.dart`, `probe_target_selector.dart`, `materialization_service.dart`, `in_memory_message_port.dart`); 42 test-side citation lines; ~20 batch-key test names. Comment-line share leaders: engine 613/1556, coordinator 428/1119, detector 369/1051, channel_service 282/738.

## Global Constraints

- Branch `comment-hygiene` (created from working-connection @ d782208, suite 1190). Finish = PR, no local merge.
- **The comment rubric, applied per comment:**
  - `///` contract docs on public/interface members: KEEP; sharpen to why-not-how where they restate steps. An interface file being doc-heavy is correct (`entry_repository.dart` at 79% is a contract, not a smell).
  - Audit-ID citations (`CC5-n`, `COR3-n`, `WIRE4-n`, `OBS-n`, bare `H2`/`H3`/`H4`/`G5`/`M1` keys): the key is deleted; the SUBSTANCE stays — inline the one-sentence rationale the key stood for (usually already adjacent), or delete the whole comment where the post-campaign code self-explains. `docs/audits/` remains the deep record; code comments no longer point into it.
  - ADR references (`ADR-001` … `ADR-013`): KEEP — permanent design documents, ordinary practice.
  - History/migration commentary ("previously", "used to", "before X adopted", "pre-extraction"): DELETE; git and the audits are the journal.
  - Inline `//` paragraphs explaining WHAT a block does: extract the block into an intention-named private function (verbatim motion) and delete or shrink the comment to residual why. Extraction only where the block genuinely does a nameable sub-thing or mixes abstraction levels — do not force fragmentation (small functions are a result, not a rule).
  - Invariant comments the code cannot express (the late-Ack grace finally, wedge staleness gating, mark-before-await, conservative-cost never-underestimates, clock-coupling): KEEP, sharpened.
  - Banner dividers (`// ----`): DELETE everywhere; where a banner grouped a real concept, the extraction pass's named functions carry it.
- **Extraction discipline (F7's):** token-level verbatim motion; parameters threaded, nothing else; zero test-file diffs from extraction tasks; the full suite green after every task is the preservation evidence. A reviewer reconstructs each moved body against the pre-task commit.
- Zero assertion changes anywhere; test-NAME edits (I4) are mechanical.
- Gates per task: full `dart test` (1190 baseline; only I5 may change the count and only if a ride-along demands it — expect level), `dart analyze`, format check, boundary test. Commit footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## Design decisions (pre-filled; binding unless Joel vetoes)

- **DI1 — batch-key test names stripped.** Test names describe behavior, not provenance: `'auto-compaction publishes StreamCompacted on coordinator.events (H4)'` → the same name without the key; group names like `'… (G3)'` likewise. Mechanical, name-only.
- **DI2 — `architecture.md` deleted.** Wholesale pre-reorg rot (documents deleted types, pre-ADR-010 layers, "not yet implemented" features that shipped). Superseded by ADR-010 + the package CLAUDE.md + README + the guides. Deletion recorded in the closing addendum; any inbound links repointed (grep docs/).
- **DI3 — the class-doc pointer paragraphs die with the keys.** The "Comment keys like COR3-n … refer to findings in docs/audits/" sentences (engine + detector class docs) are deleted once their files carry zero keys.
- **DI4 — the three redundant copies removed with equivalence arguments.** The `VersionVector` constructor copies and normalizes since Batch H, so: `Map<NodeId,int>.from(streamCache)` at the in-memory entry repository's two vector reads feeds a constructor that copies again — drop the outer copy (argument: the constructor's copy fully isolates; the source map is never exposed). `Map.unmodifiable(merged)` inside `VersionVector.merge` wraps a map the constructor immediately copies — drop the wrap (argument: the wrap protected a map that no longer escapes; post-constructor-copy it is a wasted intermediate with identical observable semantics).
- **DI5 — per-file over per-concern tasking.** Hygiene is file-local; each task owns a territory of files end-to-end (citations + history + extractions + banners in one pass per file) so every file is touched once and reviewed once.

## Batch map

| Task | Territory |
|---|---|
| I1 | `lib/src/membership/` (detector, selector, the rest) — the banner-heaviest territory |
| I2 | `lib/src/sync/application/` (engine, collaborators, channel_service, materialization) — the citation-heaviest |
| I3 | `lib/src/coordinator/` + `lib/src/shared/` (+ any remaining lib stragglers) |
| I4 | `test/` — citations, batch-key names (DI1), pointer-comment stragglers |
| I5 | Ride-alongs: DI4 copies, DI2 architecture.md, DI3 pointer paragraphs (whichever survive to here) |
| I6 | Gates, closing audit addendum, roadmap item flipped ☑, final review, PR |

Sequential I1 → I6. Every task's report carries: per-file before/after counts (citation lines, banner lines, inline-`//` lines, total comment lines), the list of extracted functions with their source blocks, and the deleted-comment classes.

---

### Task I1: Membership territory

**Files:** `lib/src/membership/**` — primary: `application/failure_detector.dart` (369 comment lines, banners), `domain/services/probe_target_selector.dart` (banners), `domain/services/probe_timing_policy.dart`, `application/peer_service.dart`, `domain/**` remainder.

- [ ] **Step 1 (sweep, per file):** apply the comment rubric file by file. Known targets: the detector's banner sections (all go); its citation keys (the class-doc pointer sentence goes per DI3 once keys are zero); the WIRE4-3/H3 keyed rationales in the selector (substance stays, keys go); any history phrasing.
- [ ] **Step 2 (extractions):** in the detector, candidate blocks with explanatory paragraphs (identify honestly — e.g. the probe-round unreachable-peer preamble, the recovery logging block in `_recordPeerContact`) become named private functions ONLY where a name genuinely carries the paragraph's content. List every extraction with its verbatim source range; list every candidate you REJECTED and why (the rejection list is how the reviewer knows judgment was applied, not automation).
- [ ] **Step 3:** full gates; zero test diffs. Commit: `refactor: membership comments state why or nothing; blocks read as named functions (comment hygiene)`

### Task I2: Sync application territory

**Files:** `lib/src/sync/application/**` — primary: `gossip_engine.dart` (613 comment lines), `channel_service.dart`, `delta_merger.dart`, `reactive_pusher.dart`, `digest_budgeter.dart`, `materialization/**` (banners in `materialization_service.dart`).

- [ ] **Step 1 (sweep):** rubric per file. The engine is the citation capital — every COR3/WIRE4/H-key rationale gets its substance inlined (most are already substantive; the key token and any "see docs/audits" tail go). The merger/pusher's invariant docs (chain ordering, wedge, staleness) are KEEP-and-sharpen exemplars.
- [ ] **Step 2 (extractions):** engine candidates: the round-candidate filter with its recency-suppression paragraph (`_staleUncongestedCandidates(...)`-shaped), the reciprocal-pull block inside `_onDigestRequest` if still paragraph-commented; channel_service/materialization candidates per the same honest test. Extraction + rejection lists as I1.
- [ ] **Step 3:** full gates; zero test diffs. Commit: `refactor: sync application comments state why or nothing; blocks read as named functions (comment hygiene)`

### Task I3: Coordinator + shared territory

**Files:** `lib/src/coordinator/**` (428 comment lines in `coordinator.dart`), `lib/src/shared/**` (banners in `in_memory_message_port.dart`), any lib file the I1/I2 greps show still carrying keys.

- [ ] **Step 1 (sweep):** rubric per file. `coordinator.dart`'s numbered how-lists in method docs get the why-lens where they restate code; `in_memory_message_port.dart`'s banners go.
- [ ] **Step 2 (extractions):** coordinator candidates (e.g. the addPeer grace/probe sequence commentary) per the honest test; extraction + rejection lists.
- [ ] **Step 3 (lib-wide zero check):** `grep -rEn "//.*(CC5|COR3|WIRE4|OBS)-?[0-9]" lib` and the bare-key pattern — ZERO hits (ADR excluded); banner grep — ZERO. Full gates. Commit: `refactor: coordinator and shared comments state why or nothing (comment hygiene)`

### Task I4: Test territory

**Files:** every test file carrying citations (42 lines) or batch-key names (~20).

- [ ] **Step 1:** citation keys out of test comments, substance stays (many are fixture rationales — keep the rationale, drop the key). History comments out.
- [ ] **Step 2 (DI1):** batch-key tokens out of test/group NAMES — name-only edits, assertions untouched, verified by a diff filter showing only string-literal name lines changed.
- [ ] **Step 3:** test-side zero check (same greps over `test/`); full gates (count unchanged — names are not tests). Commit: `test: names and comments describe behavior, not provenance (comment hygiene)`

### Task I5: Ride-alongs

- [ ] **Step 1 (DI4):** remove the two `Map<NodeId,int>.from` wraps in `in_memory_entry_repository.dart`'s vector reads and the `Map.unmodifiable` in `VersionVector.merge`, each with its equivalence argument in the report; full suite is the net (zero test changes).
- [ ] **Step 2 (DI2):** `git rm packages/gossip/architecture.md` (verify the actual path); repoint or delete any inbound doc links (grep docs/ README CLAUDE).
- [ ] **Step 3 (DI3 residual):** confirm the pointer paragraphs died in I1/I2; delete any survivor.
- [ ] **Step 4:** full gates. Commit: `refactor: redundant defensive copies removed; stale architecture doc deleted (comment hygiene ride-alongs)`

### Task I6: Gates, closing record, PR

- [ ] **Step 1:** repo-root melos test + analyze; format check; chat example suite.
- [ ] **Step 2:** append a short closing section to `docs/audits/2026-08-23-clean-code-audit.md`: "## Campaign close — comment hygiene (2026-08-27)": the before/after metrics (citation lines 97 → 0 excluding ADR; banners 46 → 0; per-file comment-share deltas for the big four; extraction count with the honest-rejection note), DI1–DI4 decisions, and the statement that the audit's keys now resolve only here — the code stands on its own rationale.
- [ ] **Step 3:** roadmap: flip `health-comment-hygiene` to ☑ with the shipping commit; backlog file gains a Done pointer per the roadmap conventions.
- [ ] **Step 4:** Commit `docs: campaign closed — code comments stand on their own (comment hygiene)`. Controller: final whole-branch review (Fable; duties: reconstruct every extraction verbatim, verify the zero-greps, verify no doc-content loss on a sampled basis — pick 10 deleted citation sites and confirm their substance survives inline or the code self-explains), push, PR, memory.

## Self-review notes

- Coverage: all four rubric dimensions land per territory (I1-I3 lib, I4 test); the ride-alongs and record close in I5/I6. The scope excludes file splits/barrels/test-tree per the owner's definition.
- The batch's defect class is **meaning loss disguised as cleanup** — a deleted key whose substance was NOT adjacent, an extraction that subtly reorders evaluation, a sharpened doc that drops a load-bearing clause. Countered: per-comment disposition lists in reports, the rejection lists proving judgment, F7-grade verbatim reconstruction at review, and the final review's 10-site substance sampling.
- Risk named: I5's `Map.unmodifiable` removal changes an internal intermediate only — but if any test pins unmodifiability of a map REACHED through merge()'s result (`.entries` returns what the constructor built), the equivalence argument must address it before landing (the constructor's own storage is what `.entries` exposes — verify it is already unmodifiable-wrapped or document that mutability was never promised).
