# Kotlin Recency Suppression Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port Dart's round-level recency suppression to `gossip-kt`: a round skips peers exchanged with inside the current interval, picks the stalest otherwise, and both ends of an exchange record it.

**Architecture:** A pure `GossipPartnerSelector` in sync's domain services makes the pick over `SyncPartner` values (which regain `lastAntiEntropyMs`, mapped by `MembershipPeerDirectory`). `GossipEngine` keeps the port reads, records the exchange when it sends a digest request and when it answers one, and stops recording on merge. No wire change, no boundary change.

**Tech Stack:** Kotlin, JUnit 5 via `kotlin("test")`, `kotlinx-coroutines-test`, the `gossip-kt-testing` harness.

**Spec:** `docs/superpowers/specs/2026-11-17-kt-recency-suppression-design.md` (gossip repo, this branch).

**Repositories and branches:** Tasks 1–6 are in `gossip-kt` on branch `claude/project-thread-juqoud` (create from `main`, 1a57f70 or later). Task 7 is in `gossip` on the same-named branch, which already holds the spec and this plan.

## Global Constraints

- One top-level class/interface/object per file, file named after it (gossip-kt `CLAUDE.md`).
- `sync/domain` may reference only `shared` and `sync/domain`; the selector takes no port and no `Peer` (`BoundaryTest`, `LayerDirectionTest`).
- No concurrency primitive outside `infrastructure/` (`LockPlacementTest`); no wall-clock read (`ClockPlacementTest`). Time and randomness are passed in as data.
- A `@Test` method returns `Unit` (`TestShapeTest`).
- Fresh means `lastAntiEntropyMs != null && nowMs - lastAntiEntropyMs < intervalMs`; stale is `>=`. `null` is never fresh.
- Stalest wins: smallest `lastAntiEntropyMs`, `null` before every real value; ties broken by one `random.nextInt(ties.size)` draw.
- Recording order in the round: record, then send. On the responder: record first, before learning holdings, ungated by `isRunning`.
- Every verification run names the root task: `./gradlew :test --tests '<filter>'`; the full gate is `./gradlew build`.
- Commits carry no model identifier; messages end with the session's Co-Authored-By and Claude-Session trailers.

## Review Focus

1. A peer whose recorded timestamp is ahead of `nowMs` (a wall clock stepped back) must count as fresh, not crash or sort as stalest; worst case is one interval of delay. Pinned in Task 2.
2. A send that throws after the pick must still have recorded the exchange, so the next round moves on instead of retrying the same peer forever. Pinned in Task 3.
3. A paused engine that answers a digest request must still record the exchange, so a resumed engine does not immediately re-gossip with a peer that just reconciled it. Pinned in Task 4.
4. Two converged nodes at the same static interval must settle to one exchange per interval per pair, not zero (both sides suppressed forever) and not two. Pinned in Task 5.
5. The only stale peer being congested must produce a skipped round with the "no stale, uncongested peers" log, not a send to a fresh peer. Pinned in Task 3.

---

### Task 1: `SyncPartner.lastAntiEntropyMs` through the directory

**Files:**
- Modify: `src/main/kotlin/com/neutrinographics/gossip/sync/domain/values/SyncPartner.kt`
- Modify: `src/main/kotlin/com/neutrinographics/gossip/sync/infrastructure/MembershipPeerDirectory.kt` (`toPartner`)
- Modify: `src/main/kotlin/com/neutrinographics/gossip/sync/domain/interfaces/PeerDirectory.kt` (KDoc only)
- Test: `src/test/kotlin/com/neutrinographics/gossip/sync/infrastructure/MembershipPeerDirectoryTest.kt`

**Interfaces:**
- Produces: `data class SyncPartner(val nodeId: NodeId, val smoothedRtt: Duration?, val lastAntiEntropyMs: Long? = null)`.

- [ ] **Step 1: Write the failing tests** in `MembershipPeerDirectoryTest`, next to the RTT mapping tests:

