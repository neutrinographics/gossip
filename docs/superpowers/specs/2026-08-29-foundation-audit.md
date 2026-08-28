# Foundation audit — Dart↔Kotlin gossip port campaign

**Date:** 2026-08-29
**Auditor:** independent audit pass (read-only; no code or doc was modified)
**Question:** before the wire/codec batch executes, is anything important
missing from the completed work?

**Scope audited**

- gossip-kt structure mirror — `26dcc13..bd50285` (feature/compaction)
- Batch KT-A — `1ffbf0d..3836bc7` (feature/compaction, HEAD)
- Ledgers: `.superpowers/sdd/2026-08-29-kt-structure-mirror/progress.md`,
  `.superpowers/sdd/2026-08-29-kt-batch-a-repository-contract-v2/progress.md`
- Specs (gossip repo `docs/superpowers/specs/`): `2026-08-28-wire-versioning.md`,
  `2026-08-28-wire-recon-facts.md`, `2026-08-28-vendored-kt-recon.md`,
  `2026-08-28-kt-port-dart-fix-inventory.md`
- Pending plan: `docs/superpowers/plans/2026-08-29-wire-codec-batch.md`

---

## Verdict summary

| # | Item | Verdict |
|---|---|---|
| A | Batch completeness | **SOLID** — every planned task recorded and verifiable; 3 cosmetic ledger gaps |
| B | Spec-vs-reality drift | **GAP** — 1 known + 4 new drifts; one is an internal contradiction that would break live interop |
| C | Interim-state safety | **SOLID / deploy-safe** — every interim contract is dormant by construction; one documentation gap |
| D | Carried-items registry | **GAP** — 4 homeless items; the durable homes of the rest are uncommitted files |
| E | Roadmap truth | **GAP** — all three kt items stale, the campaign's largest work item absent, 5 design docs orphaned *and* untracked |
| F | Coverage nets | **GAP** — checksum test does exist; fixtures are happy-path only; `gossip-kt-testing` unscanned by the boundary test |
| G | Count/gate integrity | **SOLID** — kt 629/0 exact, Dart 1190 green, whole monorepo green |

---

## A. Batch completeness — SOLID

Both plans' task lists were diffed against their ledgers task-by-task.

**Structure mirror (S0–S9):** all 10 tasks carry an explicit "complete" line.
All 13 commits in `26dcc13..bd50285` map to a ledger entry. S0 and S8 each
took one fix round, both recorded with the accept-without-re-dispatch ruling.

**Batch KT-A (A1–A6):** all 6 tasks complete. A1–A3 took one comment-only fix
round (`36fc299`). A4–A6 landed with zero fix rounds.

**Spot-checks against git/filesystem at HEAD (5 run, 5 matched):**

1. **S0 fixtures** — `src/test/resources/wire/v1-kt/` holds exactly 7 `.frame`
   files plus `checksums.txt`; `V1WireGoldenTest.kt` has exactly 9 `@Test`
   methods. Claim exact.
2. **S9 geometry** — `src/main` top-level packages are exactly
   `{shared(37), sync(36), membership(15), coordinator(10)}` = 98 `.kt` files.
   Zero `ProtocolCodec` references remain anywhere in `src`. Claim exact.
   *Caveat:* `src/test` additionally has `architecture`, `integration`, `wire`
   packages; the ledger's unqualified "top-level packages exactly {…}" wording
   doesn't say it is a `src/main` claim.
3. **`adoptVersionFloor` uncalled** — declared `EntryRepository.kt:169`,
   implemented `InMemoryEntryRepository.kt:185`. Repo-wide grep finds
   invocations *only* in `EntryRepositoryContractTest`. Zero production callers.
   Claim exact.
4. **Plan count corrections** — `git show bd50285` confirms every count line
   rewritten (S0 595→596, S6 602→603, S7 602→603, S8/S9 603→604, S3
   "13 files"→14) plus a supersession note explaining the undercount.
5. **Suite counts** — verified independently under G.

**No task was descoped without a record.** Every deferral traced to a written
home: A3's duplicate-throw→KT-B (KT-A ledger:9), S6's lenient decode→wire batch
(mirror ledger:14), the PeerDirectory ACL port (mirror ledger:22,46 *and* the
`BoundaryTest` debt row).

**Both review waivers are sound.** The KT-A waiver's "disjoint files" argument
holds on inspection (A1–A3 touch the repository pair + contract test; A4–A6
touch retention services, time ports, config). The mirror waiver rests on five
independent reviews plus a controller-run cross-task check that this audit
reproduced.

