# Dart Relay Retirement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire indirect (relayed) health probing from the Dart core library so its failure detector matches the Kotlin twin: direct probe, grace window that races the late Ack, verdict; relay requests received and ignored; "SWIM" renamed away everywhere the library describes itself.

**Architecture:** All behavior lives in one application service, `FailureDetector` (`packages/gossip/lib/src/membership/application/failure_detector.dart`), plus one domain service method to delete (`ProbeTargetSelector.selectIntermediaries`). The `PingReq` message, its codec, wire type byte, and wire vectors stay untouched (receive forever, send never). Docs and tests follow the code; the ADRs are amended in place; the bookkeeping (roadmap, backlog, divergence register, changelog) ships in the same branch.

**Tech Stack:** Dart 3, `package:test`, Melos monorepo. Run tests from `packages/gossip` with `dart test`; analyze with `dart analyze`; format with `dart format .`.

**Spec:** `docs/superpowers/specs/2026-09-18-dart-relay-retirement-rulings.md` (approved 2026-09-18). The decision record it implements: `docs/superpowers/specs/2026-09-01-swim-slimdown-decision.md`. The Kotlin twin's shape: gossip-kt commits a91404a and 67aa062 (`/Users/joel/git/neutrinographics/gossip-kt`).

## Global Constraints

- Branch off `main`: `git checkout -b feature/retire-indirect-probing`. Baseline: core suite 1274 passing, analyzer clean.
- No timing constant changes: ping-timeout floors/ceilings, the 3× probe-interval multiplier, thresholds 5/15 (config) and 3/9 (detector defaults) all stay.
- No wire change: `PingReq` class, `WireTypes.pingReq = 2`, `MembershipMessageCodec` encode and decode, `test/wire_vectors/**` (including `v1-dart/pingreq.frame` and `v2/pingreq.frame`) are byte-untouched. `packages/gossip/test/wire_vectors/README.md` line 74's mention of `pingreq` stays.
- TDD for every behavior change: write the failing test, run it red, implement, run it green, commit.
- Doc comments explain why, not how (owner rule). Never restate steps.
- Vocabulary after the rename: "failure detection" (mechanism), "the failure detector" (component), "probe" (act), "liveness" (what the sync engine feeds). "SWIM" survives only in: ADR-004's history section, the "incarnation/refutation is deliberately not implemented" note in `updatePeerHealth`'s doc, `shared/domain/services/jitter.dart`'s "standard SWIM practice" citation, and historical records (`docs/audits/**`, `docs/superpowers/plans/**`, `docs/superpowers/specs/**` dated before 2026-09-18, CHANGELOG entries below `## Unreleased`).
- Log prefix: `[SWIM]` → `[FailureDetector]`.
- No `@Deprecated` on `PingReq`.
- Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Every task ends with `dart analyze` clean and `dart test` green in `packages/gossip` before its commit.

---

### Task 1: The grace window races the late Ack; the indirect phase is deleted

**Files:**
- Modify: `packages/gossip/lib/src/membership/application/failure_detector.dart` (the `_PendingPing` doc at 30-58, `_ProbeOutcome` at 60-86, class doc 88-123, `_selector` doc 142-146, `_indirectProbeFanout` 224-227, `performProbeRound` 394-443, `_probeUnreachablePeer` 480-520, `_probe` 623-664, `_performIndirectPing` 666-689, `_awaitAckWithTimeout` 897-907, `_pingExchange` 912-944, `_sendPingRequests` 946-960)
- Modify: `packages/gossip/lib/src/membership/domain/services/probe_target_selector.dart` (class doc 8-12; delete `selectIntermediaries` 209-225; drop the now-unused `dart:math` `min` import only if nothing else uses it — `Random` is still imported from `dart:math`, so the import stays)
- Modify: `packages/gossip/test/membership/application/failure_detector_test.dart`
- Modify: `packages/gossip/test/membership/domain/services/probe_target_selector_test.dart` (delete the `ProbeTargetSelector.selectIntermediaries` group, lines 332-377)
- Delete: `packages/gossip/test/membership/application/failure_detector_recovery_test.dart` (its only test pins recovery through a relay)
- Modify: `packages/gossip/test/membership/application/failure_detector_rtt_test.dart` (rename/re-comment two tests)
- Modify: `packages/gossip/test/membership/application/failure_detector_adaptive_timeout_test.dart` (comment at 186-192)
- Modify: `packages/gossip/test/membership/application/failure_detector_pacing_test.dart` (comment at 65-69)

**Interfaces:**
- Consumes: `FailureDetectorTestHarness` (`test/membership/application/failure_detector_test_harness.dart`): `addPeer`, `expectPing`, `sendAck(peer, sequence, afterDelay:)`, `captureMessages(peer)`, `advancePastTimeout()`, `flush([count])`, `sentMessageCount`, `startListening()/stopListening()`, `timePort`, `peerRegistry`.
- Produces: private `_ProbeOutcome { aliveDirect, aliveLate, failed }`; private `Future<bool> _awaitLateAck(_PendingPing pending, NodeId target)`; `_probe(NodeId)` returning the three-way outcome; `_pingExchange` removed (its one remaining caller, `probeNewPeer`, inlines the exchange). `ProbeTargetSelector` no longer has `selectIntermediaries`. Task 2 relies on `_PendingPing` still having `allowForwarded` after this task (Task 2 removes it).

- [ ] **Step 1: Write the failing race test**

In `packages/gossip/test/membership/application/failure_detector_test.dart`, inside `group('Probe round', ...)`, directly after the test `'late Ack in 2-device scenario (no intermediaries) prevents failure'` (ends near line 357), add:

```dart
    test(
      'a late Ack landing inside the grace window ends the wait at once',
      () async {
        final h = FailureDetectorTestHarness(
          pingTimeout: const Duration(milliseconds: 500),
        );
        final peer = h.addPeer('peer1');
        h.startListening();
        addTearDown(h.stopListening);

        final pingFuture = h.expectPing(peer);
        final probeRoundFuture = h.detector.performProbeRound();
        final ping = await pingFuture;

        // Direct timeout expires; the grace window opens.
        await h.timePort.advance(const Duration(milliseconds: 501));
        await h.flush();

        // The Ack lands 100 ms into the 500 ms window.
        await h.sendAck(
          peer,
          ping.sequence,
          afterDelay: const Duration(milliseconds: 100),
        );

        var completed = false;
        unawaited(probeRoundFuture.then((_) => completed = true));
        await h.flush(3);

        expect(
          completed,
          isTrue,
          reason:
              'the round must return the moment the late Ack lands, not '
              'sleep out the remaining 400 ms of the grace window',
        );
        expect(h.peerRegistry.getPeer(peer.id)!.failedProbeCount, equals(0));
      },
    );
```

Add `import 'dart:async';` at the top of the file if `unawaited` is not already imported (check the existing imports; `dart:async` exports `unawaited`).

- [ ] **Step 2: Run it red**

Run: `cd packages/gossip && dart test test/membership/application/failure_detector_test.dart --name "ends the wait at once"`
Expected: FAIL on `completed` being false (the current code sleeps the full window in `_performIndirectPing`).

- [ ] **Step 3: Write the failing send-never test**

In the same group, directly after the test added in Step 1:

```dart
    test(
      'a failed direct probe sends no relay request even with reachable '
      'third peers',
      () async {
        final h = FailureDetectorTestHarness(
          pingTimeout: const Duration(milliseconds: 500),
        );
        final target = h.addPeer('target');
        final bystander = h.addPeer('bystander');
        h.startListening();
        addTearDown(h.stopListening);

        final (targetMessages, targetSub) = h.captureMessages(target);
        addTearDown(targetSub.cancel);
        final (bystanderMessages, bystanderSub) = h.captureMessages(
          bystander,
        );
        addTearDown(bystanderSub.cancel);

        final round = h.detector.performProbeRound();
        await h.flush();
        await h.advancePastTimeout();
        await round;

        final everything = [...targetMessages, ...bystanderMessages];
        expect(everything.whereType<Ping>(), hasLength(1));
        expect(
          everything.whereType<PingReq>(),
          isEmpty,
          reason: 'send never: a relay request is not part of a probe',
        );
        expect(h.sentMessageCount, equals(1));
      },
    );
```

- [ ] **Step 4: Run it red**

Run: `cd packages/gossip && dart test test/membership/application/failure_detector_test.dart --name "sends no relay request"`
Expected: FAIL: a `PingReq` reaches the bystander and `sentMessageCount` is 2.

- [ ] **Step 5: Implement the grace window and delete the indirect phase**

In `failure_detector.dart`:

(a) Replace the `_ProbeOutcome` enum and its doc (lines 60-86) with:

```dart
/// The classification [FailureDetector._probe] returns for one probe.
///
/// [aliveLate] is kept distinct from [aliveDirect] only so the detector
/// can log the late-Ack case at the point it sees it — a late Ack is the
/// signal that a timeout is running tight. Every caller handles the two
/// alive cases identically.
enum _ProbeOutcome {
  /// The target's Ack answered before the direct timeout.
  aliveDirect,

  /// The target's Ack landed after the direct timeout but inside the grace
  /// window (ADR-012).
  aliveLate,

  /// No Ack arrived before the grace window closed.
  failed,
}
```

(b) Replace the class doc's "Protocol Flow" block (the lines from `/// ## Protocol Flow` through `/// 5. If no Ack, increment failed probe count`, about lines 94-107) with:

```dart
/// ## Protocol Flow
///
/// **Probe Round (adaptive interval)**:
/// 1. Select the next probe target (round-robin over probable peers — see ProbeTargetSelector)
/// 2. Send direct Ping
/// 3. Wait for Ack (per-peer RTT-adaptive timeout)
/// 4. If no Ack, hold the pending ping open for one more timeout — the
///    grace window (ADR-012) — and return the moment a late Ack lands
/// 5. If still no Ack, increment failed probe count
///
/// There is no relayed (indirect) probe: a membership verdict never leaves
/// the node that formed it (ADR-007), so asking a third peer to vouch for
/// a silent one protects nothing — see ADR-004's history.
```

and change the class doc's first two sentences (lines 88-92) to:

```dart
/// Protocol service implementing probe-based failure detection.
///
/// Detects peer failures through periodic direct probing with a graded
/// reachable → suspected → unreachable status.
```

(c) In the `_selector` field doc (lines 142-146) delete the words `indirect-ping intermediary picks, `.

(d) Delete `_indirectProbeFanout` and its doc (lines 224-227).

(e) In `performProbeRound`'s doc, replace steps 4-5 with:

```dart
  /// 4. If no Ack, wait out the grace window for a late Ack
  /// 5. Record a failure only if the window closes empty
```

and replace its outcome switch (from `switch (await _probe(peer.id)) {` through the `_handleProbeFailure(peer.id);` case) with:

```dart
    switch (await _probe(peer.id)) {
      case _ProbeOutcome.aliveDirect:
      case _ProbeOutcome.aliveLate:
        // If something else already called news() earlier in this same
        // round (e.g. a different peer's contact recovering it from
        // suspected), this quietRound() still runs right after — netting
        // a multiplier of 1.5x base rather than staying at 1x. Accepted:
        // it self-corrects, since the next quiet round continues growing
        // from wherever this landed, and the next real news() resets it
        // to 1 regardless. A late Ack is a healthy answer too: its
        // contact was recorded by the Ack handler, so nothing more to do.
        _timing.quietRound();
      case _ProbeOutcome.failed:
        _handleProbeFailure(peer.id);
    }
```

(f) In `_probeUnreachablePeer`, replace the doc paragraph starting `/// Like [probeNewPeer], this is best-effort:` with:

```dart
  /// Like [probeNewPeer], this is best-effort: no failure is recorded on
  /// timeout since the peer is already unreachable. Unlike it, the probe
  /// carries a verdict (recovered or not), so it gets the grace window.
```

and replace the body from the comment `// Indirect ping (inside _probe): ...` through the end of the switch with:

```dart
    switch (await _probe(peer.id)) {
      case _ProbeOutcome.aliveDirect:
      case _ProbeOutcome.aliveLate:
        _log('Unreachable peer ${peer.id} responded — recovered to reachable');
      case _ProbeOutcome.failed:
        _log('Unreachable peer ${peer.id} did not respond (still unreachable)');
    }
```

(g) Replace `_probe` and its doc, and `_performIndirectPing` entirely (lines 623-689), with:

```dart
  /// Probes [target]: a direct Ping, then — if its timeout expires — the
  /// grace window, one more per-peer timeout on the same pending ping.
  ///
  /// Classifies the result as one of [_ProbeOutcome]'s cases and returns —
  /// it does not itself decide what a caller should do about it (pacer
  /// signals, failure bookkeeping). Those differ between
  /// [performProbeRound]'s regular probing and [_probeUnreachablePeer]'s
  /// best-effort recovery probing, so each maps the outcome to its own
  /// policy.
  Future<_ProbeOutcome> _probe(NodeId target) async {
    final sequence = _nextSequence++;
    final pending = _trackPendingPing(target, sequence);
    try {
      await _sendPing(target, sequence);

      final gotDirectAck = await _awaitAckWithTimeout(
        pending,
        effectivePingTimeoutForPeer(target),
      );
      if (gotDirectAck) return _ProbeOutcome.aliveDirect;

      if (await _awaitLateAck(pending, target)) {
        _log(
          'Late Ack arrived for seq=$sequence from $target '
          'within the grace window',
        );
        return _ProbeOutcome.aliveLate;
      }
      return _ProbeOutcome.failed;
    } finally {
      // Late-Ack grace invariant: the pending entry must stay matchable
      // through the grace window, or a late Ack finds nothing to complete
      // and is silently lost. So cleanup spans both waits.
      _cleanupPendingPing(sequence);
    }
  }

  /// The grace window after a direct timeout (ADR-012): the pending ping
  /// stays open for one more per-peer timeout so a slightly-late Ack still
  /// counts. Returns true the moment such an Ack lands, false when the
  /// window closes empty. Re-reads the timeout at entry so a fresh RTT
  /// sample is honored.
  Future<bool> _awaitLateAck(_PendingPing pending, NodeId target) =>
      _awaitAckWithTimeout(pending, effectivePingTimeoutForPeer(target));
```

(h) In `_awaitAckWithTimeout` (lines 897-907) add the fast path so an Ack that landed exactly at the boundary is honored at grace entry:

```dart
  /// Races Ack arrival against timeout. Returns true if Ack won.
  ///
  /// Does NOT remove the pending ping on timeout — late Acks can still
  /// be matched. Caller must clean up via [_cleanupPendingPing].
  Future<bool> _awaitAckWithTimeout(
    _PendingPing pending,
    Duration timeout,
  ) async {
    if (pending.completer.isCompleted) return true;
    final timeoutFuture = _timePort.delay(timeout).then((_) => false);
    return Future.any([pending.completer.future, timeoutFuture]);
  }
```

(i) Delete `_pingExchange` and its doc (lines 912-944) and `_sendPingRequests` (946-960). Rewrite `probeNewPeer`'s body so it performs the exchange itself:

```dart
  Future<bool> probeNewPeer(NodeId peerId) async {
    _timing.news();
    final peer = peerRegistry.getPeer(peerId);
    if (peer == null) return false;

    final sequence = _nextSequence++;
    final pending = _trackPendingPing(peerId, sequence);
    final bool gotAck;
    try {
      await _sendPing(peerId, sequence);
      gotAck = await _awaitAckWithTimeout(
        pending,
        effectivePingTimeoutForPeer(peerId),
      );
    } finally {
      _cleanupPendingPing(sequence);
    }

    if (gotAck) {
      _log('probeNewPeer got Ack from $peerId');
    } else {
      _log('probeNewPeer timed out for $peerId (no failure recorded)');
    }
    return gotAck;
  }
```

and change its doc's last sentence of the first paragraph from `No indirect ping is attempted.` to `No grace window either: with no verdict to protect, a late first sample is simply the next probe's.`

(j) Remove the `import 'package:gossip/src/membership/domain/entities/peer.dart';` line only if `Peer` is no longer referenced in the file (it is: `nextProbeTarget()` returns `Peer?`, so the import stays). Remove nothing else yet; `ping_req.dart` is still imported for the dispatcher until Task 2.

In `probe_target_selector.dart`: delete `selectIntermediaries` and its doc (lines 209-225), and rewrite the class doc's first sentence (lines 8-12) to:

```dart
/// Owns the failure detector's probe-target selection policy: which peer
/// to ping next, which peer is due for the periodic unreachable-recovery
/// probe, and the startup grace period that excludes a peer from probing
/// altogether.
```

- [ ] **Step 6: Delete and rewrite the tests that pin the indirect phase**

In `failure_detector_test.dart`:
- Delete the test `'indirect ping success prevents probe failure'` (lines 359-419).
- Delete the test `'recovers unreachable peer via indirect ping through intermediary'` (lines 965-1052).
- Rewrite the test `'late Ack arriving during indirect ping phase prevents failure'` (lines 260-321): rename it to `'late Ack arriving inside the grace window prevents failure (three peers)'`, rename the local `intermediary` to `bystander` (both the variable and the `'intermediary'` peer name), change the comment `// Advance past direct timeout → indirect ping phase` to `// Advance past the direct timeout → grace window`, change `// Send "late" Ack during indirect phase` to `// Send the late Ack inside the grace window`. The body's logic (whichever peer got the Ping answers late) stays.
- In the test `'late Ack in 2-device scenario (no intermediaries) prevents failure'` rename it to `'late Ack in the grace window prevents failure (two peers)'` and change the comments `// Advance past direct timeout → grace period` → `// Advance past the direct timeout → grace window` and `// Send "late" Ack during grace period` → `// Send the late Ack inside the grace window`; the expectation reason `'Late Ack during grace period should prevent failure'` → `'a late Ack inside the grace window is a healthy answer'`.
- Remove the `import 'package:gossip/src/membership/domain/messages/ping_req.dart';` line from this file only if no remaining test references `PingReq` (the send-never test from Step 3 does, so keep it).