```kotlin
@Test
fun `a partner never exchanged with maps to a null lastAntiEntropyMs`() = runTest {
    val (directory, registry, _) = createFixture()
    registry.addPeer(peerA, occurredAt = at)
    assertNull(directory.reachablePartners().single().lastAntiEntropyMs)
}

@Test
fun `a recorded exchange surfaces as the partner's lastAntiEntropyMs`() = runTest {
    val (directory, registry, _) = createFixture()
    registry.addPeer(peerA, occurredAt = at)
    directory.recordAntiEntropy(peerA, 12_345L)
    assertEquals(12_345L, directory.reachablePartners().single().lastAntiEntropyMs)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./gradlew :test --tests '*MembershipPeerDirectoryTest*'`
Expected: compilation failure, `lastAntiEntropyMs` unresolved on `SyncPartner`.

- [ ] **Step 3: Add the field and the mapping.** Add `val lastAntiEntropyMs: Long? = null` to `SyncPartner` with a one-line KDoc (the last exchange with this partner, either direction, on the time port's `nowMs` timeline; `null` = never). In `toPartner`, pass `lastAntiEntropyMs = peer.lastAntiEntropyMs`. Update `SyncPartner`'s class KDoc: it now carries the two signals sync consumes, RTT for timing and the last exchange for suppression and coverage.

- [ ] **Step 4: Replace the "Future port note" paragraph in `PeerDirectory`'s KDoc** with one sentence: the partner's `lastAntiEntropyMs` is read by the round's selector and written by `recordAntiEntropy` from both ends of an exchange; `recordMessageReceived` is not mirrored because the coordinator credits every inbound frame before any codec sees it.

- [ ] **Step 5: Run to verify they pass**

Run: `./gradlew :test --tests '*MembershipPeerDirectoryTest*'`
Expected: PASS, including the four existing tests.

- [ ] **Step 6: Commit**

```bash
git add src/main/kotlin/com/neutrinographics/gossip/sync/domain/values/SyncPartner.kt \
  src/main/kotlin/com/neutrinographics/gossip/sync/infrastructure/MembershipPeerDirectory.kt \
  src/main/kotlin/com/neutrinographics/gossip/sync/domain/interfaces/PeerDirectory.kt \
  src/test/kotlin/com/neutrinographics/gossip/sync/infrastructure/MembershipPeerDirectoryTest.kt
git commit -m "feat(sync): surface the last exchange on SyncPartner through the peer directory"
```

---

### Task 2: `GossipPartnerSelector`, the pure pick

**Files:**
- Create: `src/main/kotlin/com/neutrinographics/gossip/sync/domain/services/GossipPartnerSelector.kt`
- Test: `src/test/kotlin/com/neutrinographics/gossip/sync/domain/services/GossipPartnerSelectorTest.kt`

**Interfaces:**
- Consumes: `SyncPartner` from Task 1.
- Produces: `object GossipPartnerSelector { fun select(candidates: List<SyncPartner>, nowMs: Long, interval: Duration, random: Random): SyncPartner? }`.

- [ ] **Step 1: Write the failing tests.** Helper: `private fun partner(name: String, last: Long? = null) = SyncPartner(NodeId(name), smoothedRtt = null, lastAntiEntropyMs = last)`; `private fun pick(vararg c: SyncPartner, nowMs: Long = 10_000, seed: Int = 1) = GossipPartnerSelector.select(c.toList(), nowMs, 1.seconds, Random(seed))`.

```kotlin
@Test fun `a never-exchanged peer is picked before any exchanged peer`() {
    assertEquals(partner("b"), pick(partner("a", 1_000), partner("b")))
}
@Test fun `the stalest exchanged peer wins`() {
    assertEquals(partner("a", 1_000), pick(partner("a", 1_000), partner("b", 2_000)))
}
@Test fun `ties are broken by the draw`() {
    val tied = arrayOf(partner("a", 1_000), partner("b", 1_000))
    val picks = (1..20).map { pick(*tied, seed = it) }.toSet()
    assertEquals(tied.toSet(), picks, "both tied peers must be reachable through the draw")
}
@Test fun `a peer exchanged with inside the interval is dropped`() {
    assertEquals(partner("b", 8_000), pick(partner("a", 9_500), partner("b", 8_000)))
}
@Test fun `a peer exchanged with exactly one interval ago is eligible`() {
    assertEquals(partner("a", 9_000), pick(partner("a", 9_000)))
}
@Test fun `every candidate fresh answers null`() { assertNull(pick(partner("a", 9_500), partner("b", 9_999))) }
@Test fun `no candidates answers null`() { assertNull(pick()) }
@Test fun `a null timestamp is not fresh when now is zero`() { assertEquals(partner("a"), pick(partner("a"), nowMs = 0)) }
@Test fun `a timestamp ahead of now counts as fresh`() { assertNull(pick(partner("a", 10_500))) }
```

- [ ] **Step 2: Run to verify they fail**

Run: `./gradlew :test --tests '*GossipPartnerSelectorTest*'`
Expected: compilation failure, `GossipPartnerSelector` unresolved.

- [ ] **Step 3: Implement `GossipPartnerSelector.select`** in the new file. KDoc says why (the round's pick is a rule over values, as the probe selector is; time and the draw are inputs so a pick is reproducible) and names the two rules from Global Constraints. Body: filter out fresh (`last != null && nowMs - last < interval.inWholeMilliseconds`), find `minOf { it.lastAntiEntropyMs ?: -1L }` among the rest, draw among those at the minimum. Return `null` on empty.

- [ ] **Step 4: Run to verify they pass**

Run: `./gradlew :test --tests '*GossipPartnerSelectorTest*'`
Expected: PASS (9 tests).

- [ ] **Step 5: Run the gates**

Run: `./gradlew :test --tests '*architecture*'`
Expected: PASS (the new file is sync-domain over sync values; no edge-table change).

- [ ] **Step 6: Commit**

```bash
git add src/main/kotlin/com/neutrinographics/gossip/sync/domain/services/GossipPartnerSelector.kt \
  src/test/kotlin/com/neutrinographics/gossip/sync/domain/services/GossipPartnerSelectorTest.kt