### Cosmetic gaps (no correctness impact)

- **A-1** `docs/plans/2026-08-29-kt-structure-mirror.md:1334` — S9's own gate
  criterion still says the wire fixtures should be "exactly one commit"; they
  are two (`a7cc343` + fix round `182639f`). The doc pass fixed every count
  line but missed this one.
- **A-2** KT-A ledger task log leaves A4–A6 reading "Sonnet review IN FLIGHT";
  their completion lives only in the batch header.
- **A-3** Mirror ledger:39 dispatched a **haiku** reviewer for S7 where the
  same ledger's execution discipline (line 11) specifies sonnet — a model
  downgrade with no recorded rationale. (Lowest-risk task in the batch: 4 file
  moves, 4 import deletions, 0 findings.)

---

## B. Spec-vs-reality drift — GAP

Method: field-by-field comparison of wire spec §7 against four artefacts —
Dart `sync_message_codec.dart` and `membership_message_codec.dart` on
`working-connection`, kt `SyncMessageCodec.kt` and `MembershipMessageCodec.kt`
at HEAD, and the seven golden fixtures.

### What is correct (verified, not assumed)

The spec's Dart-side fidelity is **excellent**. Every cited line number is
exact:

- §7.3 `hasMore` decode default → `sync_message_codec.dart:263` ✓
- §7.3 `floor` omit-when-empty → `:117-121` ✓
- §7.3 `floor` decode default → `:265-267` ✓
- §7.3 base64 payload → `:167` ✓
- §7.3 legacy int-list grace + out-of-range reject → `:319-335` ✓
- §4 family-split contract → `sync_message_codec.dart:39-59`,
  `membership_message_codec.dart:30-49` ✓

Dart's sync and membership codecs match §7.2/§7.3 field-for-field. kt's
`MembershipMessageCodec` matches §7.4 exactly, including the extra
`originalRequester` on PingReq. kt's `SyncMessageCodec` matches §7.4's batched
`channelDeltas` / nested `entries` shapes exactly.

### B-1 — v1-kt payload signedness (known; now confirmed with evidence)

`SyncMessageCodec.kt:193` encodes `JsonPrimitive(it.toInt())` over a
`ByteArray`. Kotlin's `Byte.toInt()` sign-extends, so bytes `0x80`–`0xFF` emit
as `-128`–`-1`. The spec (§7.2, inherited by §7.4) says elements are
"an integer in 0–255".

The golden fixture makes this ground truth — `deltaresponse.frame` contains
`"payload":[0,1,127,-128,-1]` in every entry. The fixtures encode reality; the
spec encodes something else.

### B-2 — the reject rule contradicts the dialect it governs *(most important)*

This is the drift that matters, and it is not merely a wording slip.

§7.2 states the out-of-range rule normatively and extends it:

> each element must be an integer in 0–255 (out-of-range values are corruption
> and must be rejected, not truncated mod 256 … and **both codecs' v1 modules
> adopt it**)

§7.4 then says "`Entry-v1` is exactly §7.2's". Composed, the spec instructs
every v1 implementation to **reject the bytes the deployed gossip-kt server
actually emits** — any payload containing a byte ≥ `0x80`, which is certain in
practice for binary or multi-byte UTF-8 content.

§8c compounds it: the negative-vector list includes "out-of-range legacy
payload byte" as a *reject* case, which is precisely v1-kt's normal case.

Three independent confirmations:

- kt's own decode does the opposite of the spec —
  `SyncMessageCodec.kt:279` reads `.int.toByte()`, i.e. truncates mod 256,
  exactly what §7.2 forbids.
- Dart already implements the reject — `sync_message_codec.dart:327-329`
  throws `ArgumentError` on `b < 0`.
- The golden fixtures prove the negative values are the deployed reality.

**Blast radius.** On the kt side this is self-detecting: implementing the
reject in kt's v1 module turns the goldens red immediately. The dangerous
surface is OpenDoorApp's `ProtocolTranslator` (§8c vector set 3), which lives
in neither library repo and is the one component that reads v1-kt payload
arrays and re-emits them Dart-side. A translator written to the spec as
currently worded breaks the app↔server link on real traffic. The deployed app
is pinned pre-reject, so the hazard is latent today and activates exactly when
this campaign upgrades it.