Delete the file `packages/gossip/test/membership/application/failure_detector_recovery_test.dart`.

In `probe_target_selector_test.dart` delete the group `'ProbeTargetSelector.selectIntermediaries'` (lines 332-377).

In `failure_detector_rtt_test.dart`:
- Rename `'records RTT for late Ack that arrives during indirect phase'` (line 198) to `'records RTT for a late Ack that arrives inside the grace window'`; change the comment `// Send the late direct Ack during the indirect phase` to `// Send the late Ack inside the grace window` and `// Finish the indirect phase` to `// Close the grace window`.
- Rename `'does not perform indirect ping'` (line 129) to `'sends exactly one Ping and nothing to any other peer'`; keep its body.
- In `'rejects a direct-probe Ack from a peer other than the target'` change the comment at lines 165-168 to:

```dart
        // Ack from the WRONG peer with a colliding sequence. Only the probed
        // target may confirm its own ping; accepting this would mark a
        // possibly-dead peerA alive and pollute its RTT estimate with
        // peerB's sample.
```

In `failure_detector_adaptive_timeout_test.dart` replace the comment at lines 186-192 with:

```dart
      // Nobody ever sends an Ack. Advance past the per-peer timeout floor
      // (500ms) for the direct wait, then past the same floor again for
      // the grace window -- ~1000ms total. If the round were still gated
      // on the ~1500ms global timeout instead, it would still be waiting
      // after this, and the assertion below would go red rather than
      // merely stay green by coincidence.
```

In `failure_detector_pacing_test.dart` replace the comment at lines 65-69 with:

```dart
      // Second round of the cycle is guaranteed to land on deadpeer: a
      // genuine miss (direct probe times out, then the grace window closes
      // empty). Drive both waits explicitly.
```

- [ ] **Step 7: Run the membership suite green**

Run: `cd packages/gossip && dart analyze && dart test test/membership`
Expected: analyzer clean; all pass, including the two new tests.

- [ ] **Step 8: Run the whole suite**

Run: `cd packages/gossip && dart test`
Expected: green except `test/integration/adverse/asymmetric_partition_test.dart` `'indirect probing through the relay keeps both views reachable'`, which now fails (it pins removed behavior; Task 3 replaces it) — and possibly tests in `failure_detector_error_handling_test.dart` under `group('Intermediary role')` if their timing changed; Task 2 removes that group. Record any other failure and fix it before committing; there should be none.

- [ ] **Step 9: Commit**

```bash
git add -A packages/gossip
git commit -m "refactor(membership): the grace window races the late Ack; delete the indirect probe phase

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Relay requests are decoded and ignored; the ack-sender guard is unconditional

**Files:**
- Modify: `packages/gossip/lib/src/membership/application/failure_detector.dart` (`_PendingPing` 30-58, `handleAck` 536-575, `_dispatchProtocolMessage` 753-781, `_handlePingReq` 799-833, `_recordRtt` 835-869, `_trackPendingPing` 871-883)
- Modify: `packages/gossip/test/membership/application/failure_detector_error_handling_test.dart` (replace `group('Intermediary role', ...)`, lines 24-~245)
- Delete: `packages/gossip/test/membership/application/failure_detector_intermediary_timeout_test.dart`
- Modify: `packages/gossip/test/membership/application/failure_detector_test_harness.dart` (docs at 209, 304-306, 396-397, 432)

**Interfaces:**
- Consumes: `_ProbeOutcome`/`_probe` from Task 1; harness `sendPingReq(sender, target, sequence:)` (kept), `captureMessages`, `errors`, `sentMessageCount`.
- Produces: private `void _ignoreRelayRequest(PingReq pingReq, NodeId requester)`; `_PendingPing` without `allowForwarded`; `_trackPendingPing(NodeId target, int sequence)` with no named parameter.

- [ ] **Step 1: Write the failing ignore test**

In `failure_detector_error_handling_test.dart`, replace the whole `group('Intermediary role', ...)` (from line 24 to the closing `});` of that group, just before `group('Error handling', ...)` at line 246) with:

```dart
  group('Relay requests from older peers', () {
    test('an inbound PingReq is decoded and ignored', () async {
      final h = FailureDetectorTestHarness(
        localName: 'local',
        pingTimeout: const Duration(milliseconds: 500),
      );
      final requester = h.addPeer('requester');
      final target = h.addPeer('target');
      h.startListening();
      addTearDown(h.stopListening);

      final (requesterMessages, requesterSub) = h.captureMessages(requester);
      addTearDown(requesterSub.cancel);
      final (targetMessages, targetSub) = h.captureMessages(target);
      addTearDown(targetSub.cancel);
      final contactBefore = h.peerRegistry.getPeer(requester.id)!.lastContactMs;

      await h.sendPingReq(requester, target, sequence: 42);
      // Long enough for the old relay's own probe timeout to have fired.
      await h.timePort.advance(const Duration(seconds: 3));
      await h.flush(3);

      expect(targetMessages, isEmpty, reason: 'no probe is relayed');
      expect(requesterMessages, isEmpty, reason: 'no Ack is forwarded');
      expect(h.sentMessageCount, equals(0));
      expect(h.errors, isEmpty, reason: 'an ignored frame is not an error');
      expect(
        h.peerRegistry.getPeer(requester.id)!.lastContactMs,
        equals(contactBefore),
        reason: 'a relay request is not proof the sender can hear us',
      );
    });
  });
```

Remove the now-unused `codec` local at the top of `main()` (line 22, `final codec = MembershipMessageCodec(...)`) only if no other group in the file uses it; run the analyzer to find out. Keep the `PingReq` import only if still referenced (it is not, after this replacement — remove it and any other import the analyzer flags as unused).

- [ ] **Step 2: Run it red**

Run: `cd packages/gossip && dart test test/membership/application/failure_detector_error_handling_test.dart --name "decoded and ignored"`
Expected: FAIL: the target receives a `Ping` and `sentMessageCount` is 1.

- [ ] **Step 3: Implement count-and-ignore and the unconditional guard**

In `failure_detector.dart`:

(a) Replace `_PendingPing` (lines 30-58) with:

```dart
/// Tracks a pending ping awaiting its Ack.
///
/// Matched to an incoming Ack by sequence number, and only when that Ack's
/// sender is [target]: a stale Ack with a colliding sequence from an
/// unrelated peer must not mark a possibly-dead target alive. The
/// [completer] resolves to true when the Ack arrives.
class _PendingPing {
  final NodeId target;
  final int sequence;
  final int sentAtMs;
  final Completer<bool> completer;

  _PendingPing({
    required this.target,
    required this.sequence,
    required this.sentAtMs,
  }) : completer = Completer<bool>();
}
```

(b) Replace `handleAck`'s doc and the guard (lines 536-575) with:

```dart
  /// Handles incoming Ack: updates peer contact and records RTT.
  ///
  /// Acks that don't match a pending ping are silently ignored. This is
  /// normal when a very-late Ack arrives after the grace window closed.
  /// The sender's contact timestamp is updated regardless: an Ack is proof
  /// of life for whoever sent it, even when it confirms no probe.
  @visibleForTesting
  void handleAck(Ack ack, {required int timestampMs}) {
    _recordPeerContact(ack.sender, timestampMs);

    final pending = _pendingPings[ack.sequence];
    if (pending == null || pending.completer.isCompleted) {
      return;
    }

    // Only the probed target may confirm its own ping: a stale Ack with a
    // colliding sequence from an unrelated peer (e.g. after a detector
    // rebuild reset the sequence counter) must not mark a possibly-dead
    // target alive.
    if (ack.sender != pending.target) {
      _log(
        'Ignoring Ack seq=${ack.sequence} from ${ack.sender}: '
        'pending ping targets ${pending.target}',
      );
      return;
    }

    _recordRtt(pending, timestampMs);
    pending.completer.complete(true);
  }