git commit -m "feat(sync): GossipPartnerSelector, the pure recency-suppressed partner pick"
```

---

### Task 3: The round picks through the selector and records the exchange

**Files:**
- Modify: `src/main/kotlin/com/neutrinographics/gossip/sync/application/GossipEngine.kt` (`performGossipRound`, ~lines 350–385)
- Test: `src/test/kotlin/com/neutrinographics/gossip/sync/application/GossipEngineTest.kt`

**Interfaces:**
- Consumes: `GossipPartnerSelector.select` (Task 2), `SyncPartner.lastAntiEntropyMs` (Task 1).
- Produces: a round that records before sending; the DEBUG log line `Skipping gossip round: no stale, uncongested peers`.

Harness facts: `createHarness()` defaults to a static 200 ms interval and `Random(42)`; `harness.peerRegistry.updatePeerAntiEntropy(id, ms, occurredAt = at)` sets a peer's timestamp; `harness.timePort.setNowMs(ms)`; `receivedBy(harness, peer)` captures a peer's inbound frames; `decodeOne(bytes)` decodes one; `createHarness(wrapPort = { ... })` wraps the message port.

- [ ] **Step 1: Write the failing tests** in `GossipEngineTest`, in the gossip-round section:

```kotlin
@Test
fun `gossip round picks the least-recently-gossiped peer and sends DigestRequest`() = runTest {
    // Renamed from `gossip round selects random reachable peer and sends DigestRequest`;
    // same body, plus a second peer with an older exchange that must be the one addressed.
    val harness = createHarness(); setupChannel(harness)
    harness.timePort.setNowMs(100_000)
    harness.peerRegistry.addPeer(peerA, occurredAt = at)
    harness.peerRegistry.addPeer(peerB, occurredAt = at)
    harness.peerRegistry.updatePeerAntiEntropy(peerA, 50_000, occurredAt = at)
    harness.peerRegistry.updatePeerAntiEntropy(peerB, 40_000, occurredAt = at)
    val (toA, jobA) = receivedBy(harness, peerA); val (toB, jobB) = receivedBy(harness, peerB)
    harness.engine.performGossipRound()
    assertTrue(toA.isEmpty()); assertIs<DigestRequest>(decodeOne(toB.single().data))
    jobA.cancel(); jobB.cancel()
}

@Test
fun `rotates through peers, every peer gossiped exactly once within n rounds`() = runTest {
    val harness = createHarness(gossipInterval = 10.milliseconds); setupChannel(harness)
    val peers = listOf("a", "b", "c", "d").map { NodeId("peer-$it") }
    peers.forEach { harness.peerRegistry.addPeer(it, occurredAt = at) }
    val caps = peers.associateWith { receivedBy(harness, it) }
    repeat(peers.size) { harness.engine.performGossipRound() }   // nowMs stays 0: never-gossiped peers always outrank gossiped ones
    peers.forEach { p -> assertEquals(1, caps.getValue(p).first.count { decodeOne(it.data) is DigestRequest }, "peer $p once per cycle") }
    caps.values.forEach { it.second.cancel() }
}