**Required amendment.** §7.4 must state that v1-kt payload elements are
**signed** (`-128`–`127`), that decoders normalise via `& 0xFF`, and that
§7.2's reject rule is scoped to the **v1-dart** dialect only (or widened to
accept `-128`–`255` and normalise). §8c's negative-vector list must be
corrected in the same edit.

### B-3 — integer width is undocumented and asymmetric

kt decodes `sequence` and every version-vector value with `.int` (32-bit);
`LogEntry.sequence` is `Int`. Dart uses 64-bit `int` throughout. §7.1
documents the width question only for `physicalMs`.

A Dart-origin sequence or VV value above 2^31−1 fails kt's decode today, and
under the current lenient decode that failure is an unreported `null` —
silent divergence. §7.1 needs a sentence fixing `sequence` and version-vector
values at 32-bit across both dialects (or mandating 64-bit in kt).

### B-4 — kt has no domain field for `floor` or `hasMore`

§7.4 says a v1-kt DeltaResponse "MAY additively carry `floor`", and §6.1
requires kt's v2 codec to emit `hasMore` and optional `floor`. But kt's
`DeltaResponse` and `DeltaRequest` domain messages have **no such fields at
all** — they carry only `sender` + the nested maps.

This is a domain-model change, not a codec key addition. The spec presents it
as additive wire work; the batch should know it touches
`sync/domain/messages/` and everything constructing those messages.

### B-5 — empty-frame contract asymmetry (minor)

§4 rule 1 says "Empty frame → decode error" for "every receiver in both
libraries", then cites only the Dart contract. kt returns `null`
(`SyncMessageCodec.kt:64`, `MembershipMessageCodec.kt:53`). This is consistent
with §6.2's deferral, but §4 rule 1 should cross-reference §6.2 so a reader
doesn't take it as already-true.

### B-6 — spec header still says DRAFT (hygiene)

`2026-08-28-wire-versioning.md:3` reads "**Status:** DRAFT — for owner review
before any implementation" while §11 records three normative owner rulings
dated 2026-08-29. A reader will treat ruled decisions as drafts.

### Should the spec be amended before the batch runs?

**Yes — B-2 is a must-fix.** It is the one drift that, implemented as written,
breaks a live link rather than failing a test. B-3 and B-4 should land in the
same edit because both change what the batch builds. B-5 and B-6 are hygiene
and can ride along.

---

## C. Interim-state safety — SOLID (deploy-safe), with one doc gap

Every deliberately-interim contract now on `feature/compaction` was enumerated
and traced to its actual invocation path.

| Interim contract | Documented where a reader hits it? | Deploy impact today |
|---|---|---|
| Silent duplicate skip (`appendAll`) | **Yes** — `EntryRepository.kt:60-72`, "Interim contract (Batch KT-A)" naming the KT-B tightening | None — behaviour-identical to pre-batch |
| Below-floor skip (`append`/`appendAll`) | **Yes** — class KDoc `:44-48` + per-method, names KT-B | **Dormant** — floor is always empty |
| Monotonic VV over unservable ranges, no floor on wire | **Partly** — see C-1 | **Dormant** — see trace below |
| `adoptVersionFloor` uncalled | **Yes** — KDoc `:154-171` describes it as the acceptance primitive; contract-tested | None — zero production callers |
| GossipEngine → membership debt | **Yes** — `BoundaryTest.kt:38-46`, machine-enforced with rationale + stale-row detection | None — architectural only |
| kt lenient decode (silent null) | **Yes** — `MessageCodec.kt:6-14`, explicitly "for now", points at wire versioning | Pre-existing; unchanged by these batches |

### The deploy trace — why the VV/floor changes are dormant

The controlling question was whether the interim version-vector change is
dormant absent a `compact()` call. It is, and by **two independent guards**:

1. **No automatic compaction exists.** `ChannelService.compactStream` is
   reachable only from `Channel.compact()` (`Channel.kt:115`) and
   `EventStream.compact()` (`EventStream.kt:66`) — both explicit public API.
   Grep confirms no timer, scheduler, or threshold invokes it;
   `GossipEngine.schedulePeriodic` drives gossip rounds only. Auto-compaction
   is future work (KT-C / inventory item 7).
2. **The default retention policy prunes nothing.**
   `ChannelService.kt:83` defaults to `KeepAllRetention`, whose `compact()`
   returns its input unchanged. `compactStream` then hits
   `if (removed.isEmpty()) return null` before `removeEntries` is ever called.

