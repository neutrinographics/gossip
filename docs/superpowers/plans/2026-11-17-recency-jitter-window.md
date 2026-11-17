# Recency Window Under Jitter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the gossip timing policy own the round schedule on both twins, so the recency-suppression window is the jitter floor of the interval the pending wait was drawn from and a node never suppresses its own next round.

**Architecture:** `GossipTimingPolicy` (sync domain service, both twins) gains `armRound`, which remembers the interval it draws the jittered wait from, and `recencyWindow`, the jitter floor of that remembered interval. The engine's `nextDelay` calls `armRound`; the round filters by `recencyWindow`. The jitter fraction is named once in the shared kernel beside `applyJitter`, with a `jitterFloor` helper.

**Tech Stack:** Dart (`packages/gossip`, `dart test`), Kotlin (`gossip-kt`, JUnit 5 via `./gradlew :test`; this container needs `LANG=C.UTF-8` for gradle).

**Spec:** `docs/superpowers/specs/2026-11-17-recency-jitter-window-design.md` (gossip repo; also at `/mnt/project-files/recency-suppression/`).

## Global Constraints

- No wire change; no change to the pacer's growth (1.5x), ceiling (30 s), jitter width (±20 %), news, or the probe loop.
- Both twins ship the same behavior and equivalent tests; a Kotlin test translated from Dart cites its source in its KDoc (the repo's citation convention).
- Boundary rule: `GossipTimingPolicy` is sync domain; it may import `shared/` only. `jitterFloor` lives in `shared/domain/services`.
- Kotlin gates must stay green: `./gradlew :test --tests '*architecture*'` (seven gates; `RetiredSurfaceTest` means no retired names revive).
- Comments say why, never how. The "deliberate: read after quietRound" comment (Dart) and its Kotlin twin come out.
- Branches: gossip and gossip-kt both on `claude/project-thread-d0wq5r`. gossip-kt's branch is cut from `origin/claude/project-thread-juqoud` (PR #22, recency suppression) while #22 is open; its PR targets that branch and is retargeted to `main` when #22 merges.
- Commit messages carry the session's attribution trailer; PR bodies start with the project's attribution lines and end with the session footer (both in the thread's instructions, not reproduced here).

## Review Focus

1. **Static interval.** A caller-supplied `gossipInterval` must give a static window of 0.8x it, never 1.0x, else the self-skip persists on every test network and on the server's fixed-interval configs. Pinned in Task 2 / Task 7 (policy test 4) and Task 3 / Task 8 (engine test 5 runs on a static interval).
2. **A round nobody armed.** `performGossipRound` called directly (tests, `syncWithPeer`'s neighbours) must not throw or use a zero window when nothing was armed. Pinned by policy test 4 ("before any arm") in Task 2 / Task 7.
3. **Growth must not move the armed interval.** A quiet round between arm and read must leave the window at the armed floor. Policy test 3 and engine test 6.
4. **Wake re-arm.** News at the ceiling re-arms from the base interval while the ceiling wait may stand; the window shrinks, never grows. Documented on `armRound` per the spec; the existing "news wakes the round" tests on both twins must still pass (they run through `armRound` now).
5. **Exact-edge arithmetic.** `jitterFloor` must round exactly as `applyJitter` does at a draw of 0, or a wait of 799.999 ms meets a window of 800 ms and the floor case skips. Pinned by the jitter property test in Task 1 / Task 6 and by engine test 5 driving the exact floor.

---

## Part 1 — gossip-kt

### Task 1: `jitterFloor` and the named fraction (Kotlin shared kernel)

**Files:**
- Modify: `src/main/kotlin/com/neutrinographics/gossip/shared/domain/services/Jitter.kt`
- Test: `src/test/kotlin/com/neutrinographics/gossip/shared/domain/services/JitterTest.kt`

**Interfaces:**
- Produces: `const val DEFAULT_JITTER_FRACTION = 0.2` (top-level, same file); `fun jitterFloor(base: Duration, fraction: Double = DEFAULT_JITTER_FRACTION): Duration`; `applyJitter`'s `fraction` default becomes `DEFAULT_JITTER_FRACTION`.

- [ ] **Step 1: Write the failing tests** in `JitterTest`:

```kotlin
@Test fun `jitterFloor is the base scaled by one minus the fraction`() {
    assertEquals(800.milliseconds, jitterFloor(1.seconds))
    assertEquals(900.milliseconds, jitterFloor(1.seconds, fraction = 0.1))
}
@Test fun `a zero fraction makes the floor the base`() { assertEquals(3.seconds, jitterFloor(3.seconds, fraction = 0.0)) }
@Test fun `applyJitter never answers less than jitterFloor of the same base`() {
    val rng = Random(7); val base = 1.seconds
    repeat(2000) { assertTrue(applyJitter(base, rng) >= jitterFloor(base)) }
}
@Test fun `a draw of zero lands exactly on the floor`() {
    assertEquals(jitterFloor(1.seconds), applyJitter(1.seconds, FloorDraw))   // FloorDraw: Random with nextBits = 0
}
```

- [ ] **Step 2: Run** `LANG=C.UTF-8 ./gradlew :test --tests '*.JitterTest'` — expected: compile failure, `jitterFloor` unresolved.
- [ ] **Step 3: Implement** `jitterFloor` in `Jitter.kt` with the same rounding as `applyJitter` (`(base.inWholeMicroseconds * (1 - fraction)).roundToLong().microseconds`); name the constant; point `applyJitter`'s default at it. KDoc on `jitterFloor`: the earliest a jittered wait on `base` can end, which is what a window compared against such a wait must not exceed.
- [ ] **Step 4: Run** the same command — expected: PASS.
- [ ] **Step 5: Commit** `feat(shared): name the jitter fraction and add jitterFloor`.

### Task 2: The policy owns the schedule (Kotlin)

**Files:**
- Modify: `src/main/kotlin/com/neutrinographics/gossip/sync/domain/services/GossipTimingPolicy.kt` (`GossipTiming` and `GossipTimingPolicy` live here)
- Test: `src/test/kotlin/com/neutrinographics/gossip/sync/domain/services/GossipTimingPolicyTest.kt`

**Interfaces:**
- Consumes: Task 1's `jitterFloor`, `applyJitter`.
- Produces: `GossipTiming.armedInterval: Duration?` (new field, `null` in `initial`); `fun GossipTimingPolicy.armRound(timing: GossipTiming, random: Random): Transition<GossipTiming, Duration>` (state with `armedInterval = effectiveInterval(timing)`, result `applyJitter(that interval, random)`); `fun GossipTimingPolicy.recencyWindow(timing: GossipTiming): Duration` = `jitterFloor(timing.armedInterval ?: effectiveInterval(timing))`.

- [ ] **Step 1: Write the failing tests** (the file's existing helper style: start from `adaptive()`, thread values):

```kotlin
@Test fun `armRound answers a wait inside the jitter band and remembers the interval it drew from`() {
    val (armed, wait) = GossipTimingPolicy.armRound(adaptive(), Random(7))
    assertEquals(1000.milliseconds, armed.armedInterval)
    assertTrue(wait in 800.milliseconds..1200.milliseconds)
}
@Test fun `recencyWindow never exceeds any wait armRound can answer`() {
    val rng = Random(11)
    repeat(2000) { val (armed, wait) = GossipTimingPolicy.armRound(adaptive(), rng); assertTrue(GossipTimingPolicy.recencyWindow(armed) <= wait) }
}
@Test fun `a quiet round grows the next interval but leaves the armed window alone`() {
    val (armed, _) = GossipTimingPolicy.armRound(adaptive(), Random(7))
    val grown = GossipTimingPolicy.quietRound(armed)
    assertEquals(1500.milliseconds, interval(grown))
    assertEquals(800.milliseconds, GossipTimingPolicy.recencyWindow(grown))
}
@Test fun `before any arm the window is the floor of the current interval, static included`() {
    assertEquals(800.milliseconds, GossipTimingPolicy.recencyWindow(adaptive()))
    assertEquals(160.milliseconds, GossipTimingPolicy.recencyWindow(GossipTiming.initial(200.milliseconds, adaptiveEnabled = true)))
}
@Test fun `a second arm replaces the armed interval`() {  // the wake re-arm edge, spec §"The wake"
    val (first, _) = GossipTimingPolicy.armRound(quiet(adaptive(), rounds = 3), Random(7))
    val (second, _) = GossipTimingPolicy.armRound(GossipTimingPolicy.news(first), Random(7))
    assertEquals(1000.milliseconds, second.armedInterval)
}
```

Also extend `every transition answers a new value and leaves the one it was given alone` to cover `armRound`.

- [ ] **Step 2: Run** `LANG=C.UTF-8 ./gradlew :test --tests '*.GossipTimingPolicyTest'` — expected: compile failure.
- [ ] **Step 3: Implement** the field and the two functions. KDoc on `armRound`: arming is one decision — the wait and the window it implies come from the same reading; and the accepted wake edge (a re-arm whose wait the scheduler discards leaves the window smaller than it could be, never larger). KDoc on `recencyWindow`: why the floor (a wait is never shorter than it, so a round never suppresses its own previous exchange) and why the fallback (a round nobody armed).
- [ ] **Step 4: Run** the same command — expected: PASS.
- [ ] **Step 5: Commit** `feat(sync): GossipTimingPolicy arms the round and owns the recency window`.

### Task 3: The engine uses the schedule (Kotlin)

**Files:**
- Modify: `src/main/kotlin/com/neutrinographics/gossip/sync/application/GossipEngine.kt` (`roundLoop.nextDelay` ~line 146; `performGossipRound` ~lines 383-390)
- Modify: `src/main/kotlin/com/neutrinographics/gossip/sync/domain/services/GossipPartnerSelector.kt` (parameter `interval` → `window`; KDoc)
- Test: `src/test/kotlin/com/neutrinographics/gossip/sync/domain/services/GossipPartnerSelectorTest.kt` (rename interval-edge cases to window wording; behavior unchanged)
- Test: `src/test/kotlin/com/neutrinographics/gossip/sync/application/GossipEngineTest.kt`

**Interfaces:**
- Consumes: Task 2's `armRound`, `recencyWindow`.
- Produces: `nextDelay = { timing.update { GossipTimingPolicy.armRound(it, random) } }`; the round reads `val window = timing.read { GossipTimingPolicy.recencyWindow(it) }` where it read `effectiveGossipInterval` and passes it to `GossipPartnerSelector.select(candidates, nowMs, window, random)`. `effectiveGossipInterval` stays for the coordinator's status read.

- [ ] **Step 1: Write the failing engine tests**, beside the "news wakes the round" group, using `wakeHarness`, `awaitWaits`, `awaitRoundBeyond` and a new `private class FloorJitterRandom : Random() { override fun nextBits(bitCount: Int) = 0 }` next to `UnjitteredRandom`. Dart sources to cite: `gossip_engine_pacing_test.dart`, group "GossipEngine recency suppression" (Task 8 adds them there).

```kotlin
@Test fun `a node's own round at the jitter floor is never suppressed on a static interval`()
// createHarness(gossipInterval = 1.seconds, random = FloorJitterRandom()) with one reachable peer and a
// digest-request tap; start; advance 800 ms → 1 request; advance 800 ms → 2 requests (today: still 1).
@Test fun `a node's own round at the jitter floor is never suppressed across a quiet-round growth`()
// wakeHarness(random = FloorJitterRandom()) (adaptive, 1 s base); start; advance 800 ms → round 1 (start's news);
// advance 800 ms → round 2 sends (quiet round grew the interval to 1.5 s; window is still 800 ms);
// advance 1200 ms → round 3 sends. Assert 3 requests and effectiveGossipInterval == 2250 ms (today: 1 request).
@Test fun `a peer's initiative inside the window still suppresses the round`()
// createHarness(gossipInterval = 1.seconds); peer; peerRegistry.updatePeerAntiEntropy(peer, nowMs - 799);
// performGossipRound → no request. And at nowMs - 800 → a request (the >= edge, now on the window).
```

Rename `a round skips a peer whose exchange is fresher than the current interval` → `... fresher than the recency window`.

- [ ] **Step 2: Run** `LANG=C.UTF-8 ./gradlew :test --tests '*.GossipEngineTest'` — expected: the three new tests FAIL on request counts (1 instead of 2, 1 instead of 3, and the 800 ms edge).
- [ ] **Step 3: Implement** the two engine edits and the selector rename; delete the "Read after beginRound" comment and the KDoc sentence on `performGossipRound` that names the interval as the window; the class doc's pacing sentence says the policy arms the round.
- [ ] **Step 4: Run** `LANG=C.UTF-8 ./gradlew :test --tests '*.GossipEngineTest' --tests '*.GossipPartnerSelectorTest' --tests '*architecture*'` — expected: PASS.
- [ ] **Step 5: Commit** `fix(sync): the round's recency window is the jitter floor of the armed interval`.

### Task 4: The pair scenario under real jitter (Kotlin)

**Files:**
- Modify: `src/test/kotlin/com/neutrinographics/gossip/integration/RecencySuppressionTest.kt`

**Interfaces:**
- Consumes: Tasks 1-3 (behavior only).

- [ ] **Step 1: Change the scenario** so the jitter is visible: `runInterleavedRounds` steps 100 ms per node (not 600 ms) for 300 steps (30 s), and the band becomes `observed in 28..32`. Rewrite the KDoc's band derivation: a 600 ms step quantised every wait to 1.2 s and hid the jitter; at 100 ms steps the waits land on 0.8-1.2 s; a 200-seed simulation of the harness's arithmetic gives 23-27 per pair with the full-interval window and 28-30 with the floor window (mean 28.7); 32 is headroom for settle ordering. Keep the interleaving rationale.
- [ ] **Step 2: Run** `LANG=C.UTF-8 ./gradlew :test --tests '*.RecencySuppressionTest'` on the commit before Task 3 (`git stash` is not needed: check out Task 2's commit in a worktree, or temporarily revert Task 3's engine edit) — expected: FAIL below 28. Record the observed figure in the KDoc ("observed N with the full-interval window").
- [ ] **Step 3: Run** it on the current tree — expected: PASS; record the observed figure. Run it three times to confirm it is stable.
- [ ] **Step 4: Commit** `test(integration): the converged pair exchanges once per interval under real jitter`.

### Task 5: Kotlin docs and PR

**Files:**
- Modify: `CLAUDE.md` — the "Pacing and the round scheduler" paragraph gains one sentence: `GossipTimingPolicy.armRound` draws the wait and remembers the interval; `recencyWindow` is that interval's jitter floor, so a round never suppresses its own previous exchange. `GossipPartnerSelector` is already listed.

- [ ] **Step 1: Edit** `CLAUDE.md` as above.
- [ ] **Step 2: Run** `LANG=C.UTF-8 ./gradlew build` — expected: BUILD SUCCESSFUL, suite count ≥ 1488 + the new tests.
- [ ] **Step 3: Commit** `docs: the timing policy owns the round schedule`, push `claude/project-thread-d0wq5r`, open the PR (base: `claude/project-thread-juqoud` while #22 is open, else `main`), titled "Recency window is the jitter floor of the armed interval". Body: the defect in two lines, the shape, the test evidence (Task 4's observed figures), the Dart twin PR link once Task 10 opens it.

## Part 2 — gossip (Dart)

### Task 6: `jitterFloor` and the named fraction (Dart shared kernel)

**Files:**
- Modify: `packages/gossip/lib/src/shared/domain/services/jitter.dart`
- Test: `packages/gossip/test/shared/domain/services/jitter_test.dart`

**Interfaces:**
- Produces: `const double defaultJitterFraction = 0.2;` `Duration jitterFloor(Duration base, {double fraction = defaultJitterFraction})`; `applyJitter`'s named `fraction` defaults to `defaultJitterFraction`. Exported by `shared/shared.dart` through the existing `jitter.dart` export.

- [ ] **Step 1: Write the failing tests** (group `jitterFloor`): the four cases of Task 1 in Dart (`expect(jitterFloor(const Duration(seconds: 1)), const Duration(milliseconds: 800))`; custom fraction 0.1 → 900 ms; zero fraction → base; over 2000 draws `applyJitter(base, rng) >= jitterFloor(base)`; a `Random` whose `nextDouble` is 0 lands `applyJitter` exactly on `jitterFloor`).
- [ ] **Step 2: Run** `cd packages/gossip && dart test test/shared/domain/services/jitter_test.dart` — expected: FAIL, `jitterFloor` undefined.
- [ ] **Step 3: Implement** with `applyJitter`'s rounding: `Duration(microseconds: (base.inMicroseconds * (1 - fraction)).round())`. Doc comment as in Task 1.
- [ ] **Step 4: Run** — expected: PASS.
- [ ] **Step 5: Commit** `feat(shared): name the jitter fraction and add jitterFloor`.

### Task 7: The policy owns the schedule (Dart)

**Files:**
- Modify: `packages/gossip/lib/src/sync/domain/services/gossip_timing_policy.dart`
- Test: `packages/gossip/test/sync/domain/services/gossip_timing_policy_test.dart`

**Interfaces:**
- Consumes: Task 6.
- Produces: `Duration armRound(Random random)` — sets a private `Duration? _armedInterval = effectiveInterval` and returns `applyJitter(_armedInterval!, random)`; `Duration get recencyWindow => jitterFloor(_armedInterval ?? effectiveInterval)`.

- [ ] **Step 1: Write the failing tests** — the five cases of Task 2, in this file's style (a policy over a fake `PeerDirectory` with one partner at 500 ms SRTT so the adaptive base is 1 s; a static-interval policy at 200 ms for the static case). Names: `armRound answers a wait inside the jitter band and remembers the interval it drew from`; `recencyWindow never exceeds any wait armRound can answer`; `quietRound grows the next interval but leaves the armed window alone` (expects 1500 ms interval, 800 ms window); `before any arm the window is the floor of the current interval, static included` (800 ms; 160 ms); `a second arm replaces the armed interval`.
- [ ] **Step 2: Run** `dart test test/sync/domain/services/gossip_timing_policy_test.dart` — expected: FAIL, `armRound` undefined.
- [ ] **Step 3: Implement**; doc comments as in Task 2 (one decision; the wake edge; the fallback).
- [ ] **Step 4: Run** — expected: PASS.
- [ ] **Step 5: Commit** `feat(sync): GossipTimingPolicy arms the round and owns the recency window`.

### Task 8: The engine uses the schedule (Dart)

**Files:**
- Modify: `packages/gossip/lib/src/sync/application/gossip_engine.dart` (`nextDelay` ~line 414; `performGossipRound` ~lines 716-726 and `_staleUncongestedCandidates` ~lines 752-771)
- Create: `packages/gossip/test/support/floor_jitter_random.dart` — `class FloorJitterRandom implements Random` with `nextDouble() => 0.0`, `nextInt`/`nextBool` delegating to `Random(7)` (the `UnjitteredRandom` shape, documented as its floor-draw sibling)
- Test: `packages/gossip/test/sync/application/gossip_engine_pacing_test.dart` (group "GossipEngine recency suppression")

**Interfaces:**
- Consumes: Task 7.
- Produces: `nextDelay: () => _timing.armRound(_random)`; in the round, `final window = _timing.recencyWindow.inMilliseconds;` replaces the `interval` read, and `_staleUncongestedCandidates(reachable, window, nowMs)` takes a `window` parameter.

- [ ] **Step 1: Write the failing tests** in the recency group, driving the loop through `h.timePort.advance` as the "news wakes the round" group does:

```dart
test("a node's own round at the jitter floor is never suppressed on a static interval", ...)
// GossipEngineTestHarness(gossipInterval: 1 s, random: FloorJitterRandom()); one peer; capture; start;
// advance 800 ms + pumpEventQueue → 1 DigestRequest; advance 800 ms → 2 (today: 1).
test("a node's own round at the jitter floor is never suppressed across a quiet-round growth", ...)
// adaptiveTimingEnabled, peer RTT 500 ms, FloorJitterRandom; start; advance 800 → 1; advance 800 → 2;
// advance 1200 → 3; effectiveGossipInterval == 2250 ms (today: 1).
test("a peer's initiative inside the window still suppresses the round", ...)
// static 1 s; updatePeerAntiEntropy(peer, nowMs - 799) → performGossipRound sends nothing;
// then at nowMs - 800 → it sends (the >= edge on the window).
```

Rename `a round skips a peer whose exchange is fresher than the current interval` → `... than the recency window`.

- [ ] **Step 2: Run** `dart test test/sync/application/gossip_engine_pacing_test.dart` — expected: the three new tests FAIL on counts.
- [ ] **Step 3: Implement** the engine edits. Delete the "Deliberate: this reads effectiveGossipInterval AFTER the quietRound()" block and the "Recency suppression (time-based …)" inline comment's interval wording; `performGossipRound`'s doc comment step 1 says "inside the recency window (see `GossipTimingPolicy.recencyWindow`)"; the `nextDelay` comment says the policy arms the round.
- [ ] **Step 4: Run** `dart test test/sync/application/ test/architecture/boundary_test.dart` — expected: PASS.
- [ ] **Step 5: Commit** `fix(sync): the round's recency window is the jitter floor of the armed interval`.

### Task 9: The pair scenario under real jitter (Dart)

**Files:**
- Create: `packages/gossip/test/integration/sync/recency_suppression_test.dart`

**Interfaces:**
- Consumes: `TestNetwork` (`test/support/test_network.dart`): `create`, `connectAll`, `setupChannel`, `startAll`, `runRounds(n, advanceMs: 100)`, `corruptLink(from, to, transform)`; `WireTypes.frameTypeOffset(bytes)` and `WireTypes.digestRequest` (3) to classify a frame.

- [ ] **Step 1: Write the test** `a converged pair exchanges about once per interval under real jitter`: two nodes with a static 1 s `gossipInterval` (see how `TestNetwork.create` passes config; add a parameter if it has none), converge on one entry, tap both directions counting DigestRequests, `runRounds(300, advanceMs: 100)`, `expect(observed, inInclusiveRange(28, 32))`. Doc comment: translation of gossip-kt's `RecencySuppressionTest` with the same band derivation (Task 4).
- [ ] **Step 2: Run** it with Task 8's engine edit temporarily reverted — expected: FAIL below 28; record the figure in the doc comment.
- [ ] **Step 3: Run** on the current tree, three times — expected: PASS, stable; record the figure.
- [ ] **Step 4: Commit** `test(integration): the converged pair exchanges once per interval under real jitter`.

### Task 10: Dart docs, register, PR

**Files:**
- Modify: `packages/gossip/docs/adr/013-adaptive-timing.md` — after "Final-review refinements", add `### Amendment (2026-11-17): the recency window under jitter` — four to six lines: the window is the jitter floor of the interval the pending wait was drawn from, held by the timing policy (`armRound`/`recencyWindow`), so a round never suppresses its own previous exchange and the 30 s + jitter bound above holds; before this the lone-initiator gap averaged 1.5 intervals and reached 2.2.
- Modify: `docs/backlog/kt-normalize-twin-divergences.md` — one register row: "Recency window under jitter | both twins compared a 0.8-1.2x wait against a 1.0x window, and read it after the quiet-round growth | neither — a SHARED gap found by the Fable review of gossip-kt #22 | **Closed (2026-11-17):** both twins' timing policy owns the schedule (`armRound` / `recencyWindow`); gossip PR #N, gossip-kt PR #M".
- Modify: `docs/superpowers/specs/2026-11-17-recency-jitter-window-design.md` — status line gains "built: gossip #N, gossip-kt #M".
- Modify: `docs/roadmap.md` line 224 (item 11): append "Window fixed under jitter 2026-11-17 (both twins)."

- [ ] **Step 1: Make the four edits.**
- [ ] **Step 2: Run** `cd packages/gossip && dart analyze && dart format --set-exit-if-changed lib test && dart test` — expected: clean, all green.
- [ ] **Step 3: Commit** `docs: ADR-013 amendment and register row for the recency window under jitter`, push `claude/project-thread-d0wq5r`, open the PR against `main` titled "Recency window is the jitter floor of the armed interval", body as Task 5's with the Kotlin PR linked; then edit the Kotlin PR body to link back.