@Test
fun `records the anti-entropy timestamp for the selected peer`() = runTest {
    val harness = createHarness(); setupChannel(harness)
    harness.peerRegistry.addPeer(peerA, occurredAt = at)
    assertNull(harness.peerRegistry.findById(peerA)!!.lastAntiEntropyMs)
    harness.timePort.setNowMs(5_000)
    harness.engine.performGossipRound()
    assertEquals(5_000L, harness.peerRegistry.findById(peerA)!!.lastAntiEntropyMs)
}

@Test
fun `a round skips a peer whose exchange is fresher than the current interval`() = runTest {
    val harness = createHarness(); setupChannel(harness)   // static 200 ms
    harness.peerRegistry.addPeer(peerA, occurredAt = at)
    harness.timePort.setNowMs(5_000)
    harness.peerRegistry.updatePeerAntiEntropy(peerA, 4_900, occurredAt = at)
    val (received, job) = receivedBy(harness, peerA)
    harness.engine.performGossipRound()
    assertTrue(received.isEmpty(), "all candidates fresh: the round must send nothing")
    job.cancel()
}

@Test
fun `a stale peer is still gossiped with`() = runTest {
    // as above with updatePeerAntiEntropy(peerA, 4_800, ...) → exactly one DigestRequest received
}

@Test
fun `the only stale peer being congested skips the round with the no-stale-uncongested log`() = runTest {
    // peerA fresh (timestamp = nowMs), peerB stale but congested (reuse the congestion idiom of
    // `gossip round skips congested peers`); collect onLog; assert nothing received by either and
    // the log contains "Skipping gossip round: no stale, uncongested peers".
}