So `removeEntries` never runs → `compactionFloors` stays empty → the
below-floor guards compare against `0` and every real entry (sequence ≥ 1)
passes → `latestSequenceCache` equals the max sequence over stored entries,
exactly as before. **Merging and deploying `feature/compaction` today without
the wire batch changes nothing observable on the wire.**

Additionally, `Channel.compact()` fan-out is itself new on this branch
(`44ae68d`), so no existing caller can reach the changed paths.

**If an app opts in** (non-default retention *and* an explicit `compact()`
call), the interim state degrades gracefully rather than corrupting: the node
advertises a VV above what it can serve, so a peer re-requests the pruned
range every round and receives nothing — a futile-request loop and a
late-joiner that never converges for that range, until the floor reaches the
wire. This is strictly better than the pre-A1 behaviour it replaced
(entry resurrection plus silent sequence reuse), but it is a *new* degradation
mode and it is opt-in only.

### The two new construction guards are low-risk

A4/A5 convert previously-degenerate configs into fail-fast errors. Checked
individually, all reject only already-broken values:

- `CountBasedRetention` rejects **negative** only — `0` is explicitly legal
- `TimeBasedRetention` rejects **negative** only — `ZERO` is explicitly legal
- `CompositeRetention` rejects an **empty** policy list
- `CoordinatorConfig` / `RealTimePort.schedulePeriodic` reject **non-positive**
  intervals (a zero interval busy-spins the dispatcher rather than ticking)

No sane deployment supplies these. Fail-fast is the right call; noted only for
completeness.

### C-1 — the one documentation gap

