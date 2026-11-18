# Digest Scoping Leftovers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the four small items gossip PR #19 left behind — the Dart `pull` flag, value equality on the budgeter's types, channel creation as news on both twins, and three formatter-flagged files — in one gossip PR and one gossip-kt PR.

**Architecture:** No new types. Dart's inbound digest-response path takes over the running gate from the seam it calls; `setChannels` records news when the channel map grows; kt gains `GossipEngine.notifyChannelCreated()` wired from the coordinator's existing domain-event lambda. Everything else is tests, one formatting commit and docs.

**Tech Stack:** Dart 3.10 language level (`packages/gossip`, `dart test`), Kotlin + JUnit 5 (`gossip-kt`, `./gradlew :test`). Dart SDK in this container: `/tmp/claude-0/-home-user/8ea1712e-f8d8-5026-95cf-b453230edbe2/scratchpad/dartsdk/dart-sdk/bin` (3.14.1; put it on `PATH`). The workspace is already resolved in this container with a slimmed root `pubspec.yaml`/`pubspec.lock` (Flutter packages and path overrides dropped; both files are `assume-unchanged` in git — never `git add -A` or commit them). Baseline on main: `dart test` 1530 passing. gossip-kt's Gradle needs `LANG=C.UTF-8`.

**Spec:** `docs/superpowers/specs/2026-11-18-digest-scoping-leftovers-design.md`

**Branches:** gossip `claude/project-thread-22tuwp` (already checked out, at main 94949ae); gossip-kt `claude/project-thread-22tuwp` (already checked out, at main 64c344a).

## Global Constraints

- No wire change; no public API removed except the `pull` named parameter of `GossipEngine.handleDigestResponse` (test seam, not exported from `lib/gossip.dart` — verify before removing).
- Channel removal, pause and resume do not become news (kt pins removal as not news; keep that pin green).
- The formatting commit contains only the three files named in Task 5 and nothing else; run `dart format` with `--language-version=3.10` everywhere, never bare.
- Commit messages: conventional prefix, no model names. Dart tests that translate a kt pin cite it in the test name, as the existing suites do (`(kt GossipEngineTest)`).
- Comments say why, not how.

## Review Focus

1. `setChannels` called with the same map instance or an equal set (coordinator resume path) — must not record news or wake the round. Pinned in Task 3.
2. `setChannels` called with a *smaller* set (removal) — not news. Pinned in Task 3.
3. A channel created while the Dart engine is stopped or paused — `setChannels` is not called by the coordinator then, and resume records news through `start()`; no engine change needed, but the kt `notifyChannelCreated` on a stopped engine must be a no-op. Pinned in Task 6.
4. kt `createChannel` for a channel that already exists emits no `ChannelCreated`, so no news. Pinned in Task 7.
5. The inbound digest response on a stopped Dart engine still learns holdings and sends nothing. Existing pin (`gossip_engine_scoping_test.dart`, "a paused engine still learns holdings…") must stay green in Task 1.

---

### Task 1: Dart — the inbound path gates itself; the seam loses its `pull` flag

**Files:**
- Modify: `packages/gossip/lib/src/sync/application/gossip_engine.dart` (`_onDigestResponse` ~L990–1003, `handleDigestResponse` ~L1215–1237)
- Test: `packages/gossip/test/sync/application/gossip_engine_scoping_test.dart` (existing pin "a paused engine still learns holdings from a response…")

**Interfaces:**
- Produces: `Future<List<PullRequest>> handleDigestResponse(DigestResponse response)` — no named parameters; learns holdings, then plans pulls among held digests, whatever the running state.