@Test
fun `a send that throws has already recorded the exchange`() = runTest {
    // createHarness(wrapPort = { port -> a MessagePort delegating to port whose send throws IllegalStateException },
    //   onError = { errors += it }); addPeer(peerA); setNowMs(5_000); performGossipRound()
    // assert lastAntiEntropyMs == 5_000 and the error reached onError (the round reports, never throws — keep today's contract).
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./gradlew :test --tests '*GossipEngineTest*'`
Expected: the new tests fail (B not addressed; timestamp null after the round; fresh peer still receives); everything else green.

- [ ] **Step 3: Rewrite the selection in `performGossipRound`.** After the congestion filter: `val interval = effectiveGossipInterval` (read after `beginRound`; keep Dart's comment on why, in two lines), `val nowMs = timePort.nowMs`, `val partner = GossipPartnerSelector.select(candidates, nowMs, interval, random) ?: run { log(DEBUG, "Skipping gossip round: no stale, uncongested peers"); return }`, then `peerDirectory.recordAntiEntropy(partner.nodeId, nowMs)` before `sendMessage(...)`. Fold the existing all-congested log into the selector's null branch only if the message stays informative; otherwise keep both. Update the method KDoc to Dart's four steps (filter congested and fresh; stalest with random tiebreak; record; send).

- [ ] **Step 4: Run to verify they pass**

Run: `./gradlew :test --tests '*GossipEngineTest*'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/main/kotlin/com/neutrinographics/gossip/sync/application/GossipEngine.kt \
  src/test/kotlin/com/neutrinographics/gossip/sync/application/GossipEngineTest.kt
git commit -m "feat(sync): recency-suppressed, least-recently-gossiped round that records before it sends"
```

---

### Task 4: Record on answering a digest request, not on merge

**Files:**
- Modify: `src/main/kotlin/com/neutrinographics/gossip/sync/application/GossipEngine.kt` (`handleDigestRequest` ~line 434; the `merger` construction's `onNewEntriesMerged` ~line 206)
- Test: `src/test/kotlin/com/neutrinographics/gossip/sync/application/GossipEngineTest.kt` (~lines 2139–2195)

**Interfaces:**
- Consumes: Task 3's engine.
- Produces: `onNewEntriesMerged = { recordNews() }`; `handleDigestRequest` begins with `peerDirectory.recordAntiEntropy(request.sender, timePort.nowMs)`.

- [ ] **Step 1: Write the failing tests.** Replace `DeltaResponse updates peer anti-entropy timestamp` with:

```kotlin
@Test
fun `handling an inbound DigestRequest records the exchange`() = runTest {
    val harness = createHarness(); harness.engine.start(); setupChannel(harness)
    harness.peerRegistry.addPeer(peerA, occurredAt = at)
    harness.timePort.setNowMs(5_000)
    harness.engine.handleMessage(DigestRequest(sender = peerA, channelDigests = emptyList(), announced = emptyList()))
    assertEquals(5_000L, harness.peerRegistry.findById(peerA)!!.lastAntiEntropyMs, "a reciprocated exchange is coverage for both sides")
}

@Test
fun `a paused engine still records the exchange it answers`() = runTest {
    // same, but pause the engine (the lifecycle idiom the pause tests use) before handleMessage;
    // the response is still sent and lastAntiEntropyMs == 5_000.
}

@Test
fun `merging a DeltaResponse records news but not anti-entropy coverage`() = runTest {
    // body of the old `DeltaResponse updates peer anti-entropy timestamp`, asserting
    // assertNull(peer.lastAntiEntropyMs) after the merge.
}
```

Rename `a throwing onEntriesMerged still records news and anti-entropy credit` to `a throwing onEntriesMerged still records news`, and drop its `lastAntiEntropyMs` assertion (line ~2190); keep the snap-back assertion.

- [ ] **Step 2: Run to verify they fail**

Run: `./gradlew :test --tests '*GossipEngineTest*'`
Expected: the DigestRequest tests fail (timestamp null); the merge test fails (timestamp set).

- [ ] **Step 3: Move the recording.** In `handleDigestRequest`, first statement after the TRACE log: `peerDirectory.recordAntiEntropy(request.sender, timePort.nowMs)`, with a two-line comment (a reciprocated exchange is coverage for both sides; ungated, a paused engine that answers still records). In the `merger` construction, `onNewEntriesMerged = { recordNews() }` (drop the `peer ->` parameter if the callback type allows, else name it `_`). Adjust `DeltaMerger`'s KDoc if it describes the credit.

- [ ] **Step 4: Run to verify they pass**

Run: `./gradlew :test --tests '*GossipEngineTest*'` then `./gradlew :test --tests '*DeltaMergerTest*'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/main/kotlin/com/neutrinographics/gossip/sync/application/GossipEngine.kt \
  src/test/kotlin/com/neutrinographics/gossip/sync/application/GossipEngineTest.kt
git commit -m "fix(sync): record anti-entropy coverage when answering a digest request, not when merging"
```

---

### Task 5: Harness scenario, one exchange per interval per pair

**Files:**
- Test: `src/test/kotlin/com/neutrinographics/gossip/integration/RecencySuppressionTest.kt` (new)

**Interfaces:**
- Consumes: `TestNetwork`, `scenario(...)`, `corruptLink`, `runRounds`, `awaitConverged` as `IdleQuiescenceTest` uses them; the engine from Tasks 3–4.

- [ ] **Step 1: Write the failing test.** Config: `TestNetwork.DEFAULT_CONFIG.copy(gossipInterval = 1.seconds, adaptiveTimingEnabled = false)` so the window is fixed. Tap both directions as `IdleQuiescenceTest.tapBoth` does, but count only frames that decode to `DigestRequest` (decode through the node's codec, or match the wire type byte through `WireTypes`; the builder picks whichever the harness exposes). After `awaitConverged`, reset the counter, `runRounds(30, step = 1.seconds)`, and assert `count in 25..31`: one request per interval per pair, where unsuppressed symmetric rounds would give about 60. KDoc: translated in spirit from Dart's pacing suite; the number this pins is the pair's, not a node's.

- [ ] **Step 2: Run to verify it fails on `main`'s behavior.** Temporarily check out the engine from before Task 3 (`git stash` is not enough across commits; instead run the test once with the selector call replaced by the old random pick, confirm it reads ~60, revert). If that is awkward, skip the red run and record in the commit message that the count was observed at the old value by reasoning from symmetric rounds.

- [ ] **Step 3: Run to verify it passes**

Run: `./gradlew :test --tests '*RecencySuppressionTest*'`
Expected: PASS.

- [ ] **Step 4: Run the full idle suite for regressions**

Run: `./gradlew :test --tests '*IdleQuiescenceTest*'`
Expected: PASS (fewer frames than before, every assertion still holds).

- [ ] **Step 5: Commit**

```bash
git add src/test/kotlin/com/neutrinographics/gossip/integration/RecencySuppressionTest.kt
git commit -m "test(integration): a converged pair exchanges once per interval under recency suppression"
```

---

### Task 6: Kotlin docs and the full gate

**Files:**
- Modify: `CLAUDE.md` (services list, line ~56–57: add `GossipPartnerSelector` after `DigestAnswering`)
- Modify: `src/main/kotlin/com/neutrinographics/gossip/sync/application/GossipEngine.kt` class KDoc (lines ~59, ~69: "random peer" → "the least-recently-gossiped peer not exchanged with inside the interval")
- Modify: `README.md` if it says the round picks a random peer (grep `random`)

- [ ] **Step 1: Make the three edits.**
- [ ] **Step 2: Run the full gate**

Run: `./gradlew build`
Expected: BUILD SUCCESSFUL, all seven architecture gates green, `RetiredSurfaceTest` green (no retired name revived).

- [ ] **Step 3: Commit and push**

```bash
git add CLAUDE.md README.md src/main/kotlin/com/neutrinographics/gossip/sync/application/GossipEngine.kt
git commit -m "docs: the round picks the least-recently-gossiped peer; name GossipPartnerSelector"
git push -u origin claude/project-thread-juqoud
```

- [ ] **Step 4: Open the gossip-kt PR** titled "Recency suppression: skip peers exchanged with inside the interval (wire-efficiency phase 2)". Body: the required attribution lines first, then what changed (selector, both-side recording, merge-time recording dropped), the tests added, the register row closed, and a line that the server picks it up on the next opendoor-api submodule bump with that repo's live-device validation. Assign `da1nerd`, request review, subscribe to PR activity.

---

### Task 7: gossip docs — roadmap, backlog, register

**Files (gossip repo, branch `claude/project-thread-juqoud`):**
- Modify: `docs/roadmap.md` item 11 (line ~224) and the wire-efficiency status row (line ~352)
- Modify: `docs/backlog/kt-port-wire-efficiency.md` "Phase split" section
- Modify: `docs/backlog/kt-normalize-twin-divergences.md` row "Anti-entropy coverage: which side records it" (line ~103) and append one row
- Modify: `docs/backlog/health-adopt-kt-flow-backs.md` candidate list

- [ ] **Step 1: Roadmap.** Item 11: phase 2 complete; recency suppression ported in gossip-kt PR #N (date); the item rides the next opendoor-api bump. Status row: `◐` → `☑` with the same note.
- [ ] **Step 2: Backlog item.** In "Phase split", add a dated paragraph: recency suppression shipped (PR #N) as a pure `GossipPartnerSelector` plus both-side recording; the merge-time recording was dropped to match Dart.
- [ ] **Step 3: Register.** Row 103: append `**Closed (2026-11-17):** kt records when it answers a digest request (ungated) and no longer on merge (gossip-kt PR #N).` New row: `| Gossip partner pick as a pure service | kt's round picks through `GossipPartnerSelector` (sync domain service over `SyncPartner` values; time and the draw are inputs). Dart's `_selectGossipPartner`/`_staleUncongestedCandidates` are private engine methods owning a `Random`. | kt | Flow-back: Dart extracts the same selector; homed in [the flow-backs item](health-adopt-kt-flow-backs.md). |`
- [ ] **Step 4: Flow-backs item.** Add the gossip partner selector to the candidate list, next to the probe selector's "randomness as an input" entry.
- [ ] **Step 5: Commit, push, open the gossip docs PR** titled "docs: recency suppression ported to Kotlin (wire-efficiency phase 2 complete)" with the attribution lines, linking the gossip-kt PR. Assign `da1nerd`, request review, subscribe.

```bash
git add docs/roadmap.md docs/backlog/kt-port-wire-efficiency.md docs/backlog/kt-normalize-twin-divergences.md docs/backlog/health-adopt-kt-flow-backs.md
git commit -m "docs: recency suppression ported to Kotlin; register row closed, selector flow-back recorded"
git push -u origin claude/project-thread-juqoud
```