`InMemoryEntryRepository.kt:150-157` explains why `latestSequenceCache` is not
regressed, and it explains it well — but it names only the cost of the
*rejected* alternative ("they re-send the pruned range every round… re-issue a
sequence number"). It does not name the cost of the *chosen* path: that
advertising a VV above the servable range makes peers request entries this
node can never supply, until the floor is on the wire. A future reader sees an
unqualified win. One sentence would close it.

**Nothing in the interim state is deploy-unsafe.** No loud flag is warranted.

---

## D. Carried-items registry — GAP

Every deferred or carried item found across both ledgers, all reviews, the
four specs, and the pending plan.

### Durably homed

| Item | Home | Strength |
|---|---|---|
| PeerDirectory ACL port (+ two-collaborator scope: `SynchronizedPeerRegistry.getReachablePeers` at GossipEngine:130,169 **and** `PeerService.recordPeerAntiEntropy/recordMessageSent` at :312,402) | Mirror ledger:22,46 **and** `BoundaryTest.kt` `acceptedDebt` row | **Strongest** — the test fails if the debt is paid and the row isn't deleted |
| Duplicate appends throw → KT-B | `EntryRepository.kt:60-72` KDoc + inventory item 9 | In-code |
| Below-floor skip → KT-B | `EntryRepository.kt:44-48` KDoc | In-code |
| kt lenient decode → wire batch | `MessageCodec.kt:6-14` KDoc | In-code |
| BoundaryTest typealias blind spot | Mirror ledger S8 + in-test comment | Recorded |
| Materializer rebuild-marker (Dart side) | `docs/backlog/engine-materializer-rebuild-marker.md` | Committed backlog |
| Batch envelope (future) | Spec §10 + `docs/backlog/engine-message-coalescing.md` | Committed backlog |
| Library wire-version default flip → ≥3.0.0 publish decision | Spec §11 decision 1 | Spec (uncommitted) |
| KT-B/C/D/E sequence + inventory items 1–5, 7–11, 13 | Inventory spec + both ledgers | Spec (uncommitted) |

### Homeless — flagged

- **D-1 — kt budgeting / delta pagination.** Falls between two stools: spec
  §10 hands budgeting to "the port campaign's wire batch", but the wire batch
  plan's decision 4 explicitly rules it **out** ("porting Dart's budgeting to
  kt is a separate batch"). That separate batch exists in neither the roadmap,
  the backlog, nor any plan. kt today has no digest budgeting and no delta
  pagination at all.
- **D-2 — OBS-3 digest budgeter cursor rotation (inventory item 6).** Classed
  "wire-efficiency" in the inventory's summary table and routed to **no**
  KT-A..E batch. Its natural owner is `docs/backlog/kt-port-wire-efficiency.md`,
  which does not mention it.
- **D-3 — the B-2 signedness/reject amendment.** No home at all; this audit is
  its first written record.
- **D-4 — kt commit-signing question.** Mirror ledger:33 records it as a "NOTE
  for Joel at batch end" (gossip-kt commits are unsigned, including the
  owner's own prior ones; offer `gpgsign` config). Both batches have since
  been reported and the note appears nowhere else. It either got raised and
  closed without a record, or it evaporated.

### D-5 — the structural finding

**The carried items with the weakest homes are not the obscure ones — they are
the ones whose only home is an uncommitted file.** The inventory spec, the
wire spec (including the owner's §11 rulings), and the batch sequence for
KT-B through KT-E all live in files git does not track (see E-3). The
in-code homes (KDocs, the `BoundaryTest` debt row) are durable; the
spec-resident ones are one `git clean` from gone.

---

## E. Roadmap truth — GAP

### E-1 — all three kt roadmap items are stale

`docs/roadmap.md`:

- **Line 76, `kt-mirror-bounded-contexts`** — still `☐` (open). It **shipped**
  in `26dcc13..bd50285`. Needs marking done, with the commit range, and a
  `- **Done** (2026-08-28) — …` bullet at the top of the backlog file's
  `## Related` (precedent: `health-comment-hygiene.md:52-54`).
- **Line 77, `kt-audit-legacy-bug-classes`** — doubly stale. The audit itself
  is *finished* (its deliverable is the 13-item inventory), and the summary
  still describes four bug classes and no batch sequence. Should read as
  in-progress with the KT-A..KT-E sequence and the KT-A commit range.
- **Line 75, `kt-port-wire-efficiency`** — not superseded by the wire batch
  (disjoint surfaces: codec/schema vs scheduling/filtering), but now
  **dependent** on it: entry-size estimation must read from the active send
  codec, so budgeting cannot be ported until the codec settles. `**Depends
  on:** nothing` is wrong. It should also absorb D-1 and D-2.

### E-2 — the campaign's largest work item has no roadmap presence

Wire versioning — a three-repo, owner-ruled, release-blocking piece of work —
is invisible from the roadmap. Per spec §1 the `working-connection` base64
change has *already* broken the deployed app and the deployed kt server (which
swallows the failure into a silent `null`). A new backlog file
`docs/backlog/kt-wire-versioning.md` plus a roadmap line is needed; priority is
the owner's call, but the branch cannot ship to the fleet without it.

### E-3 — five design documents are orphaned *and* untracked *(most urgent)*

All five are `??` in `git status` and referenced by **zero tracked file** in
the gossip repo:

```
docs/superpowers/specs/2026-08-28-wire-versioning.md
docs/superpowers/specs/2026-08-28-wire-recon-facts.md
docs/superpowers/specs/2026-08-28-vendored-kt-recon.md
docs/superpowers/specs/2026-08-28-kt-port-dart-fix-inventory.md
docs/superpowers/plans/2026-08-29-wire-codec-batch.md
```

Worse: **three already-committed gossip-kt plan files link two of them by
absolute path**, so the consumer is committed while the source is not —

- `gossip-kt/docs/plans/2026-08-29-kt-structure-mirror.md:41`
- `gossip-kt/docs/plans/2026-08-29-kt-batch-a-repository-contract-v2.md:41`
- `gossip-kt/docs/plans/2026-08-28-kt-batch-a-repository-contract.md:43`

The gossip repo is otherwise clean on `working-connection`, so a `git clean
-fd`, a worktree switch, or a fresh clone destroys the entire design record of
a three-repo campaign — including the only written statement of the owner's
2026-08-29 rulings (§11) and both verified wire recons the design rests on.
Every prior campaign in this repo committed its spec + plan and linked them
from the backlog item's `## Related`.

**Minimum fix: commit the five files.** Then wire them into `## Related` on the
new `kt-wire-versioning.md` and on `kt-audit-legacy-bug-classes.md`.

---

## F. Coverage nets — GAP

### F-1 — the checksum manifest test **already exists** (answering the open question)

`V1WireGoldenTest.kt:180-190`, test `every fixture matches its recorded
checksum`: it reads `checksums.txt`, asserts the recorded filename set equals
the vector set, and SHA-256s each `.frame`. It shipped with S0 in `a7cc343`.
`checksums.txt` is **not** an inert data file, and this does **not** need to
arrive in the wire batch.

Its precise power is narrower than it looks: the regenerate path rewrites the
frames *and* the manifest in one pass, so the manifest catches a fixture
mutated **without** a manifest update (accidental corruption, stray tool,
partial hand-edit) but cannot detect a wholesale regeneration. Reviewer
discipline on the diff remains the only defence there — which is what the plan
says.

### F-2 — the "vacuous-when-off regen guard" is contained

`V1WireGoldenTest.kt:136-151`: `if (!regenerate) return`. With the committed
`regenerate = false` this one test asserts nothing — genuinely vacuous, which
is why it was logged as a MINOR. But it is **1 of 9** `@Test` methods; the 7
`assertGolden` pins and the checksum test are unconditional. The regenerate
branch deliberately *throws*, so a build cannot be green while regenerating.
Keeping it was the right call. **The golden test cannot silently pass without
comparing anything.**

### F-3 — fixture coverage holes

The fixtures deliberately exercise more than expected — the signed-byte
boundary (`-128`, `-1`), multi-author VV key order, a zero-valued VV entry
(`"node-b":0`), a `physicalMs` exceeding Int range, and (verified, ledger
claim TRUE, added in `182639f`) multi-channel/multi-stream ordering. But every
fixture is a happy-path ASCII specimen. Absent:

1. **Empty payload** (`byteArrayOf()`) — the test helper hardcodes one 5-byte
   payload for every entry in every fixture.
2. **Zero-entry DeltaResponse** — the most common frame on a quiescent
   network, entirely unpinned.
3. **Empty digest list / empty version-vector map** — `VersionVector.EMPTY`
   never appears, so `{}` vs omitted-key is unpinned.
4. **Multi-channel/multi-stream ordering in the *digest* frames** — pinned for
   deltas only; digest frames carry exactly one channel and one stream.
5. **Unicode / non-ASCII IDs** — all IDs are `node-a`/`ch-1`/`st-1`. JSON
   escaping of `"`, `\`, newline, or non-BMP characters is unpinned, and the
   delta frames use IDs as **JSON object keys**, where Kotlin's
   `kotlinx.serialization` and Dart's `jsonEncode` need not agree on escaping.
6. **Large sequence numbers** — structurally impossible to fixture: kt's
   `sequence` is `Int`. See B-3.
7. **New message types are unguarded.** `WireTypesTest` pins only the byte
   *sets*, not constant→name (swapping `DIGEST_REQUEST`/`DIGEST_RESPONSE`
   keeps it green — only the goldens catch that), and nothing asserts "every
   encodable type has a fixture". A wire batch adding a type gets zero golden
   coverage by default.

### F-4 — boundary test holes

Solid on the common cases: a new top-level `wire/` package fails loudly as
`unknown module`; `membership → sync` and `shared → anything` fail; the
`acceptedDebt` row is correctly target-scoped (a reach from `GossipEngine.kt`
into `coordinator` still fails); stale rows fail the test. Holes:

1. **`gossip-kt-testing` is never scanned** — `root` is
   `src/main/kotlin/com/neutrinographics/gossip`. The published testing
   artifact imports `sync.domain.interfaces.EntryRepository` and has **no
   edge-table row at all**; its dependencies are unconstrained. `src/test` is
   likewise unscanned.
2. **The ACL is directory-scoped, not file-scoped** — any file under
   `sync/infrastructure/` gets a blanket pass to `membership`. A wire batch
   adding a second such file expands the concession silently.
3. **Typealias laundering is the genuine blind spot** — an alias declared
   under `sync/infrastructure/` (ACL-legal) resolving to a membership type and
   consumed from `sync/application/` shows no `membership` FQN at the
   consumption site. *Correction to the ledger:* `import … as Y` is **not**
   actually a blind spot — the import line carries the FQN and matches the
   regex.

### F-5 — contract tests: SOLID, with one expected future red

`EntryRepositoryContractTest` (~33 tests) pins append/appendAll dedupe, HLC
ordering, `latestSequence` as a persistent high-water mark across compaction
rounds, `getVersionVector` non-regression, floor accumulation, the
`vv >= floor` invariant, `adoptVersionFloor` raising both marks together, and
clear-path resets. Two clusters are directly wire-relevant: below-floor
rejection (the receive-side behaviour for any decoded delta) and the
silently-idempotent duplicate append — which **diverges from Dart**, where the
2026-07 audit made duplicates throw. When KT-B ports Dart's semantics this
contract goes red; that is the net working, but the batch should expect it.

### F-6 — Dart has no golden fixtures

Dart's protection is an inline `encode-side wire pinning` group at
`packages/gossip/test/sync/infrastructure/sync_message_codec_test.dart:405-563`
— hand-copied literals asserting type bytes, top-level key *sets*, nested key
names, and `entry['payload'] == 'AQID'`. Genuine co-drift protection, but
**key-set assertions, not byte-exact frames**, and no committed artifact a
second language can diff against.

Consequence for the wire batch: the golden fixtures protect kt against *self*-
regression only. There is no `v1-dart/` fixture directory to converge toward,
and producing the four shared vector sets (§8c) is **net-new work the batch
must scope**. Note the v1-dart↔v1-kt shape divergence (batched vs flat,
int-array vs base64) is *by design* — §7.2 and §7.4 are two deliberate
dialects bridged by the translator — so it is not itself a defect. What **is**
a defect is B-2, where the spec's reject rule collides with one of those
dialects.

---

## G. Count/gate integrity — SOLID

Both gates run to completion at the audited HEADs.

**gossip-kt @ `3836bc7` (feature/compaction):**

```
./gradlew clean test  →  BUILD SUCCESSFUL
tests 629  failures 0  errors 0  skipped 0
```

Exactly 629/0, matching the KT-A ledger's A6 gate. (Counted from
`build/test-results/test/*.xml` after a clean run; the first pass reported
`UP-TO-DATE` and was re-run clean to get a true count.)

**gossip @ `working-connection`:**

```
packages/gossip:  00:03 +1190: All tests passed!
melos run test:   SUCCESS (all packages)  [exit 0]
```

1190 green in the core package, and the whole monorepo (`gossip`,
`gossip_nearby`, `gossip_bluey`) passes. Both stated counts are accurate.

---

## Consolidated actions before the wire batch runs

**Must fix**

1. **Amend the wire spec for B-2** — scope §7.2's reject rule to v1-dart;
   state v1-kt payloads are signed `-128`–`127` and decoders normalise
   `& 0xFF`; correct §8c's negative-vector list. This is the one item that
   breaks a live link rather than a test.
2. **Commit the five campaign documents** (E-3). One command; currently one
   `git clean` from losing the owner's §11 rulings and both recons.

**Should fix in the same pass**

3. Amend §7.1 for integer width (B-3) and note that `floor`/`hasMore` are a kt
   **domain-model** change, not just codec keys (B-4).
4. Flip the spec header off DRAFT (B-6) and cross-reference §6.2 from §4 rule 1
   (B-5).
5. Update the three stale roadmap lines and add the wire-versioning backlog
   item (E-1, E-2).
6. Give D-1 (kt budgeting/pagination) and D-2 (OBS-3) a written home; resolve
   or close D-4 (commit signing).
7. Have the batch decide **up front** whether adding `floor`/`hasMore`/base64
   to kt is a fixture regeneration or a wire break (F-6), rather than
   discovering it mid-batch.

**Worth doing, not blocking**

8. Add fixtures for the empty payload, the zero-entry DeltaResponse, and a
   non-ASCII ID used as a JSON object key (F-3).
9. Add an edge-table row for `gossip-kt-testing`, or scan it (F-4).
10. Add the one-sentence cost note to `removeEntries` (C-1).
11. Ledger hygiene: A-1, A-2, A-3.

---

## Confidence statement

**High confidence in the completed work.** The two batches are complete,
honestly recorded, and independently verifiable — five spot-checks against git
and the filesystem all matched their ledger claims exactly, both gates are
green at the stated counts, and the interim state is deploy-safe by two
independent structural guards rather than by luck. The review discipline
(machine token-preservation proofs, an opus dispatch-equivalence proof, the
byte goldens, the machine-enforced boundary table) is genuinely strong, and
the spec's Dart-side citations are exact to the line.

**Moderate confidence in the surrounding record.** The gaps are concentrated
in what is *written down and where*, not in what was built: one spec
contradiction that would survive into a live break, five uncommitted design
documents, a stale roadmap, and four carried items with no durable home.
All are cheap to close, and none require revisiting the shipped code.

**One caveat on scope.** The B-2 blast radius runs through OpenDoorApp's
`ProtocolTranslator`, which is outside both audited repositories and was
therefore reasoned about from the spec and the two recons rather than read
directly. That reasoning should be confirmed against the app's actual
translator before the wire batch commits to the reject rule.