- [ ] **Step 1: Confirm the flag's only caller** — `grep -rn "pull:" packages/gossip/lib packages/gossip/test` shows exactly one production call (`_onDigestResponse`) and no test call. Confirm `handleDigestResponse` is not re-exported: `grep -n handleDigestResponse packages/gossip/lib/gossip.dart` is empty.
- [ ] **Step 2: Run the pin that must survive** — `dart test test/sync/application/gossip_engine_scoping_test.dart --name "paused engine still learns"` → PASS (baseline).
- [ ] **Step 3: Rewrite `_onDigestResponse`** so that when `!_scheduler.isRunning` it does `_holdings = _holdings.learn(response.sender, response.namedChannels)` and returns (the comment there already says why: a paused engine serves but does not pull; its names still teach holdings), and otherwise calls `handleDigestResponse(response)` and hands the result to `_sendDeltaRequests`. Remove the `pull` parameter and the `if (!pull) return const [];` line from `handleDigestResponse`; trim its doc comment's "with [pull] false…" clause to say the running gate is the caller's.
- [ ] **Step 4: Run** `dart analyze` (no unused members, no warnings) and `dart test test/sync/application/` → all PASS, the paused-learning pin included.
- [ ] **Step 5: Commit** `refactor(sync): the inbound digest response gates on running itself; handleDigestResponse loses its pull flag`

### Task 2: Dart — value equality on the budgeter's result types, and the rotation pins

**Files:**
- Modify: `packages/gossip/lib/src/sync/application/digest_window.dart` (`Window<T>`), `packages/gossip/lib/src/sync/application/digest_budgeter.dart` (`OversizedDigest`, `FittedRequest`, `FittedResponse`)
- Test: `packages/gossip/test/sync/application/recency_test.dart`, `packages/gossip/test/sync/application/digest_window_test.dart`, `packages/gossip/test/sync/application/digest_budgeter_test.dart`

**Interfaces:**
- Produces: `==`/`hashCode` on `Window<T>` (element-wise over `selected`, `oversized`, plus `usedBytes`), `OversizedDigest`, `FittedRequest`, `FittedResponse` — the same value semantics their kt data-class twins have (`DigestWindow.Window`, `DigestBudgeter.FittedRequest/FittedResponse`, `OversizedDigest`). Use `ListEquality` from `package:collection` only if it is already a dependency of `packages/gossip` (check `pubspec.yaml`); otherwise a short element-wise loop.