```

(c) In `_dispatchProtocolMessage` replace `await _handlePingReq(protocolMessage, sender);` with `_ignoreRelayRequest(protocolMessage, sender);`.

(d) Replace `_handlePingReq` and its doc (lines 799-833) with:

```dart
  /// A relay request from a peer still running the retired indirect-probing
  /// protocol. Nothing happens beyond a log line: a membership verdict
  /// never leaves the node that formed it (ADR-007), so probing a third
  /// peer on someone else's behalf protected nothing. The frame is not
  /// proof the sender can hear us either, so it records no contact.
  void _ignoreRelayRequest(PingReq pingReq, NodeId requester) {
    _log('Ignoring PingReq from $requester target=${pingReq.target}');
  }
```

(e) Replace `_recordRtt` (lines 835-869) with:

```dart
  /// Records an RTT sample from a matched Ack, attributed to the probed
  /// target — which the sender guard in [handleAck] makes the same node as
  /// the Ack's sender.
  ///
  /// All valid RTT samples are recorded regardless of whether they exceeded
  /// the timeout. Unlike TCP (where Karn's algorithm avoids ambiguity between
  /// original and retransmitted segments), probe pings have unique sequence
  /// numbers so every Ack is unambiguously matched. Recording all samples
  /// lets the EWMA adapt upward when latency increases, preventing a
  /// survivorship bias where only fast samples feed the estimate.
  void _recordRtt(_PendingPing pending, int timestampMs) {
    final rttMs = timestampMs - pending.sentAtMs;

    if (rttMs <= 0) return;

    final rttSample = clampDuration(
      Duration(milliseconds: rttMs),
      min: RttTracker.minSample,
      max: RttTracker.maxSample,
    );

    _rttTracker.recordSample(rttSample);
    peerRegistry.recordPeerRtt(pending.target, rttSample);
    _log(
      'Ack seq=${pending.sequence} from ${pending.target} (RTT: ${rttMs}ms)',
    );
  }
```

(f) Replace `_trackPendingPing` (lines 871-883) with:

```dart
  _PendingPing _trackPendingPing(NodeId target, int sequence) {
    final pending = _PendingPing(
      target: target,
      sequence: sequence,
      sentAtMs: _timePort.nowMs,
    );
    _pendingPings[sequence] = pending;
    return pending;
  }
```

(g) Run `dart analyze` and remove any import the analyzer now reports unused (`peer.dart` stays; `ping_req.dart` stays because `_ignoreRelayRequest` names the type).

- [ ] **Step 4: Delete the intermediary-timeout test file and update the harness docs**

Delete `packages/gossip/test/membership/application/failure_detector_intermediary_timeout_test.dart`.

In `failure_detector_test_harness.dart`:
- Line 209: `/// Number of messages the local detector has sent (Ping/Ack/PingReq),` → `/// Number of messages the local detector has sent (Ping/Ack),`.
- Lines 304-306: replace the three-line doc sentence `Does not respond to [PingReq] — this peer is a dumb auto-responder, not a full detector, so it never acts as an indirect-probe intermediary.` with `/// Answers Pings only — this peer is a dumb auto-responder, not a full detector.`
- Lines 396-397: `/// Sends a [PingReq] from [sender] to the local detector, requesting it probe [target].` → `/// Sends a [PingReq] from [sender] to the local detector, as a peer on the retired relay protocol would. The detector ignores it; tests pin that.`
- Line 432: `/// backs [sendAck], [sendPing], and [sendPingReq]` — unchanged (all three still exist).

- [ ] **Step 5: Run green**

Run: `cd packages/gossip && dart analyze && dart test test/membership`
Expected: analyzer clean; all pass, including `'an inbound PingReq is decoded and ignored'` and the existing `'rejects a direct-probe Ack from a peer other than the target'`.

- [ ] **Step 6: Commit**

```bash
git add -A packages/gossip
git commit -m "refactor(membership): decode and ignore relay requests; the ack-sender guard is unconditional

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: End-to-end pins — ignored relay through the coordinator, honest degradation with a third node

**Files:**
- Create: `packages/gossip/test/coordinator/coordinator_relay_request_test.dart`
- Modify: `packages/gossip/test/integration/adverse/asymmetric_partition_test.dart`

**Interfaces:**
- Consumes: `TestNetwork` (`test/support/test_network.dart`): `create(names, config:)`, `connectAll()`, `startAll()`, `dispose()`, `runRounds(n, advanceMs:)`, `partitionOneWay(from, to)`, `healOneWay`, `setupChannel`, `hasConverged`, `operator []` → `TestNode` with `.id`, `.coordinator` (`errors` stream, `peerStatus`), `.messagePort` (`InMemoryMessagePort`: `send(dest, bytes)`, `incoming`). `MembershipMessageCodec(wireVersion: WireVersion.v1)`. `CoordinatorConfig(gossipInterval:, probeInterval:, suspicionThreshold:, unreachableThreshold:)`.
- Produces: nothing downstream.

- [ ] **Step 1: Write the coordinator-level ignore pin**

Create `packages/gossip/test/coordinator/coordinator_relay_request_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:gossip/src/coordinator/coordinator_config.dart';
import 'package:gossip/src/membership/domain/messages/ack.dart';
import 'package:gossip/src/membership/domain/messages/ping_req.dart';
import 'package:gossip/src/membership/infrastructure/membership_message_codec.dart';
import 'package:gossip/src/shared/domain/errors/sync_error.dart';
import 'package:gossip/src/shared/domain/interfaces/message_port.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_version.dart';

import '../support/test_network.dart';

/// The receive-only contract the mixed fleet relies on: a relay request
/// from a peer on an older build is decoded by the real coordinator and
/// codec, and produces no frame back and no error.
void main() {
  test('an inbound relay request is decoded and ignored end to end', () async {
    // Periodic loops parked far past the test horizon so the only traffic
    // after settling is what the relay request itself would cause.
    final network = await TestNetwork.create(
      ['nodeA', 'requester', 'target'],
      config: const CoordinatorConfig(
        gossipInterval: Duration(hours: 1),
        probeInterval: Duration(hours: 1),
      ),
    );
    addTearDown(network.dispose);
    await network.connectAll();
    await network.startAll();
    // Let the connect-time bootstrap probes and their Acks settle.
    await network.runRounds(3, advanceMs: 2000);

    final nodeA = network['nodeA'];
    final requester = network['requester'];
    final target = network['target'];

    final errors = <SyncError>[];
    final errorSub = nodeA.coordinator.errors.listen(errors.add);
    addTearDown(errorSub.cancel);
    final toRequester = <IncomingMessage>[];
    final requesterSub = requester.messagePort.incoming.listen(toRequester.add);
    addTearDown(requesterSub.cancel);
    final toTarget = <IncomingMessage>[];
    final targetSub = target.messagePort.incoming.listen(toTarget.add);
    addTearDown(targetSub.cancel);

    final codec = MembershipMessageCodec(wireVersion: WireVersion.v1);
    await requester.messagePort.send(
      nodeA.id,
      codec.encode(PingReq(sender: requester.id, sequence: 7, target: target.id)),
    );
    await network.runRounds(3, advanceMs: 2000);

    final forwardedAcks = toRequester
        .map((m) => codec.decode(m.bytes))
        .whereType<Ack>()
        .where((ack) => ack.sequence == 7);
    expect(forwardedAcks, isEmpty, reason: 'no Ack is forwarded back');
    expect(
      toTarget.where((m) => m.sender == nodeA.id),
      isEmpty,
      reason: 'no probe is relayed to the target',
    );
    expect(errors, isEmpty);
  });
}
```

- [ ] **Step 2: Run it**

Run: `cd packages/gossip && dart test test/coordinator/coordinator_relay_request_test.dart`
Expected: PASS (Task 2 already shipped the behavior; this pin proves it through the real coordinator and codec). If it fails because a periodic probe from nodeA still reaches the target during the settle, raise `probeInterval` handling by asserting on `Ping` frames only within the 3 rounds after the request — but first confirm that the frame is a probe, not a relay: a relayed Ping would be followed by an `Ack(sequence: 7)` to the requester, which the first assertion already excludes. Do not weaken the first assertion.

- [ ] **Step 3: Rewrite the asymmetric-partition suite**

In `packages/gossip/test/integration/adverse/asymmetric_partition_test.dart`:

(a) Replace the file doc (lines 9-18) with:

```dart
/// Asymmetric (one-way) partition scenarios.
///
/// The link condition throughout is `partitionOneWay('nodeB', 'nodeA')`:
/// nodeA can send to nodeB, but everything nodeB sends to nodeA is lost.
/// nodeA is the "one-way-deaf" node — it never hears nodeB directly.
///
/// There is no relayed probing: a third node connected to both sides
/// cannot vouch for the pair, so the deaf node degrades honestly and marks
/// its peer suspected, then unreachable — while entries keep converging
/// through the third node, and the pair recovers after the heal.
```

(b) Rename the first group from `'With relay (nodeC connected to both sides)'` to `'With a third node connected to both sides'`, give its `setUp` the fast-verdict config (the same one the deaf-pair group uses):

```dart
      setUp(() async {
        network = await TestNetwork.create(
          ['nodeA', 'nodeB', 'nodeC'],
          config: const CoordinatorConfig(
            suspicionThreshold: 3,
            unreachableThreshold: 6,
          ),
        );
        await network.connectAll();
        await network.setupChannel(channelId, streamId);
        await network.startAll();
      });
