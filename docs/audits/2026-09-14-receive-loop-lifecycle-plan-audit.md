# Audit: the receive-loop lifecycle plan, before execution

**Date:** 2026-09-14. **Scope:** the Kotlin implementation plan
`gossip-kt/docs/superpowers/plans/2026-09-01-kt-receive-loop-lifecycle.md`
(drafted 2026-09-01 against gossip-kt 33772f7) together with the documents
it argues from — the [rulings page](../superpowers/specs/2026-09-01-receive-loop-lifecycle-rulings.md),
the [retirement decision record](../superpowers/specs/2026-09-01-swim-slimdown-decision.md),
the three backlog items it closes, and the
[purification rulings](../superpowers/specs/2026-09-02-kt-domain-purification-rulings.md)
that supersede part of it. Judged against four rubrics the owner named:
logical correctness, domain-driven design, clean architecture, and whether
the batch is the right move toward a faster, more stable deployed fleet and
toward Dart↔Kotlin parity.

**Method:** four read-only deep-readers by territory (the Kotlin
coordinator; the engine, channel service, pusher, codecs, and test harness;
the failure detector, its wrappers, the wire fixtures, and the partition
tests; the Dart reference, the six withheld scenarios, the register, the
parity page, and the roadmap). Every claim below was re-read by the
orchestrator at the cited lines. The Kotlin gate was run: 1046 tests, 0
failures, at gossip-kt 83ec65a. Line numbers are against gossip-kt 83ec65a
and gossip 092c423.

**Outcome:** the owner ruled the four open points on 2026-09-14 (rulings
9–12 on the rulings page, 6 and 7 amended); the plan was rewritten in place
against 83ec65a. This report is the record of what the rewrite fixed.

## Verdict

The batch is the right move. Direction, scope, and layering are sound: it
closes two real Kotlin defects, deletes the only structural stall class in
the server's receive loop, and converges lifecycle vocabulary with Dart.
The rulings page is a good decision record.

The plan document was not executable as written. It was drafted against
gossip-kt 33772f7; two batches merged since. One ruling contradicted
another inside the same plan, one task's red tests could never turn red,
one step would fail the architecture gate, and the doc-truth task would
have written two register rows the owner's own rulings reversed. It also
overrode the Dart-first ordering the roadmap and decision record set. No
Critical: nothing is shipped or broken today. Six Majors and eight
Moderates were fixed before execution.

## Findings

IDs are `LC1-n` for later citation. Severity ladder: Major = a real defect
in what the plan exists to do · Moderate = a structural gap that will bite
during execution · Minor = real, cheap · Observation = recorded, no action.

### Major

- **LC1-1 Ruling 5 reintroduces the awaited gap ruling 9 says does not exist.**
  At HEAD `Coordinator.start()` (Coordinator.kt:341-402) has no suspension
  between its state check and engine start, so ruling 9's premise was true.
  Task T1 then inserted `receiveJob?.cancelAndJoin()` before relaunch,
  which suspends whenever a prior stop left the collector mid-handler, with
  the `isActive` check *before* the suspension. Races at the new gap: two
  concurrent starts both pass the check, both join, both launch — two
  collectors on the unsynchronized merge path, the invariant ruling 1
  protects; a dispose during the join lets start resume on a cancelled
  scope and write RUNNING over DISPOSED; a stop during the join is lost.
  Dart's epoch guard exists for exactly this shape (coordinator.dart:147-153,
  899-913). *Fixed: ruling 7 reversed — the epoch guard is ported; T1 pins
  the stop-wins and dispose-wins cases.*
- **LC1-2 Task T3's red tests were vacuous.** Both pins relied on
  `InMemoryTimePort.close()` cancelling an in-flight round. It does not:
  parked delays are appended to a list and awaited (InMemoryTimePort.kt:144-150);
  `close()` marks the port closed, closes periodic timers, and cancels only
  its own dispatch scope (:241-254). Production loops now run on
  `GenerationScheduler` over `timePort.delay` on the coordinator scope, so
  closing the clock parks them forever and injects nothing. The detector
  pin also called `advanceTime`, which does not exist (`advance`/`advanceMs`,
  :158/:161). The port's own KDoc (:234-239) still described a catch-all in
  the engines' start methods that no longer exists, which is what misled the
  design. *Fixed: the detector pin cancels the detector's own scope while a
  send is wedged; `close()` now cancels parked delays and gets its own pin.*
- **LC1-3 The plan was two batches stale, and following it literally
  broke the architecture gate.** Ruling 2 and T4 step 3 added a
  `synchronized` lock and `@Volatile` fields inside
  `membership/application/FailureDetector.kt`; purification already
  extracted that bookkeeping behind wrappers (FailureDetector.kt:95-108)
  and `LockPlacementTest` fails on those tokens outside an infrastructure
  package (LockPlacementTest.kt:85, 108). Ruling 4's gates read
  `GossipEngine._isRunning`, a field that no longer exists (the flag is
  `isRunning` → `scheduler.isRunning`, GossipEngine.kt:210). T3's nine
  catch-all sites are seven (two scheduler-callback sites gone, three
  moved). Every kt line citation, the branch base, and the baseline count
  were wrong. *Fixed: plan re-baselined on 83ec65a.*