- [ ] **Step 1: Write the failing tests.** In `recency_test.dart`, next to the existing hash test: `test('PeerRotation equals by its three lists and hashes alike')` — `PeerRotation(request: one) == PeerRotation(request: same)` is true, `!= PeerRotation(response: one)`, and equal values share a `hashCode`; `test('DigestRotation equals by peer and value, whatever the insertion order')` — two rotations built with `withPeer(n1, …).withPeer(n2, …)` and `withPeer(n2, …).withPeer(n1, …)` are equal; one with a different peer value is not. In `digest_window_test.dart`: `test('a Window is a value: equal selections, oversized lists and byte counts are equal')` with a positive and a negative (`usedBytes` differs) case. In `digest_budgeter_test.dart`: one test each that `FittedRequest`, `FittedResponse` and `OversizedDigest` built twice from the same inputs are equal and hash alike (reuse the file's existing builders).
- [ ] **Step 2: Run** the three files → the new tests FAIL (identity equality).
- [ ] **Step 3: Implement** `operator ==`, `hashCode` on the four classes (`@immutable` where missing; `Object.hashAll` over the lists).
- [ ] **Step 4: Run** the three files → PASS; `dart analyze` clean.
- [ ] **Step 5: Commit** `test(sync): pin PeerRotation and DigestRotation equality; the budgeter's results are values like their kt twins`

### Task 3: Dart — a channel gained by `setChannels` is news

**Files:**
- Modify: `packages/gossip/lib/src/sync/application/gossip_engine.dart` (`setChannels` ~L681)
- Test: `packages/gossip/test/sync/application/gossip_engine_pacing_test.dart`

**Interfaces:**
- Produces: `void setChannels(Map<ChannelId, ChannelAggregate> channels)` — unchanged signature; records news (`_recordNews()`) iff `channels.keys` holds an id absent from the previous `_channels`.

- [ ] **Step 1: Write the failing tests** in the `news` group of `gossip_engine_pacing_test.dart`, modelled on "syncWithPeer (join/reconnect) is news":
  - `test('a channel the engine did not hold is news (kt GossipEngineTest)')`: `pacing harness`, `start`, six `performGossipRound()`, `expect(effectiveGossipInterval, greaterThan(1 s))`; then `h.engine.setChannels({...current, newId: newAggregate})` → `effectiveGossipInterval == 1 s`. Build the aggregate with `ChannelAggregate.create` as `createChannelWithStream` in the harness does, or via `h.createChannel(...)` followed by reading `h.channels` — whichever the harness exposes; check `gossip_engine_test_harness.dart` first.
  - `test('the same channel set is not news')`: same setup, `setChannels` with an equal map → interval still `greaterThan(1 s)`.
  - `test('a smaller channel set (removal) is not news')`: start with two channels, `setChannels` with one → interval unchanged.
  - In the `news wakes the round` group: `test('a created channel wakes the round instead of waiting out the interval armed before it')` — copy the local-write wake test's body, replacing `notifyLocalWrite` with `setChannels` adding a channel; same 199 ms / 1 ms assertions.
- [ ] **Step 2: Run** `dart test test/sync/application/gossip_engine_pacing_test.dart` → the four FAIL (the first and fourth; the two negatives pass already — keep them, they are the pins the Review Focus names).
- [ ] **Step 3: Implement** in `setChannels`: compute `final gained = channels.keys.any((id) => !_channels.containsKey(id));`, assign, then `if (gained) _recordNews();`. Doc comment: a channel this node did not hold is something new to tell peers about, so it resets the pace and wakes a sleeping round; a removal or an equal set is nothing new.
- [ ] **Step 4: Run** the pacing file and `dart test test/sync/application/ test/coordinator/` → PASS.
- [ ] **Step 5: Commit** `feat(sync): a channel gained by setChannels is news — resets the pace and wakes the round`

### Task 4: Dart — the join converges within the active interval; the cap shrinks

**Files:**
- Test: `packages/gossip/test/integration/sync/digest_scoping_test.dart`, `packages/gossip/test/integration/sync/idle_quiescence_test.dart`

- [ ] **Step 1: Measure** — in `digest_scoping_test.dart`, temporarily print the round index at which `awaitConverged(group, entries: 1)` returns in the join test; run the file; note the number (expected: a few rounds, down from ~14).
- [ ] **Step 2: Tighten the pin.** Set `maxRounds` default to the measured count plus a margin of two, and rewrite the helper's doc comment: creating the channel is news on the server, so the first exchange after the join comes within the active interval, not the idle one. Remove the print.
- [ ] **Step 3: Add the coordinator-level pin** in `idle_quiescence_test.dart`, after "deep idle stretches … a write snaps it back": `test('deep idle stretches the gossip interval and creating a channel snaps it back (kt IdleQuiescenceTest)')` — same setup; after the deep-idle assertion, `await network['a'].createChannel(ChannelId('fresh'))` then `expect(network['a'].effectiveGossipInterval!.inSeconds, lessThanOrEqualTo(5))`.
- [ ] **Step 4: Run** `dart test test/integration/sync/digest_scoping_test.dart test/integration/sync/idle_quiescence_test.dart` → PASS; then the whole `dart test` once → all PASS (note the count; main had 1515).
- [ ] **Step 5: Commit** `test(integration): a joined channel converges within the active interval; creating a channel snaps a deep-idle pacer back`

### Task 5: Dart — the formatting-only commit

**Files:**
- Modify (format only): `packages/gossip/lib/src/sync/domain/aggregates/stalled_range_registry.dart`, `packages/gossip/test/sync/application/gossip_engine_stalled_range_test.dart`, `packages/gossip/test/sync/domain/aggregates/stalled_range_registry_test.dart`
- Modify: `docs/backlog/health-format-normalization.md`

- [ ] **Step 1: Check the set** — `cd packages/gossip && dart format --language-version=3.10 --output=none --set-exit-if-changed .` lists exactly those three files (the earlier tasks' edits are already formatted; if a fourth file appears, it is from this branch — format it in its own task's commit instead).
- [ ] **Step 2: Format** the three files with `dart format --language-version=3.10 <files>`; `git diff --stat` shows only them.
- [ ] **Step 3: Run** `dart test test/sync/application/gossip_engine_stalled_range_test.dart test/sync/domain/aggregates/stalled_range_registry_test.dart` → PASS.
- [ ] **Step 4: Commit** `style: format the three files the 3.10 formatter flagged (formatting only)`.
- [ ] **Step 5: Note on the backlog item** — append to `health-format-normalization.md` under "Rough approach": the formatter's output depends on the language version it resolves; without a resolved `.dart_tool` it formats at its own latest version, which reflows 43 files of `packages/gossip` where `--language-version=3.10` (the pubspec's) reflows none after this commit, so the sweep must pin that flag (or resolve packages first). Commit `docs: format-normalization item — pin the language version when the sweep runs`.