```

(c) Replace the test `'indirect probing through the relay keeps both views reachable'` (its whole body, lines 34-84) with:

```dart
      test(
        'the deaf node suspects its peer even though a third node could '
        'have vouched for it',
        () async {
          await network.runRounds(5);
          expect(
            network['nodeA'].peerStatus(network['nodeB'].id),
            equals(PeerStatus.reachable),
          );

          // nodeA stops hearing nodeB directly. Its Pings still reach
          // nodeB, but every Ack back is lost; each probe times out
          // through the grace window and records a failure. nodeC is not
          // asked to relay anything.
          network.partitionOneWay('nodeB', 'nodeA');
          await network.runRounds(80);

          expect(
            network['nodeA'].peerStatus(network['nodeB'].id),
            anyOf(equals(PeerStatus.suspected), equals(PeerStatus.unreachable)),
            reason: 'a silent direct link is reported as such — honestly',
          );
          // The third node talks to both sides directly and stays healthy
          // in everyone's view.
          expect(network['nodeC'].reachablePeers.length, equals(2));
          expect(
            network['nodeA'].peerStatus(network['nodeC'].id),
            equals(PeerStatus.reachable),
          );
          expect(
            network['nodeB'].peerStatus(network['nodeC'].id),
            equals(PeerStatus.reachable),
          );
        },
      );
```

(d) Keep `'state converges through the relay while the block is active'` as is, but rename it to `'state converges through the third node while the block is active'` and change the comment line `// A direct A↔B gossip exchange can never complete` block's wording `but nodeC is bidirectionally connected to` — unchanged; only the test name changes.

(e) In the deaf-pair group's first test, replace the comment at lines 174-177 (`// nodeA becomes deaf to nodeB. ... records a failure on nodeA.`) with:

```dart
        // nodeA becomes deaf to nodeB. nodeA's Pings still reach nodeB,
        // but every Ack back is lost, so each probe times out through the
        // grace window and records a failure on nodeA.
```

- [ ] **Step 4: Run the suite**