- **LC1-4 Sequencing contradicted the owner's ordering.** The plan said it
  does not wait for the Dart-side relay removal; the roadmap's focus item 4,
  the Kotlin-track line, and the decision record's sequencing all said Dart
  first. Dart has retired nothing (failure_detector.dart:671, 800, 946).
  *Ruled 2026-09-14: Kotlin first (ruling 9); roadmap and decision record
  amended.*
- **LC1-5 The doc-truth task wrote falsehoods.** T6 added a register row
  "relay timeout, queue the port" (voided by ruling 8) and a row "kt start
  doubles as resume, no resume()" (reversed by ruling 3 and parity.md);
  said seven withheld scenarios were translated (six; the seventh is
  obsolete); named a backlog file renamed to the retirement item; and was
  numbered T7 in the table and T6 in the body. Register row 85
  (intermediary selection's home) closes with retirement and was omitted.
  *Fixed: T6 rewritten from the amended rulings.*
- **LC1-6 The pending-ping sender guard gap becomes universal.** T4 said to
  delete "any forwarded-ack allowance"; kt has none. What it lacks is
  Dart's *restriction*: an Ack completes a pending ping only if its sender
  is the probed target (failure_detector.dart:557-568). kt's `handleAck`
  matches by sequence alone (FailureDetector.kt:297-306). After retirement
  every pending ping is direct and the guard is missing on the one path
  that remains. *Ruled: ported (ruling 11); T4 pins it.*

### Moderate

- **LC1-7 Lifecycle calls are multi-threaded and unsynchronized; the plan
  added a second cross-thread field.** `_syncState` is a plain var; the
  server starts on a Ktor application coroutine and stops on the shutdown
  thread (CoordinatorLifecycle.kt:43-54). `@Volatile` is no escape hatch
  under the lock rule. *Ruled: the caller serializes lifecycle calls,
  documented on the class (ruling 10).*
- **LC1-8 "Lifecycle contract = Dart parity" was vocabulary parity.**
  Dart's `pause()` throws unless running and `resume()` unless paused;
  kt's `pause()` had no precondition and the plan's `resume() = start()`
  silently resumed from STOPPED. *Ruled: match Dart (ruling 10).*
- **LC1-9 T1 landed before T3**, so every stop hitting a mid-handler
  cancellation reported a spurious protocol error until T3 (Coordinator.kt:384).
  *Fixed: that one carve-out moved into T1.*
- **LC1-10 T4's deletion scope was incomplete.** One indirect-phase call
  site named, two exist (:247, :388); `sendPingRequests` (:519), the only
  relay-request producer, unlisted; `evaluateProbeOutcome`'s indirect
  parameter becomes a constant; decode-and-ignore dropped the incoming-metrics
  call (:345) pinned by FailureDetectorTest.kt:899; class KDoc, the
  message's relay diagram, log strings, and the timing multiplier's
  rationale all described deleted behavior with no step to rewrite them.
  *Fixed in T4; metrics kept by ruling 12.*
- **LC1-11 Ruling 7's compaction claim was confirmed and understated:** the
  per-stream catch in `compactAll` (ChannelService.kt:329-340) swallows
  cancellation and the loop continues, one storage error per remaining
  stream per tick on a five-minute production timer. *Ruling 6 reworded.*
- **LC1-12 Ruling 4 is exactly Dart's partition, but what Dart leaves
  ungated was unnamed:** anti-entropy bookkeeping on the digest-request
  side and detector contact recording on ping and ack. kt records
  anti-entropy coverage on the response side (GossipEngine.kt:540), so
  gating the merge also gates that bookkeeping. *T6 records the row.*
- **LC1-13 The server's requester role is live today through Dart relays;**
  the decision record's "production evidence" covers only its relay role.
  Kotlin-first removes that rescue path plus the peer-unreachable noise
  phones emit when they cannot reach the target. *Recorded in ruling 9.*
- **LC1-14 Two translation slips:** T2 dropped Dart's assertion that state
  is running after resume (coordinator_lifecycle_test.dart:94-95); T5's
  header claimed the whole Dart churn file is carried (eight tests, six
  after the batch). *Fixed.*

### Minor

- **LC1-15** Codec carve-outs were unreachable: both `decode` methods are
  non-suspend. *Dropped.*
- **LC1-16** Ruling 9's mechanism misnamed: the engine shares the
  `ChannelRepository` instance and reads it live; it never reads
  `ChannelService`. kt has no `removeChannel`. *Reworded.*
- **LC1-17** `start()`'s KDoc would be wrong after T1. *Step added.*
- **LC1-18** Dart citations drifted (the third gate is now at
  gossip_engine.dart:1000). *Refreshed.*

### Observations

- **Performance claim confirmed.** The relay is structurally inert and
  blocks the single collector for the full 500 ms (FailureDetector.kt:357,
  588; Coordinator.kt:503): the Ack it awaits can only arrive through the
  collector it is suspended in. The server's inbound flow has a 256-frame
  buffer with suspend overflow (WebSocketMessagePort.kt:28), so a stalled
  collector backpressures every phone's reader. Retirement deletes the
  stall class. Frequency is low and bursty — a stability win, not the
  traffic win, which the roadmap already orders correctly.
- **The grace window is a blind sleep in both twins** (FailureDetector.kt:426-428;
  failure_detector.dart:678-681). *Ruling 12: kt races the late Ack;
  flow-back candidate.*
- **Unrecorded kt-better divergence:** a kt node serves a channel created
  during a pause immediately; Dart cannot until resume reloads its
  snapshot. *T6 records it.*
- **Cancel-and-join classifies as a kt-better flow-back row**, not an
  exemption. Its Dart value is doubtful: a single isolate delivers nothing
  after cancel, and neither runtime interrupts a handler already in flight.
- **DDD and Clean Architecture.** The gates are use-case policy and belong
  in the application-layer handlers, where Dart keeps them; reading the
  running flag through the synchronized loop generation needs no new
  primitive. The job field and the dispatcher parameter belong in the
  composition root. Retirement is a pure deletion inside membership
  application plus one routing arm; `PingReq` stays in the domain as a
  received-only type, and the wire fixtures require its encoder, which the
  plan keeps. `LockPlacementTest` is the enforcing gate for all of it.

## What is genuinely healthy

The rulings-page-plus-plan split works: the page is short, the decisions
numbered, every amendment dated. The acceptance suite was fixed in advance.
T1 before T2 is load-bearing and ordered correctly (a resume today launches
a second collector). The scenario translations are strictly stronger than
the Dart originals, every DSL call they use exists with the right
signature, and the gate partition is exactly Dart's. The reactive pusher is
already gated on both sides. The single-collector invariant behind parity
exemption E2 is preserved by design.

## Adjusted or discarded claims

No fabricated citations. One reader cited the server's message port at the
wrong path (the file is one directory deeper; the claim holds). Three
readers graded the staleness items as separate Majors; merged into LC1-3.
The doc-truth findings were graded Major individually; merged into LC1-5.
Two readers proposed the codec carve-outs as actionable; graded Minor and
dropped from the plan instead.

## Recommendations (all applied 2026-09-14)

| # | What | Findings |
|---|------|----------|
| R1 | Rule the Dart-first gate | LC1-4, 13 → ruling 9 |
| R2 | Amend the rulings page: resolve 5 vs 9, preconditions and caller-serialization, ack-sender guard, ungated bookkeeping | LC1-1, 6, 7, 8, 12 → rulings 7, 10, 11 |
| R3 | Re-baseline the plan on 83ec65a | LC1-3 |
| R4 | Redesign T3's proof | LC1-2 |
| R5 | Complete T4's deletion list; schedule the comment rewrite; decide on metrics | LC1-10, 11 → ruling 12 |
| R6 | Rewrite T6 from the amended rulings | LC1-5, 14 |
| R7 | Collector carve-out into T1; translation slips; drop codec carve-outs | LC1-9, 14, 15, 17 |

## Coverage

Read in full by the readers: `Coordinator.kt`, `CoordinatorConfig.kt`,
`SyncState.kt`, `CoordinatorTest.kt`, `GenerationScheduler.kt`,
`LoopGeneration.kt`, `SynchronizedLoopGeneration.kt`, `InMemoryMessageBus.kt`,
`InMemoryMessagePort.kt`, `LockPlacementTest.kt`, `GossipEngine.kt`,
`ChannelService.kt`, `ReactivePusher.kt`, `SyncMessageCodec.kt`,
`MembershipMessageCodec.kt`, `Scenario.kt`, `TestNode.kt`,
`GossipTimingPolicy.kt`, `FailureDetector.kt`, `PendingPing.kt`,
`PendingPingRegistry.kt`, `ProbeTargetSelector.kt`, `ProbeTimingPolicy.kt`,
the three membership `Synchronized*` wrappers, `RttTracker.kt`,
`RealTimePort.kt`, `TimePort.kt`, `AsymmetricPartitionTest.kt`, the
decision record, the rulings page, ADR-004, ADR-012, the three backlog
items, `coordinator_lifecycle_test.dart`, and the Dart lifecycle, gate,
and detector sections named above. Read in part: `TestNetwork.kt`,
`InMemoryTimePort.kt`, `FailureDetectorTest.kt`, `FailureDetectionTest.kt`,
`WireGoldenTest.kt`, `WireVectorConformanceTest.kt`, the wire fixtures,
`churn_sync_test.dart`, `test_network.dart`, the register, `parity.md`,
`roadmap.md`. Not covered: the Dart-side retirement design (no plan yet);
the OpenDoor app's peer wiring (the relay-request frequency estimate rests
on the Dart selector rule alone); execution of the translated scenarios.