### Task 6: kt — `GossipEngine.notifyChannelCreated()`

**Files:**
- Modify: `src/main/kotlin/com/neutrinographics/gossip/sync/application/GossipEngine.kt` (next to `notifyLocalWrite` ~L764)
- Test: `src/test/kotlin/com/neutrinographics/gossip/sync/application/GossipEngineTest.kt` (pacing section ~L3658–3760)

**Interfaces:**
- Produces: `fun notifyChannelCreated()` — non-suspending; `if (!scheduler.isRunning) return; recordNews()`. KDoc: a channel this node just created is something new to tell peers about; the coordinator calls this from the service's event lambda, under the channel lock, so it must return without waiting — `recordNews` updates a cell and asks the scheduler to wake, nothing more.

- [ ] **Step 1: Write the failing tests** in the pacing section: `` fun `a created channel is news`() `` — `pacingHarness()`, `start()`, `repeat(3) { performGossipRound() }`, assert `> 1000 ms`, `notifyChannelCreated()`, `assertEquals(1000.milliseconds, effectiveGossipInterval)`; `` fun `a created channel on a stopped engine is not news`() `` — no `start()`, stretch via rounds, call, interval unchanged; and in the wake section a twin of "a local write wakes the round instead of waiting out the interval armed before it" using `notifyChannelCreated()`.
- [ ] **Step 2: Run** `LANG=C.UTF-8 ./gradlew :test --tests '*GossipEngineTest*created channel*'` → compile FAIL (unresolved reference).
- [ ] **Step 3: Implement** the method.
- [ ] **Step 4: Run** the same filter → PASS; `--tests '*GossipEngineTest*'` → PASS (the "channel removal is NOT news" pin included).
- [ ] **Step 5: Commit** `feat(sync): notifyChannelCreated — a channel this node created is news`

### Task 7: kt — the coordinator turns `ChannelCreated` into news

**Files:**
- Modify: `src/main/kotlin/com/neutrinographics/gossip/coordinator/Coordinator.kt` (`onEvent` lambda ~L444–460)
- Test: `src/test/kotlin/com/neutrinographics/gossip/integration/IdleQuiescenceTest.kt`, `src/test/kotlin/com/neutrinographics/gossip/integration/DigestScopingTest.kt`

**Interfaces:**
- Consumes: `GossipEngine.notifyChannelCreated()` (Task 6), `ChannelCreated` (`sync/domain/events`).