Run: `cd packages/gossip && dart test test/integration/adverse/asymmetric_partition_test.dart`
Expected: PASS, four tests. If the new degradation test's status assertion fails because nodeA's freshness suppression keeps skipping nodeB (nodeB's own Pings to nodeA are blocked, so this should not happen), raise the round count to 120 and note it in the test comment; do not loosen the assertion.

- [ ] **Step 5: Run the whole suite and commit**

Run: `cd packages/gossip && dart analyze && dart test`
Expected: analyzer clean, all green.

```bash
git add -A packages/gossip
git commit -m "test: pin the ignored relay request end to end and the honest one-way-deaf degradation with a third node

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Library docs for the retired wire type and the remaining comments that credit relays

**Files:**
- Modify: `packages/gossip/lib/src/membership/domain/messages/ping_req.dart` (whole doc)
- Modify: `packages/gossip/lib/src/membership/domain/messages/ping.dart` (doc lines 8-11)
- Modify: `packages/gossip/lib/src/membership/domain/aggregates/peer_registry.dart` (lines 24, 193)
- Modify: `packages/gossip/lib/src/membership/domain/events/membership_events.dart` (line 39)
- Modify: `packages/gossip/lib/src/membership/domain/services/probe_timing_policy.dart` (lines 90-96)
- Modify: `packages/gossip/lib/src/membership/infrastructure/membership_message_codec.dart` (lines 12-13)
- Modify: `packages/gossip/lib/src/shared/domain/interfaces/protocol_message.dart` (line 7)
- Modify: `packages/gossip/lib/src/sync/application/gossip_engine.dart` (lines 177, 856)
- Modify: `packages/gossip/docs/adr/010-ddd-layered-architecture.md` (line 158)

**Interfaces:** none; documentation only. `dart analyze` and `dart test` must stay green.

- [ ] **Step 1: Rewrite the `PingReq` doc**

Replace the class doc in `ping_req.dart` (everything above `class PingReq`) with:

```dart
/// A relay request from the retired indirect-probing protocol.
///
/// Still decoded because deployed peers on older builds send it; this
/// library never sends one and ignores those it receives. The type stays
/// in the wire vocabulary (type byte 2, and the `pingreq` conformance
/// vectors) until the next dialect revision retires the encoder — see the
/// retirement decision record in `docs/superpowers/specs/`.
```

and the field docs to:

```dart
  /// Sequence number the requester would have matched a forwarded Ack to.
  final int sequence;

  /// The node the requester wanted probed on its behalf.
  final NodeId target;
```

- [ ] **Step 2: Fix every comment that still credits a relay**

- `ping.dart` lines 8-11: replace `If no Ack is received within the timeout period, the failure detector initiates an indirect probe via PingReq to distinguish between target failure and network partition.` with `If no Ack is received within the timeout, the failure detector holds the ping open for one more timeout (the grace window) before counting a failure.`
- `peer_registry.dart` line 24: `2. **suspected** → **unreachable**: After indirect probe also fails` → `2. **suspected** → **unreachable**: After further consecutive probe failures`. Line 193: `- suspected → unreachable (after indirect probe fails)` → `- suspected → unreachable (after further probe failures)`.
- `membership_events.dart` line 39: `- suspected → unreachable (indirect probe also failed)` → `- suspected → unreachable (further probe failures)`; line 40 `(peer recovered or refuted suspicion)` → `(peer answered again)`.
- `probe_timing_policy.dart` lines 90-96: replace the doc with:

```dart
  /// Effective probe interval (time between probe rounds).
  ///
  /// Computed as 3x the effective ping timeout — room for the direct probe
  /// and its grace window, plus slack — then paced: quiet (all-answered)
  /// rounds stretch this toward [_maxProbeInterval]; a miss or membership
  /// change snaps it back to the formula's raw value. A static override
  /// bypasses the pacer entirely.
```

- `membership_message_codec.dart` lines 12-13: `/// Wire codec for the membership context's SWIM messages: [Ping], [Ack], [PingReq] — [WireTypes.membership] type bytes 0-2.` → `/// Wire codec for the membership context's messages: [Ping], [Ack], and the retired-but-still-decoded [PingReq] — [WireTypes.membership] type bytes 0-2.`
- `protocol_message.dart` line 7: `/// - **SWIM messages**: Failure detection (Ping, Ack, PingReq)` → `/// - **Membership messages**: Failure detection (Ping, Ack; PingReq is received-only)`.
- `gossip_engine.dart` lines 177 and 856: `Ping/Ack/PingReq` → `Ping/Ack` in both.
- `010-ddd-layered-architecture.md` line 158: `decodes \`Ping\`/\`Ack\`/\`PingReq\` — wire type bytes 0-2.` → `decodes \`Ping\`/\`Ack\`/\`PingReq\` (the last received-only since the relay retirement) — wire type bytes 0-2.`

- [ ] **Step 3: Verify nothing outside the allowed list still says "indirect" or "intermediar"**

Run: `cd packages/gossip && grep -rn -i 'indirect\|intermediar' lib test | grep -v 'ping_req.dart'`
Expected: no output except `lib/src/membership/application/failure_detector.dart` lines that say "no relayed (indirect) probe" (the class doc) and the send-never test's name. Fix any other hit.

- [ ] **Step 4: Analyze, test, commit**

Run: `cd packages/gossip && dart analyze && dart test`
Expected: clean, green.

```bash
git add -A packages/gossip
git commit -m "docs(membership): PingReq is a retired, received-only relay request; comments stop crediting relays

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Amend ADR-004 and ADR-012 in place

**Files:**
- Modify: `packages/gossip/docs/adr/004-swim-failure-detection.md` (whole file)
- Modify: `packages/gossip/docs/adr/012-swim-late-ack-handling.md` (whole file)
- Modify: `packages/gossip/docs/adr/README.md` (lines 16, 24)
- Modify: `CLAUDE.md` (line 152)

**Interfaces:** none. File names keep their numbers and slugs (ruling 7).

- [ ] **Step 1: Rewrite ADR-004**

Replace the whole file with:

````markdown
# ADR-004: Probe-Based Failure Detection

## Status

Accepted 2026-03; **amended 2026-09-18** — indirect (relayed) probing
retired. History below.

## Context

In a distributed system, nodes need to detect when peers become unreachable:
- to avoid wasted sync attempts to dead nodes,
- to keep peer status accurate for the application,
- to steer gossip partner selection.

The library targets small networks (up to 8 devices) with potentially
unreliable connections (mobile, P2P). Under ADR-007 membership is local
metadata: no node ever tells another who it thinks is alive.

## Decision

**Detect failures with direct probes, graded status, and slow recovery
probing.** Each round the detector pings one peer and waits a per-peer
RTT-adaptive timeout; if that expires it holds the ping open for one more
timeout — the grace window (ADR-012) — and counts a failure only if the
window closes empty.

```
Probe:
  A ──ping──> B
  A <──ack─── B            (before the timeout: reachable)
  A <──ack─── B            (inside the grace window: still reachable)
  (nothing)                (window closes empty: one failure counted)
```

No probe is ever relayed through a third peer. In the SWIM literature the
relay exists to stop one node's false "dead" verdict from spreading through
the group; here a verdict never leaves the node that formed it, so the
relay would protect nothing — and keeping a one-way-deaf link marked
reachable would keep the node sending into a link that cannot answer,
while data converges through any healthy third node regardless.

## Rationale

1. **The status means what it says**: "I cannot usefully exchange data
   with this peer directly" is exactly what the status gates.
2. **Scalable**: O(1) probe messages per node per round.
3. **Configurable**: suspicion thresholds tunable for different networks.
4. **Simple state machine**: reachable → suspected → unreachable.
5. **One code path**: every verdict-bearing probe has the same shape,
   so the late-Ack protection (ADR-012) is universal.

## Protocol Details

### States

- **Reachable**: Peer answers probes.
- **Suspected**: After `suspicionThreshold` (default 5) consecutive probe
  failures. Still probed; recovers by answering.
- **Unreachable**: After `unreachableThreshold` (default 15) consecutive
  probe failures. Excluded from regular probing and gossip. Probed for
  recovery every `unreachableProbeInterval` (default 5) rounds.

### Configuration

```dart
CoordinatorConfig(
  suspicionThreshold: 5,       // Failed probes before suspected (default: 5)
  unreachableThreshold: 15,    // Failed probes before unreachable (default: 15)
  unreachableProbeInterval: 5, // Probe unreachable peers every N rounds (default: 5)
  startupGracePeriod: Duration(seconds: 10), // Hold new peers out of probing
)
```

Timing parameters (ping timeout, probe interval, gossip interval) are
RTT-adaptive and not directly configurable — see ADR-013. The grace
window is one more per-peer ping timeout and has no knob of its own.

### No incarnation numbers

SWIM's incarnation numbers let a wrongly suspected node refute the rumor.
There is no rumor here — a suspicion is private to the node that formed
it — so a wrongly suspected peer clears its name by answering the next
probe, or by sending anything at all. Neither library implements
incarnation numbers; the Kotlin twin's leftover scaffolding is scheduled
for deletion.

### Tuning Guide

All parameters are set via `CoordinatorConfig` and passed to
`Coordinator.create()`. Only the policy thresholds below are tunable.

| Parameter | Default | Effect of raising | Effect of lowering |
|-----------|---------|-------------------|--------------------|
| `suspicionThreshold` | 5 | Slower to suspect, fewer false positives | Faster detection, more false positives on flaky networks |
| `unreachableThreshold` | 15 | Longer recovery window for suspected peers | Faster eviction, less chance to recover |
| `unreachableProbeInterval` | 5 | Less overhead probing dead peers, slower deadlock recovery | Faster deadlock recovery, negligible extra bandwidth (~66 bytes/probe) |
| `startupGracePeriod` | 10s | More time for transport to stabilize | Faster initial failure detection |

#### Failure detection timeline (defaults, ~1.5s probe interval)

**This timeline assumes n=2** (one probable peer, so every round probes the
dead peer). Probe selection is round-robin over a shuffled order, so a
specific dead peer is probed roughly once every (n−1) rounds; multiply the
times below by ~(n−1) for larger groups. In practice, on the BLE transport a
closed connection removes the peer immediately, so this timeline mainly
governs half-open links.

1. **0–7.5s**: First 5 probes fail → peer becomes **suspected**
2. **7.5–22.5s**: 10 more probes fail → peer becomes **unreachable**
3. **Every ~7.5s thereafter**: One recovery probe fires. If the peer
   answers, directly or inside the grace window, it recovers to
   **reachable** immediately.

#### Recovery paths

- **Suspected → Reachable**: the peer answers any regular probe, or sends
  anything the node receives.
- **Unreachable → Reachable**: three ways:
  1. A periodic recovery probe gets an answer
  2. The peer sends an incoming Ping (handled by the detector)
  3. Transport reconnection triggers `addPeer()` (e.g., BLE reconnect)

#### Bandwidth cost of unreachable probing

A Ping is ~66 bytes. At `unreachableProbeInterval: 5` with ~1.5s probe
intervals, that's one 66-byte message every ~7.5s per unreachable peer —
roughly 9 bytes/second, or 0.06% of typical gossip traffic. Lowering the
interval to 1 (probe every round) costs ~44 bytes/second, still negligible.

## Consequences

### Positive

- Fast detection of actual failures (~7.5s to suspected, ~22.5s to unreachable)
- Low false-positive rate from the grace window and two-tier thresholds
- Works well with unreliable mobile networks
- Automatic recovery from mutual-unreachable deadlocks via periodic probing
- Minimal bandwidth overhead
- One probe shape on both libraries

### Negative

- A one-way-deaf pair is reported as degraded even when a third node
  could reach both sides (intended: data still converges through it)
- Small delay before declaring a node unreachable

### Integration

- FailureDetector runs alongside GossipEngine
- Shares MessagePort for network communication
- Updates PeerRegistry with status changes
- Emits PeerStatusChanged events
- A `PingReq` frame from a peer on an older build is decoded and ignored;
  the type leaves the wire at the next dialect revision.

## History

### Original decision (2026-03): SWIM

The detector was first specified as SWIM (Scalable Weakly-consistent
Infection-style Membership): direct probes plus, on a direct timeout, an
indirect probe relayed through up to three intermediaries. The rationale
was fewer false positives from transient network issues, and precedent in
HashiCorp Serf and Consul. SWIM proper is three mechanisms — probing,
dissemination of verdicts, and refutation by incarnation number — and only
the probing was ever built; ADR-007 made membership deliberately local.

### Retirement (ruled 2026-09-01, Kotlin shipped 2026-09-15, Dart 2026-09-18)

With no dissemination, the relay's purpose — insulating the group from one
node's false verdict — had no referent, and its local effect was
counterproductive (a deaf link kept marked reachable). On the Kotlin twin
the relay had also been structurally inert since the port, so the server
fleet had been running without it unnoticed. Both libraries now converge
on the slimmer detector; the full argument is the retirement decision
record in `docs/superpowers/specs/2026-09-01-swim-slimdown-decision.md`,
and the Dart batch's rulings are in
`docs/superpowers/specs/2026-09-18-dart-relay-retirement-rulings.md`.
The mechanism is no longer called SWIM anywhere the library describes
itself, since neither dissemination, refutation, nor indirect probing
remain.

## Alternatives Considered

### Simple Heartbeat

Each peer broadcasts "I'm alive" periodically: simpler, but O(n) messages
per period, higher false-positive rate, poor scaling.

### Phi Accrual Detector

Adaptive threshold based on heartbeat history: more accurate for stable
networks but complex to tune, assumes regular heartbeats, overkill here.

### Passive liveness only

No dedicated probes; liveness from transport link events plus sync-traffic
recency. Rejected in the retirement record: quiescence pacing makes a
converged mesh deliberately quiet, so passive observation cannot tell
"paced and healthy" from "dead" — the idle probe is load-bearing.

### No Failure Detection

Let gossip timeouts handle failures: wastes bandwidth on dead peers, gives
the application no status, slow to detect.
````

- [ ] **Step 2: Rewrite ADR-012**

Replace the whole file with:

````markdown
# ADR-012: Late-Ack Grace Window

## Status

Accepted 2026-05; **amended 2026-09-18** — the grace window is now the
shape of every verdict-bearing probe, not a special case.

## Context

Failure detection (ADR-004) sends a direct Ping and waits a per-peer
RTT-adaptive timeout for the Ack. In real mobile network conditions, Acks
sometimes arrive slightly after that timeout.

Observed behavior in production logs showed the pattern:
```
Probe FAILED for NodeId(...) (pings sent: 6, acks received: 5)
Received Ack seq=6
Ack seq=6 did NOT match any pending ping (pending sequences: [])
```

The Ack arrived ~175ms after the probe timeout, causing a spurious probe
failure even though the peer was healthy — unnecessary "suspected"
transitions and noise.

Originally the only wait after a direct timeout was the indirect probe
phase, so a two-device pair (no intermediaries) had no window at all, and a
larger group's window was an accident of relaying. The 2026-05 decision
added an explicit equal-length wait for the no-intermediary case. The
2026-09 retirement of indirect probing (ADR-004 history) left that wait as
the only path.

## Decision

**Every verdict-bearing probe holds its pending ping open for one more
per-peer timeout after the direct timeout — the grace window — and counts
a failure only if the window closes empty.** The window races the still-
open pending ping, so it ends the instant a late Ack lands rather than
sleeping its full length.

Applies to the regular probe round and the unreachable-recovery probe.
Does not apply to the new-peer RTT bootstrap probe: it records no failure,
so there is no verdict to protect, and a late first sample is simply the
next probe's.

The window's length is the same per-peer adaptive timeout as the direct
wait, re-read when the window opens so a fresh RTT sample is honored. It
has no configuration knob of its own.

## Rationale

1. **Matches real-world network behavior**: an Ack 100–200ms late is a
   healthy peer, not a failure.
2. **No protocol change**: no new message types, no peer coordination.
3. **One shape**: two-device pairs and larger groups behave identically,
   and both libraries read the same probe line for line.
4. **Bounded cost**: worst case a failed probe takes two timeouts; the probe
   interval is sized at three (room for both, plus slack).

## Consequences

### Positive

- No spurious probe failures from latency spikes
- Stable peer status in two-device pairs
- No "did NOT match any pending ping" noise for merely-late Acks
- The late-Ack case is logged distinctly, which is the signal that a
  timeout is running tight

### Negative

- Detecting a real failure takes up to two timeouts per probe instead of
  one
- The pending-ping map holds entries slightly longer

### Trade-offs

With the 500ms floor: direct 500ms + grace 500ms = 1000ms per probe round
worst case. Real failures are still detected within a few probe rounds,
and false positives are more disruptive than slightly slower detection.

## Alternatives Considered

### Increase the direct ping timeout

Simpler, but delays detection for all probes, not just the edge cases, and
still drops an Ack that lands just after the longer timeout.

### Ignore late Acks entirely

Simplest, but causes the spurious failures this record exists to remove.

### Sleep the full window, then check

The pre-2026-09 Dart shape. Same verdicts, but a late Ack at +100ms still
cost the remaining 400ms of the round. The Kotlin twin raced the window
from the start; Dart adopted the race with the retirement.
````

- [ ] **Step 3: Update the ADR index and CLAUDE.md**

In `packages/gossip/docs/adr/README.md`: line 16 → `| [004](004-swim-failure-detection.md) | Probe-Based Failure Detection | Accepted, amended 2026-09-18 |`; line 24 → `| [012](012-swim-late-ack-handling.md) | Late-Ack Grace Window | Accepted, amended 2026-09-18 |`.

In `CLAUDE.md` line 152: `| 004 | SWIM protocol for failure detection |` → `| 004 | Probe-based failure detection (indirect probing retired 2026-09) |`.

- [ ] **Step 4: Commit**

```bash
git add packages/gossip/docs/adr CLAUDE.md
git commit -m "docs(adr): amend ADR-004 and ADR-012 for the relay retirement; correct the incarnation-number claim

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: The rename sweep — "SWIM" → failure-detection vocabulary, log prefix `[FailureDetector]`

**Files:**
- Modify: every file under `packages/gossip/lib`, `packages/gossip/test`, `packages/gossip/README.md`, `packages/gossip/docs/guides/**`, `packages/gossip/docs/adr/006-transport-discovery-external.md`, `packages/gossip/docs/adr/010-ddd-layered-architecture.md`, `packages/gossip/docs/adr/013-adaptive-timing.md`, `packages/gossip/test/integration/README.md`, and `CLAUDE.md` that contains `SWIM` — except the exceptions in Global Constraints.
- Test: `packages/gossip/test/membership/application/failure_detector_test.dart` (one new pin for the prefix)

**Interfaces:** none public. The only runtime-visible change is the log prefix string in `FailureDetector._log`.

- [ ] **Step 1: Write the failing log-prefix pin**

In `failure_detector_test.dart`, inside `group('Lifecycle', ...)` (or a new `group('Logging', ...)` at the end of `main`), add:

```dart
  group('Logging', () {
    test('log lines carry the [FailureDetector] prefix', () async {
      final lines = <String>[];
      final localNode = NodeId('local');
      final registry = PeerRegistry(localNode: localNode);
      final timePort = InMemoryTimePort();
      final bus = InMemoryMessageBus();
      final detector = FailureDetector(
        codec: MembershipMessageCodec(wireVersion: WireVersion.v2),
        localNode: localNode,
        peerRegistry: registry,
        timePort: timePort,
        messagePort: InMemoryMessagePort(localNode, bus),
        onLog: (level, message, error, stackTrace) => lines.add(message),
      );
      addTearDown(detector.stopListening);

      // probeNewPeer logs "Sending Ping ..." before it awaits anything, and
      // logs the timeout when the fake clock passes it — two lines, both
      // prefixed. peer1 has no port on the bus, so the send may fail and
      // be logged too; every line still carries the prefix.
      registry.addPeer(NodeId('peer1'), occurredAt: DateTime.now());
      final probe = detector.probeNewPeer(NodeId('peer1'));
      await Future<void>.delayed(Duration.zero);
      await timePort.advance(const Duration(seconds: 3));
      await probe;

      expect(lines, isNotEmpty);
      expect(lines.every((l) => l.startsWith('[FailureDetector] ')), isTrue);
      expect(lines.any((l) => l.contains('[SWIM]')), isFalse);
    });
  });
```

Check the file's existing imports and add the ones this test needs (`InMemoryTimePort`, `InMemoryMessageBus`, `InMemoryMessagePort`, `MembershipMessageCodec`, `WireVersion`, `PeerRegistry`) using the same import paths the harness file uses.

- [ ] **Step 2: Run it red**

Run: `cd packages/gossip && dart test test/membership/application/failure_detector_test.dart --name "FailureDetector\\] prefix"`
Expected: FAIL: lines start with `[SWIM] `.

- [ ] **Step 3: Change the prefix and sweep the vocabulary**

In `failure_detector.dart` change `onLog?.call(level, '[SWIM] $message', error, stackTrace);` to `onLog?.call(level, '[FailureDetector] $message', error, stackTrace);`. Also change the two strings `'Malformed SWIM message from ...'` (emitted error and log) to `'Malformed membership message from ...'`, and `/// Starts listening to incoming SWIM protocol messages.` → `/// Starts listening to incoming membership protocol messages.`, `// zone error and permanently cancels SWIM message handling.` → `// zone error and permanently cancels membership message handling.`, `/// SWIM pings have unique sequence numbers` → `/// probe pings have unique sequence numbers` (already done in Task 2 if that text was replaced; verify), and in `updatePeerHealth`'s doc keep `SWIM incarnation/refutation is deliberately not implemented` verbatim (allowed citation).

Then apply this table with a careful manual pass (not blind `sed`: read each hit), using `grep -rn 'SWIM' packages/gossip/lib packages/gossip/test packages/gossip/README.md packages/gossip/docs/guides packages/gossip/docs/adr/006-transport-discovery-external.md packages/gossip/docs/adr/010-ddd-layered-architecture.md packages/gossip/docs/adr/013-adaptive-timing.md packages/gossip/test/integration/README.md CLAUDE.md` as the worklist:

| Old phrase | New phrase |
|---|---|
| `SWIM failure detection` | `failure detection` |
| `SWIM protocol` (as the thing the library does) | `failure detection` |
| `SWIM ping timeout` / `SWIM probe interval` | `ping timeout` / `probe interval` |
| `SWIM probe loop` / `SWIM probe rounds` / `SWIM probes` | `probe loop` / `probe rounds` / `probes` |
| `SWIM pings/acks` / `SWIM pings and acks` | `probe pings/acks` |
| `SWIM liveness` | `liveness` |
| `SWIM-driven` | `probe-driven` |
| `SWIM state` / `SWIM protocol state` | `failure-detection state` |
| `SWIM messages` | `membership messages` |
| `the SWIM peer model` | `the peer model` |
| `SWIM suppression` (CHANGELOG, an existing Unreleased bullet at line 106) | `probe suppression` |
| `SWIM detection latency` (selector doc) | `detection latency` |
| `Implements the SWIM (Scalable Weakly-consistent ...) protocol` | delete the sentence (Task 1 already rewrote this doc; verify) |
| `# SWIM protocol and peer status` (integration README) | `# failure detection and peer status` |
| README line 11 `**SWIM failure detection**: Scalable membership protocol for peer health monitoring` | `**Failure detection**: Direct probes with graded reachable/suspected/unreachable status for peer health` |
| README line 228 box label `SWIM` | `Probes` |
| CLAUDE.md line 48 `SWIM failure detection` | `failure detection` |
| CLAUDE.md line 64 `# SWIM liveness:` | `# liveness:` |
| CLAUDE.md line 97 `SWIM protocol for peer health` | `probe-based failure detection for peer health` |
| `gossip.dart` line 77 `**SWIM Protocol**: Failure detection for peer health` | `**Failure Detection**: Direct probes for peer health` |
| `jitter.dart` `A ±20% spread is standard SWIM practice.` | keep verbatim (literature citation) |
| `updatePeerHealth` doc `SWIM incarnation/refutation is deliberately not implemented` | keep verbatim |
| ADR-004 history section, ADR-012 history paragraph | keep (written in Task 5) |
| `docs/roadmap.md`, `docs/backlog/**`, `docs/audits/**`, `docs/superpowers/**`, CHANGELOG below `## Unreleased` | keep (history and tracking; Task 7 touches the tracking docs deliberately) |

Also rename the file `packages/gossip/test/sync/application/gossip_engine_liveness_test.dart`'s group `'GossipEngine feeds SWIM liveness'` to `'GossipEngine feeds liveness'`; the test file names containing `swim` do not exist (verify with `find packages/gossip -iname '*swim*'` — expected: only the two ADR files, which keep their names).

- [ ] **Step 4: Verify the sweep**

Run:
```bash
cd packages/gossip && grep -rn 'SWIM' lib test README.md docs/guides docs/adr/006-transport-discovery-external.md docs/adr/010-ddd-layered-architecture.md docs/adr/013-adaptive-timing.md test/integration/README.md ../../CLAUDE.md
```
Expected: exactly the allowed hits: `lib/src/shared/domain/services/jitter.dart` (standard SWIM practice), `lib/src/membership/application/failure_detector.dart` (the incarnation/refutation note only). Anything else is a miss — fix it.

Run: `dart analyze && dart format . && dart test`
Expected: clean, formatted, green (the prefix pin included). Also run `melos run analyze` from the repo root, since `gossip_nearby` and `gossip_bluey` compile against the core package.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: rename the mechanism away from SWIM — failure detection, probes, liveness; log prefix [FailureDetector]

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Changelog and program bookkeeping

**Files:**
- Modify: `packages/gossip/CHANGELOG.md` (`### Behavioral` under `## Unreleased`, line 95)
- Modify: `docs/roadmap.md` (item 8 at line 119-125; the track row at line 265 for `kt-retire-indirect-probing`; the `engine-swim-threshold-tuning` row's "re-measure once indirect checks are retired" wording stays as a live instruction)
- Modify: `docs/backlog/kt-retire-indirect-probing.md` (Related section)
- Modify: `docs/backlog/kt-normalize-twin-divergences.md` (rows "SWIM indirect probing" at line 66 and "Grace window after a direct probe timeout" at line 91; add one row for the rename)
- Modify: `docs/backlog/health-adopt-kt-flow-backs.md` (the paragraph at lines 34-40 mentioning the grace window)
- Modify: `docs/superpowers/specs/2026-09-18-dart-relay-retirement-rulings.md` (append the shipping note to Review outcome)

**Interfaces:** none.

- [ ] **Step 1: Changelog**

At the top of `### Behavioral` (after the heading at line 95) insert:

```markdown
- Indirect (relayed) health probing is retired. A probe is now a direct
  Ping, a per-peer adaptive timeout, and a grace window of one more
  timeout that ends the moment a late Ack lands; a failure is counted only
  if the window closes empty. A `PingReq` frame from a peer on an older
  build is decoded and ignored; this library never sends one. A pair that
  is one-way deaf now degrades honestly — each side eventually marks the
  other suspected, then unreachable, while entries keep converging through
  any healthy third node, and the pair recovers after the link heals. See
  ADR-004 (amended) and the retirement decision record in
  `docs/superpowers/specs/`.
- The failure detector's log prefix changed from `[SWIM] ` to
  `[FailureDetector] `, and its malformed-frame error text now says
  "membership message"; the mechanism is no longer described as SWIM
  anywhere in the library's docs.
```

- [ ] **Step 2: Roadmap**

Item 8 (lines 119-125): replace the whole item with:

```markdown
8. ☑ **Finish the Dart half of the relay retirement** — **done 2026-09-18**
   (branch `feature/retire-indirect-probing`; rulings page
   [approved](superpowers/specs/2026-09-18-dart-relay-retirement-rulings.md)
   the same day): the indirect phase and the relay handler are gone, the
   grace window races the late Ack (the Kotlin flow-back adopted), ADR-004
   and ADR-012 are amended, the mechanism is no longer called SWIM, the
   asymmetric-partition suite pins the honest degradation with a third node
   present. Closes [retire indirect probing](backlog/kt-retire-indirect-probing.md)
   on both halves. **Remaining tail:** the OpenDoorApp pin bump (its own PR
   in the app repo, device-checked on Android and iOS per the rulings).
```

(Replace the merge commit hash into the item once the PR merges; leave the branch name until then.)

Track row (line 265, the `◐ **High**` row for `kt-retire-indirect-probing`): change `◐` to `☑` and append ` **Dart half shipped 2026-09-18** (rulings page approved; ADR-004/012 amended, SWIM renamed away, grace-window race adopted). Both halves done; the app pin bump is item 8's tail.`

- [ ] **Step 3: Backlog item**

In `docs/backlog/kt-retire-indirect-probing.md` Related section, after the `**Kotlin half done:**` bullet add:

```markdown
- **Dart half done:** 2026-09-18 on branch `feature/retire-indirect-probing`
  ([rulings](../superpowers/specs/2026-09-18-dart-relay-retirement-rulings.md)) —
  relay handler ignores, the indirect phase is a grace window that races the
  late Ack, `PingReq` still decodes with its encoder kept for the wire
  vectors, ADR-004/012 amended, the mechanism renamed away from SWIM. Both
  halves are done; what remains is the OpenDoorApp pin bump.
```

- [ ] **Step 4: Divergence register and flow-backs**

In `docs/backlog/kt-normalize-twin-divergences.md`:
- Row "SWIM indirect probing" (line 66): rename the row label to `Indirect probing`, and replace the trailing "Dart half pending." with `**Closed** — Dart half shipped 2026-09-18 (same shape: relay ignored, grace window races the late Ack, encoder kept for the vectors).`
- Row "Grace window after a direct probe timeout" (line 91): replace the last cell's text with `**Closed by adoption** in the Dart relay retirement (2026-09-18): Dart's grace window now races the pending ping too.`
- Add a row after it:

```markdown
| Failure-detector vocabulary and log prefix | Dart renamed the mechanism away from "SWIM" on 2026-09-18 (docs, comments, README, CLAUDE.md) and logs with the `[FailureDetector] ` prefix; kt still says "SWIM" in its README, CLAUDE.md, and detector docs and logs `[SWIM] `. | Dart (the ruled vocabulary) | kt adopts the same prefix and wording in its next bump (roadmap item 9); documentation only, no wire. |
```

In `docs/backlog/health-adopt-kt-flow-backs.md` lines 34-40, change `the grace window after a failed probe racing the late answer instead of sleeping blind (worth adopting when Dart retires indirect probing, which rewrites the same lines)` to `the grace window after a failed probe racing the late answer instead of sleeping blind (**adopted** with the Dart relay retirement, 2026-09-18)`.

- [ ] **Step 5: Rulings page shipping note**

Append to the Review outcome section of `docs/superpowers/specs/2026-09-18-dart-relay-retirement-rulings.md`:

```markdown

**Shipped 2026-09-18** on branch `feature/retire-indirect-probing` per the
plan `docs/superpowers/plans/2026-09-18-dart-relay-retirement.md`; suite
1274 → N (fill in from the final run). The OpenDoorApp pin bump follows as
its own PR.
```

Fill in `N` from `dart test`'s final count before committing.

- [ ] **Step 6: Hygiene and commit**

Run: `grep -rn 'Dart half pending\|Dart half is what remains' docs` — expected: no output. Run `melos run test && melos run analyze` from the repo root — expected: all packages green, analyzer clean.

```bash
git add -A
git commit -m "docs: changelog and program bookkeeping for the Dart relay retirement (roadmap item 8 done)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Branch finish

- [ ] **Step 1: Full verification**

From the repo root: `melos run test && melos run analyze && melos run format` (format must leave the tree unchanged: `git status --porcelain` empty afterwards).

- [ ] **Step 2: Review and integrate**

Use `superpowers:requesting-code-review` on the branch diff against `main`, then `superpowers:finishing-a-development-branch`. The PR description lists the rulings page, the four new pins, the suite count before/after, and states plainly that the wire is unchanged and the app pin bump is a separate PR. End the PR body with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

- [ ] **Step 3: After merge**

Replace the branch name in roadmap item 8 and the backlog item with the merge commit, in one docs commit on `main`.