- [ ] **Step 1: Write the failing test** in `IdleQuiescenceTest`, after the write snap-back pin: `` fun `deep idle stretches the gossip interval and creating a channel snaps it back`() `` — same body up to the idle assertion, then `this["node1"].createChannel(ChannelId("fresh"))` and `assertTrue(effectiveGossipInterval() <= 5.seconds)`. Add a second: `` fun `creating a channel that already exists is not news`() `` — after deep idle, `createChannel(channelId)` (the existing one) → interval still `> 10.seconds`.
- [ ] **Step 2: Run** `LANG=C.UTF-8 ./gradlew :test --tests '*IdleQuiescenceTest*'` → the first FAILS, the second passes.
- [ ] **Step 3: Implement** in the `onEvent` lambda: `if (event is ChannelCreated) engineForPush?.notifyChannelCreated()` beside the `EntryAppended` branch; extend the lambda's comment with one line: a created channel is news for the same reason, and the same no-waiting rule binds it.
- [ ] **Step 4: Tighten the join scenario's expectation** — in `DigestScopingTest`, the join test's comment "the pacer has backed off…" (if present in kt's helper) no longer holds; add after `awaitConverged(group, …)` nothing new, but record in the test's comment that the server's `createChannel` is news, so the group converges within the active interval. If `awaitConverged` reports elapsed rounds, assert they are below the pre-change figure the Dart measurement in Task 4 gives (same simulated step); otherwise leave the timeout.
- [ ] **Step 5: Run** `LANG=C.UTF-8 ./gradlew :test --tests '*IdleQuiescenceTest*' --tests '*DigestScopingTest*' --tests '*CoordinatorTest*'` → PASS; then `LANG=C.UTF-8 ./gradlew build` once → PASS (all seven gates included).
- [ ] **Step 6: Commit** `feat(coordinator): a created channel is news — the event lambda wakes the round like a local write`

### Task 8: Docs — close the item, truth the roadmap, register row, changelog

**Files (gossip):**
- Modify: `docs/backlog/engine-channel-creation-is-news.md`, `docs/roadmap.md` (L217 follow-up sentence, L293 item line, item 10's "Next:" which still lists the kt vendoring PR — gossip-kt #21 merged 2026-11-17), `docs/backlog/kt-normalize-twin-divergences.md`, `packages/gossip/CHANGELOG.md`, `docs/superpowers/specs/2026-11-18-digest-scoping-leftovers-design.md` (status line: built, PR numbers once known)

- [ ] **Step 1: Invoke the `roadmap` skill** (project skill) and follow its conventions to mark the channel-creation item ☑ done 2026-11-18 with the gossip and gossip-kt PR numbers (fill in after Task 9 if needed), and to fix item 10's "Next:" (vendoring done in gossip-kt #21; the pin bump remains).
- [ ] **Step 2: Register row** — add under the digest-scoping rows of `kt-normalize-twin-divergences.md`: *Where channel creation becomes news* — Dart: `setChannels` records news when the map gains a channel (the coordinator pushes the map on create/remove while running); kt: `Coordinator`'s event lambda calls `GossipEngine.notifyChannelCreated()` on `ChannelCreated`, since kt engines read the repository and have no `setChannels`. Owner: neither. Leave; same pin on both (deep idle snaps back on create; removal is not news).
- [ ] **Step 3: Changelog** — under `## Unreleased`, in the section the digest-scoping entries use, add: creating a channel is news (resets the pace and wakes the round); `GossipEngine.handleDigestResponse` loses its `pull` parameter (test seam); the budgeter's result types compare by value.
- [ ] **Step 4: Commit** `docs: channel creation is news — item closed, item 10 next-step truthed, register row, changelog`

### Task 9: PRs

- [ ] **Step 1: Push** both branches (`git push -u origin claude/project-thread-22tuwp`, retrying network errors).
- [ ] **Step 2: Open** gossip PR "Digest scoping leftovers: channel creation is news, pull flag, value equality, three formatted files" and gossip-kt PR "A created channel is news" — bodies start with the required attribution lines, link the spec and plan, list the pins, state the test counts; assign `da1nerd`; the review request may be refused for the PR author.
- [ ] **Step 3: Backfill** PR numbers into the roadmap line and the spec status (one small docs commit on the gossip branch), subscribe to both PRs' activity.
