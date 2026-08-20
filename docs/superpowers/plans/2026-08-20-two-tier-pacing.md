# Two-Tier Pacing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A converged, healthy network goes quiet: both scheduling loops back off toward a 30 s ceiling when nothing is happening and snap back instantly on news, probes are suppressed for peers we just heard from, and converged digest responses shrink to ~63 B.

**Architecture:** One pure domain state machine (`QuiescencePacer`) owned once by each protocol loop. The gossip engine tracks a "news since last round" flag feeding its pacer, records exchanges on the responder path, skips rounds whose candidates were all exchanged-with recently, and dominance-filters `DigestResponse`. The failure detector feeds its own pacer from probe outcomes and skips peers whose `lastContactMs` is fresh. Timers stay in the protocol layer; the pacer has no I/O.

**Tech Stack:** Pure Dart, `packages/gossip` only. Tests via the existing `GossipEngineTestHarness` / `FailureDetectorTestHarness` / `TestNetwork` infrastructure.

**Spec:** `docs/superpowers/specs/2026-08-20-two-tier-pacing-design.md`

## Global Constraints

- Strict TDD: no production code without a failing test first (repo mandate).
- Idle ceiling: exactly `Duration(seconds: 30)` for both loops; growth factor 1.5. No new config knobs.
- A user-pinned static `gossipInterval` / `probeInterval` bypasses the pacer entirely (verbatim, as today).
- No cached-VV skipping anywhere — time-based mechanisms only (owner decision 2).
- All ~972 existing gossip tests stay green after every task; `dart analyze` zero issues.
- Run tests from `packages/gossip/`: `dart test <file>`; full gate `dart test && dart analyze`.
- Commit messages follow repo style (`feat(gossip): …`, `test(gossip): …`) and end with the Claude Fable co-author line used throughout this branch.

---

### Task 1: QuiescencePacer domain service

**Files:**
- Create: `packages/gossip/lib/src/domain/services/quiescence_pacer.dart`
- Test: `packages/gossip/test/domain/services/quiescence_pacer_test.dart`

**Interfaces:**
- Consumes: nothing (pure).
- Produces: `class QuiescencePacer { QuiescencePacer({required Duration ceiling, double growth = 1.5}); void news(); void quietRound(); Duration apply(Duration base); }` — Tasks 2 and 7 construct it with `ceiling: Duration(seconds: 30)`.

- [ ] **Step 1: Write the failing tests**

```dart
// packages/gossip/test/domain/services/quiescence_pacer_test.dart
import 'package:test/test.dart';
import 'package:gossip/src/domain/services/quiescence_pacer.dart';

void main() {
  group('QuiescencePacer', () {
    test('applies the base unchanged before any quiet round', () {
      final pacer = QuiescencePacer(ceiling: const Duration(seconds: 30));
      expect(pacer.apply(const Duration(seconds: 1)),
          const Duration(seconds: 1));
    });

    test('each quiet round grows the applied interval by 1.5x', () {
      final pacer = QuiescencePacer(ceiling: const Duration(seconds: 30));
      pacer.quietRound();
      expect(pacer.apply(const Duration(seconds: 1)),
          const Duration(milliseconds: 1500));
      pacer.quietRound();
      expect(pacer.apply(const Duration(seconds: 1)),
          const Duration(milliseconds: 2250));
    });

    test('news snaps the multiplier back to 1', () {
      final pacer = QuiescencePacer(ceiling: const Duration(seconds: 30));
      for (var i = 0; i < 5; i++) {
        pacer.quietRound();
      }
      pacer.news();
      expect(pacer.apply(const Duration(seconds: 1)),
          const Duration(seconds: 1));
    });

    test('the applied interval never exceeds the ceiling', () {
      final pacer = QuiescencePacer(ceiling: const Duration(seconds: 30));
      for (var i = 0; i < 20; i++) {
        pacer.quietRound();
      }
      expect(pacer.apply(const Duration(seconds: 5)),
          const Duration(seconds: 30));
    });

    test('eternal idleness cannot overflow the multiplier', () {
      final pacer = QuiescencePacer(ceiling: const Duration(seconds: 30));
      for (var i = 0; i < 10000; i++) {
        pacer.quietRound();
      }
      // Still clamps sanely and news still resets.
      expect(pacer.apply(const Duration(milliseconds: 100)),
          const Duration(seconds: 30));
      pacer.news();
      expect(pacer.apply(const Duration(milliseconds: 100)),
          const Duration(milliseconds: 100));
    });
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `dart test test/domain/services/quiescence_pacer_test.dart`
Expected: FAIL — `quiescence_pacer.dart` does not exist (compile error).

- [ ] **Step 3: Minimal implementation**

```dart
// packages/gossip/lib/src/domain/services/quiescence_pacer.dart
import 'dart:math' as math;

/// Pure quiescence pacing state machine (two-tier scheduling, WIRE4-1/2/4).
///
/// Owned by a protocol loop: the loop reports [quietRound] when a round
/// carried no news and [news] the moment anything happens; [apply]
/// stretches the loop's latency-derived base interval toward [ceiling]
/// while quiet. No clocks, timers, or I/O — the protocol layer owns those.
class QuiescencePacer {
  QuiescencePacer({required this.ceiling, this.growth = 1.5});

  /// The slowest the paced interval may get (spec: 30 s, not configurable).
  final Duration ceiling;

  /// Multiplicative growth per quiet round (Trickle-style doubling core).
  final double growth;

  /// Hard cap keeps eternal idleness from growing the double unboundedly;
  /// [apply]'s ceiling clamp is what callers observe.
  static const double _maxMultiplier = 1 << 20;

  double _multiplier = 1;

  /// Anything happened: snap back to the active cadence.
  void news() => _multiplier = 1;

  /// A round completed with nothing to say: rest a little longer.
  void quietRound() =>
      _multiplier = math.min(_multiplier * growth, _maxMultiplier);

  /// The paced interval for the loop's current latency-derived [base].
  Duration apply(Duration base) {
    final scaled =
        Duration(microseconds: (base.inMicroseconds * _multiplier).round());
    return scaled > ceiling ? ceiling : scaled;
  }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `dart test test/domain/services/quiescence_pacer_test.dart`
Expected: 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/src/domain/services/quiescence_pacer.dart test/domain/services/quiescence_pacer_test.dart
git commit -m "feat(gossip): QuiescencePacer — pure two-tier pacing state machine"
```

---

### Task 2: Gossip engine — pacer wiring, news flag, quiet-round growth

**Files:**
- Modify: `packages/gossip/lib/src/protocol/gossip_engine.dart` (fields near line 206; `effectiveGossipInterval` at ~312-340; `performGossipRound` at ~586; `notifyLocalWrite` at ~463; `start()` at ~388)
- Test: `packages/gossip/test/protocol/gossip_engine_pacing_test.dart` (new)

**Interfaces:**
- Consumes: `QuiescencePacer` from Task 1.
- Produces: private `void _recordNews()` on `GossipEngine` — Tasks 3 and 4 call it from additional sites. `effectiveGossipInterval` semantics change: adaptive path returns `_pacer.apply(<existing adaptive base>)`.

- [ ] **Step 1: Write the failing tests**

```dart
// packages/gossip/test/protocol/gossip_engine_pacing_test.dart
import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'dart:typed_data';

import 'gossip_engine_test_harness.dart';

/// Two-tier pacing (spec 2026-08-20): quiet rounds stretch the adaptive
/// interval toward the 30s ceiling; any news snaps it back to base.
void main() {
  group('GossipEngine quiescence pacing', () {
    test('consecutive no-news rounds grow the effective interval', () async {
      final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 500));
      // Base = median SRTT * 2 = 1s.
      expect(h.engine.effectiveGossipInterval, const Duration(seconds: 1));

      h.engine.start();
      await h.engine.performGossipRound(); // first round: news flag from start
      await h.engine.performGossipRound(); // quiet
      await h.engine.performGossipRound(); // quiet

      expect(h.engine.effectiveGossipInterval,
          greaterThan(const Duration(seconds: 1)));
      h.engine.stop();
    });

    test('a local write snaps the interval back to base', () async {
      final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 500));
      h.engine.start();
      for (var i = 0; i < 6; i++) {
        await h.engine.performGossipRound();
      }
      expect(h.engine.effectiveGossipInterval,
          greaterThan(const Duration(seconds: 1)));

      h.engine.notifyLocalWrite(
        ChannelId('ch'),
        StreamId('s'),
        LogEntry(
          author: h.localNode,
          sequence: 1,
          timestamp: Hlc(1, 0),
          payload: Uint8List.fromList([1]),
        ),
      );

      expect(h.engine.effectiveGossipInterval, const Duration(seconds: 1));
      h.engine.stop();
    });

    test('the paced interval clamps at the 30s ceiling', () async {
      final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(seconds: 2));
      h.engine.start();
      for (var i = 0; i < 30; i++) {
        await h.engine.performGossipRound();
      }
      expect(h.engine.effectiveGossipInterval, const Duration(seconds: 30));
      h.engine.stop();
    });

    test('a static gossipInterval bypasses the pacer entirely', () async {
      final h = GossipEngineTestHarness(
        gossipInterval: const Duration(seconds: 2),
      );
      h.addPeer('peer1');
      h.engine.start();
      for (var i = 0; i < 6; i++) {
        await h.engine.performGossipRound();
      }
      expect(h.engine.effectiveGossipInterval, const Duration(seconds: 2));
      h.engine.stop();
    });
  });
}
```

Note: if the harness constructor requires other named args, mirror the
construction in `test/protocol/gossip_engine_interval_pacing_test.dart`
(same pattern, verified) — the assertions above are the contract.

- [ ] **Step 2: Run to verify failure**

Run: `dart test test/protocol/gossip_engine_pacing_test.dart`
Expected: FAIL — intervals do not grow (first test: `Expected: > 0:00:01, Actual: 0:00:01`).

- [ ] **Step 3: Implement**

In `gossip_engine.dart`:

(a) Import + fields (near the other fields, ~line 206):

```dart
import '../domain/services/quiescence_pacer.dart';
```

```dart
  /// Two-tier pacing (spec 2026-08-20): stretches the adaptive interval
  /// toward [_idleCeiling] across quiet rounds; any news snaps it back.
  final QuiescencePacer _pacer = QuiescencePacer(ceiling: _idleCeiling);

  /// The slowest the anti-entropy safety net may get (owner decision:
  /// 30 s, not configurable).
  static const Duration _idleCeiling = Duration(seconds: 30);

  /// True when anything newsworthy happened since the last round began.
  /// Read-and-cleared by [performGossipRound]; set by [_recordNews].
  bool _newsSinceLastRound = true;

  /// News: local append, merge, delta traffic either direction, or a
  /// membership change. Resets the pacer and marks the round non-quiet.
  void _recordNews() {
    _newsSinceLastRound = true;
    _pacer.news();
  }
```

(b) `effectiveGossipInterval` (~line 312): keep the static-override branch
unchanged; wrap only the adaptive returns. The method currently returns
`_defaultConservativeInterval`, `_minGossipInterval`, `_maxGossipInterval`,
or `computed` — route all four through the pacer by computing the base
first, then returning `_pacer.apply(base)`:

```dart
  Duration get effectiveGossipInterval {
    if (_staticIntervalProvided || !_adaptiveTimingEnabled) {
      return _staticGossipInterval;
    }
    return _pacer.apply(_adaptiveBaseInterval);
  }

  /// Today's latency-derived cadence, unchanged (median SRTT x 2,
  /// clamped [100ms, 5s]; 1s fallback without samples). The pacer
  /// stretches THIS toward the idle ceiling.
  Duration get _adaptiveBaseInterval {
    final srtts = <Duration>[];
    for (final peer in peerRegistry.reachablePeers) {
      final rttEstimate = peer.metrics.rttEstimate;
      if (rttEstimate != null) srtts.add(rttEstimate.smoothedRtt);
    }
    if (srtts.isEmpty) return _defaultConservativeInterval;
    srtts.sort();
    final computed = srtts[srtts.length ~/ 2] * _gossipIntervalMultiplier;
    if (computed < _minGossipInterval) return _minGossipInterval;
    if (computed > _maxGossipInterval) return _maxGossipInterval;
    return computed;
  }
```

(c) `performGossipRound` (~line 586), FIRST statement — read-and-clear the
flag:

```dart
  Future<void> performGossipRound() async {
    if (_newsSinceLastRound) {
      _newsSinceLastRound = false;
    } else {
      _pacer.quietRound();
    }
    // ... existing body unchanged ...
```

(d) `notifyLocalWrite` (~line 463): after the `if (!_isRunning) return;`
guard, add `_recordNews();`.

(e) `start()` (~line 388): after `_isRunning = true;`, add
`_newsSinceLastRound = true;` and `_pacer.news();` (a restart is news —
never resume mid-backoff into a stale world).

- [ ] **Step 4: Run to verify pass, then the neighbors**

Run: `dart test test/protocol/gossip_engine_pacing_test.dart` → PASS.
Run: `dart test test/protocol/ && dart test test/integration/` → all green
(existing interval-pacing tests assert the base formula via fresh engines
with zero quiet rounds, so they still hold).

- [ ] **Step 5: Commit**

```bash
git add lib/src/protocol/gossip_engine.dart test/protocol/gossip_engine_pacing_test.dart
git commit -m "feat(gossip): quiescence pacing for the gossip round (WIRE4-1/2)"
```

---

### Task 3: Gossip engine — remaining news triggers

**Files:**
- Modify: `packages/gossip/lib/src/protocol/gossip_engine.dart` (`_mergeDeltaResponse` ~1496; `_sendDeltaRequests` ~1166; `handleDeltaRequest` ~1309; `_handleIncomingMessage` DeltaRequest branch ~843; `syncWithPeer` ~743; `clearPendingRequestsForPeer` ~1623)
- Test: extend `packages/gossip/test/protocol/gossip_engine_pacing_test.dart`

**Interfaces:**
- Consumes: `_recordNews()` from Task 2.
- Produces: complete news semantics — Task 9's integration tests rely on merges and delta traffic resetting the cadence.

- [ ] **Step 1: Write the failing tests** (append to the pacing test group)

```dart
    test('merged entries are news: the interval snaps back', () async {
      final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 500));
      final channelId = ChannelId('ch');
      final streamId = StreamId('s');
      await h.createChannelWithStream(channelId, streamId);
      h.engine.start();
      for (var i = 0; i < 6; i++) {
        await h.engine.performGossipRound();
      }
      expect(h.engine.effectiveGossipInterval,
          greaterThan(const Duration(seconds: 1)));

      // A peer-authored entry arriving as an unsolicited push merges and
      // must reset the cadence.
      await h.deliverDeltaResponse(
        from: peer,
        channelId: channelId,
        streamId: streamId,
        entries: [
          LogEntry(
            author: peer.id,
            sequence: 1,
            timestamp: Hlc(1, 0),
            payload: Uint8List.fromList([7]),
          ),
        ],
      );

      expect(h.engine.effectiveGossipInterval, const Duration(seconds: 1));
      h.engine.stop();
    });

    test('an inbound DeltaRequest is news (the peer is pulling from us)',
        () async {
      final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 500));
      final channelId = ChannelId('ch');
      final streamId = StreamId('s');
      await h.createChannelWithStream(channelId, streamId);
      h.engine.start();
      for (var i = 0; i < 6; i++) {
        await h.engine.performGossipRound();
      }
      expect(h.engine.effectiveGossipInterval,
          greaterThan(const Duration(seconds: 1)));

      await h.deliverDeltaRequest(
        from: peer, channelId: channelId, streamId: streamId);

      expect(h.engine.effectiveGossipInterval, const Duration(seconds: 1));
      h.engine.stop();
    });

    test('syncWithPeer (join/reconnect) is news', () async {
      final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 500));
      h.engine.start();
      for (var i = 0; i < 6; i++) {
        await h.engine.performGossipRound();
      }
      await h.engine.syncWithPeer(peer.id);
      expect(h.engine.effectiveGossipInterval, const Duration(seconds: 1));
      h.engine.stop();
    });

    test('peer removal (clearPendingRequestsForPeer) is news', () async {
      final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 500));
      h.engine.start();
      for (var i = 0; i < 6; i++) {
        await h.engine.performGossipRound();
      }
      h.engine.clearPendingRequestsForPeer(peer.id);
      expect(h.engine.effectiveGossipInterval, const Duration(seconds: 1));
      h.engine.stop();
    });
```

If the harness lacks `createChannelWithStream` / `deliverDeltaResponse` /
`deliverDeltaRequest` helpers, add thin ones to
`gossip_engine_test_harness.dart` following its existing style: create a
`ChannelAggregate`, call `engine.setChannels`, and deliver codec-encoded
messages onto `h.localPort` via the bus the way
`gossip_engine_message_handling_test.dart` does. Helpers are test code —
still commit them with this task.

- [ ] **Step 2: Run to verify failure**

Run: `dart test test/protocol/gossip_engine_pacing_test.dart`
Expected: the four new tests FAIL (interval stays grown).

- [ ] **Step 3: Implement** — one `_recordNews()` call per site:

  - `_mergeDeltaResponse` (~1582, next to `_mergedBatchCount++`): after a
    non-empty merge — `_recordNews();`
  - `_sendDeltaRequests` (~1166): at the top,
    `if (requests.isNotEmpty) _recordNews();`
  - `_handleIncomingMessage` `DeltaRequest` branch (~843): before handling —
    `_recordNews();`
  - `handleDeltaRequest` (~1353): after `_fitDeltaToBudget`,
    `if (fitted.isNotEmpty) _recordNews();` (serving data is news; empty
    responses are not)
  - `syncWithPeer` (~743): after the `_isRunning` guard — `_recordNews();`
  - `clearPendingRequestsForPeer` (~1623): first line — `_recordNews();`

- [ ] **Step 4: Run to verify pass + neighbors**

Run: `dart test test/protocol/` → all green.

- [ ] **Step 5: Commit**

```bash
git add lib/src/protocol/gossip_engine.dart test/protocol/gossip_engine_pacing_test.dart test/protocol/gossip_engine_test_harness.dart
git commit -m "feat(gossip): complete news triggers for quiescence pacing"
```

---

### Task 4: Gossip engine — responder-side exchange recording + recency suppression

**Files:**
- Modify: `packages/gossip/lib/src/protocol/gossip_engine.dart` (`_handleIncomingMessage` DigestRequest branch ~790; `performGossipRound` candidate filter ~591)
- Test: extend `packages/gossip/test/protocol/gossip_engine_pacing_test.dart` (new group `recency suppression`)

**Interfaces:**
- Consumes: `peerRegistry.updatePeerAntiEntropy(NodeId, int)` (exists), `Peer.lastAntiEntropyMs` (exists).
- Produces: rounds that send nothing when every candidate is fresh — Task 9's idle integration test depends on this.

- [ ] **Step 1: Write the failing tests**

```dart
  group('GossipEngine recency suppression', () {
    test('handling an inbound DigestRequest records the exchange', () async {
      final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
      final peer = h.addPeer('peer1');
      h.engine.startListening(const {});
      await h.deliverDigestRequest(from: peer); // empty digests are fine

      final recorded =
          h.peerRegistry.getPeer(peer.id)!.lastAntiEntropyMs;
      expect(recorded, isNotNull,
          reason: 'a reciprocated exchange must count as coverage '
              '(missing half of WIRE4-1)');
    });

    test('a round skips a peer whose exchange is fresher than the '
        'current interval', () async {
      final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 500));
      h.engine.start();

      // Mark the peer as exchanged-with "now".
      h.peerRegistry.updatePeerAntiEntropy(peer.id, h.timePort.nowMs);
      final sentBefore = peer.receivedMessages.length;

      await h.engine.performGossipRound();

      expect(peer.receivedMessages.length, sentBefore,
          reason: 'all candidates fresh: the round must send nothing');
      h.engine.stop();
    });

    test('a stale peer is still gossiped with', () async {
      final h = GossipEngineTestHarness(adaptiveTimingEnabled: true);
      final peer = h.addPeer('peer1');
      h.peerRegistry.recordPeerRtt(peer.id, const Duration(milliseconds: 500));
      h.engine.start();

      // Exchange recorded far in the past relative to the interval.
      h.peerRegistry.updatePeerAntiEntropy(
          peer.id, h.timePort.nowMs - 60000);
      final sentBefore = peer.receivedMessages.length;

      await h.engine.performGossipRound();

      expect(peer.receivedMessages.length, greaterThan(sentBefore));
      h.engine.stop();
    });
  });
```

(Use the harness's existing peer-message capture; if `GossipTestPeer` names
it differently — e.g. a `received` list or a port helper — use that name;
the assertion is "no bytes reached the peer".)

- [ ] **Step 2: Run to verify failure**

Run: `dart test test/protocol/gossip_engine_pacing_test.dart`
Expected: test 1 FAILS (`lastAntiEntropyMs` null); test 2 FAILS (round sends a DigestRequest).

- [ ] **Step 3: Implement**

(a) `_handleIncomingMessage`, `DigestRequest` branch (~line 790), before
building the response:

```dart
        // A reciprocated exchange is coverage for BOTH sides: record it
        // so our own selector/suppression see this peer as fresh
        // (missing half of WIRE4-1).
        peerRegistry.updatePeerAntiEntropy(message.sender, nowMs);
```

(b) `performGossipRound` (~591): extend the existing candidate filter —
congestion AND staleness:

```dart
    final interval = effectiveGossipInterval.inMilliseconds;
    final nowMs = timePort.nowMs;
    final candidates = reachable
        .where(
          (p) =>
              messagePort.pendingSendCount(p.id) <=
                  _perPeerCongestionThreshold &&
              // Recency suppression (time-based — deliberately NOT
              // cached-VV state): skip peers we exchanged with inside
              // the current interval. Worst case of a wrong skip is one
              // interval of delay.
              (p.lastAntiEntropyMs == null ||
                  nowMs - p.lastAntiEntropyMs! >= interval),
        )
        .toList();
```

The existing "all congested → skip" log branch now also covers
"all fresh"; update its message to `'Skipping gossip round: no stale,
uncongested peers'`.

- [ ] **Step 4: Run to verify pass + full protocol suite**

Run: `dart test test/protocol/` → all green. Watch specifically
`gossip_engine_partner_selection_test.dart` and
`gossip_engine_scheduling_test.dart`; if a test drove rounds against
just-synced peers it may need its scenario's timestamps aged — age the
timestamps, do not weaken the assertion.

- [ ] **Step 5: Commit**

```bash
git add lib/src/protocol/gossip_engine.dart test/protocol/gossip_engine_pacing_test.dart
git commit -m "feat(gossip): responder exchange recording + round recency suppression (WIRE4-1)"
```

---

### Task 5: Gossip engine — dominance-filtered DigestResponse (WIRE4-5)

**Files:**
- Modify: `packages/gossip/lib/src/protocol/gossip_engine.dart` (`handleDigestRequest` ~1054-1087)
- Test: `packages/gossip/test/protocol/gossip_engine_digest_filter_test.dart` (new)

**Interfaces:**
- Consumes: `VersionVector.dominates` (exists, used at ~1279).
- Produces: converged responses with empty `digests` — Task 9's byte-count assertions rely on it.

- [ ] **Step 1: Write the failing tests**

```dart
// packages/gossip/test/protocol/gossip_engine_digest_filter_test.dart
import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/version_vector.dart';
import 'package:gossip/src/protocol/messages/digest_request.dart';
import 'package:gossip/src/protocol/values/channel_digest.dart';
import 'package:gossip/src/protocol/values/stream_digest.dart';

import 'gossip_engine_test_harness.dart';

/// WIRE4-5: a converged DigestResponse used to echo back version vectors
/// the requester provably already had — the single largest pure-redundancy
/// item on the idle wire. Pairs the requester dominates are now omitted.
void main() {
  group('DigestResponse dominance filter', () {
    test('omits streams the requester already dominates', () async {
      final h = GossipEngineTestHarness();
      final channelId = ChannelId('ch');
      final streamId = StreamId('s');
      final channel = await h.createChannelWithStream(channelId, streamId);
      // Local store: entry seq 1 by us -> our VV = {local: 1}.
      await h.appendLocalEntry(channelId, streamId, sequence: 1);

      // Requester advertises {local: 1} — it has everything we have.
      final request = DigestRequest(
        sender: h.addPeer('peer1').id,
        digests: [
          ChannelDigest(channelId: channelId, streams: [
            StreamDigest(
              streamId: streamId,
              version: VersionVector({h.localNode: 1}),
            ),
          ]),
        ],
      );

      final response = await h.engine.handleDigestRequest(
        request, [channel]);

      expect(response.digests, isEmpty,
          reason: 'the requester dominates us: echoing our vector back '
              'is pure redundancy');
    });

    test('includes streams where the requester is behind', () async {
      final h = GossipEngineTestHarness();
      final channelId = ChannelId('ch');
      final streamId = StreamId('s');
      final channel = await h.createChannelWithStream(channelId, streamId);
      await h.appendLocalEntry(channelId, streamId, sequence: 1);
      await h.appendLocalEntry(channelId, streamId, sequence: 2);

      // Requester only has seq 1 — it must be told about our state.
      final request = DigestRequest(
        sender: h.addPeer('peer1').id,
        digests: [
          ChannelDigest(channelId: channelId, streams: [
            StreamDigest(
              streamId: streamId,
              version: VersionVector({h.localNode: 1}),
            ),
          ]),
        ],
      );

      final response = await h.engine.handleDigestRequest(
        request, [channel]);

      expect(response.digests, hasLength(1));
      expect(response.digests.single.streams.single.version[h.localNode], 2);
    });
  });
}
```

(Use the harness's existing channel/append helpers or the ones added in
Task 3; `handleDigestRequest` is public — see
`gossip_engine_push_pull_test.dart` for prior direct-call usage.)

- [ ] **Step 2: Run to verify failure**

Run: `dart test test/protocol/gossip_engine_digest_filter_test.dart`
Expected: test 1 FAILS (response includes the stream).

- [ ] **Step 3: Implement** — in `handleDigestRequest`'s inner loop
(~1069-1082), after computing `version`:

```dart
        // Dominance filter (WIRE4-5): if the requester's vector already
        // covers ours, echoing it back is pure redundancy. Safe: the
        // requester pulls only when the response shows us ahead, and the
        // responder-behind direction is our own reciprocal pull.
        if (streamDigest.version.dominates(version)) continue;
```

- [ ] **Step 4: Run to verify pass + neighbors**

Run: `dart test test/protocol/` → all green (`gossip_engine_push_pull_test`
and `gossip_engine_message_handling_test` exercise this path; genuinely
divergent fixtures keep their digests).

- [ ] **Step 5: Commit**

```bash
git add lib/src/protocol/gossip_engine.dart test/protocol/gossip_engine_digest_filter_test.dart
git commit -m "feat(gossip): dominance-filter the DigestResponse (WIRE4-5)"
```

---

### Task 6: Failure detector — pacer + quiet/reset wiring

**Files:**
- Modify: `packages/gossip/lib/src/protocol/failure_detector.dart` (fields ~150; `effectiveProbeInterval` ~260; `performProbeRound` ~328; `_evaluateProbeOutcome` ~647; `_handleProbeFailure` ~701; `probeNewPeer` ~372; `_recordPeerContact` ~948)
- Test: `packages/gossip/test/protocol/failure_detector_pacing_test.dart` (new)

**Interfaces:**
- Consumes: `QuiescencePacer` from Task 1.
- Produces: `effectiveProbeInterval` paced toward 30 s; Task 7's suppression reads it.

- [ ] **Step 1: Write the failing tests**

```dart
// packages/gossip/test/protocol/failure_detector_pacing_test.dart
import 'package:test/test.dart';

import 'failure_detector_test_harness.dart';

/// Two-tier pacing for the probe loop: all-healthy rounds stretch the
/// interval toward the existing 30s cap; any miss or membership change
/// snaps it back. (Owner decision: minutes-scale half-open detection in
/// a deep-idle mesh is acceptable — hard disconnects surface via the
/// transport instantly.)
void main() {
  group('FailureDetector quiescence pacing', () {
    test('answered probe rounds grow the effective interval', () async {
      final h = FailureDetectorTestHarness();
      final peer = h.addAnsweringPeer('peer1'); // auto-acks pings
      final base = h.detector.effectiveProbeInterval;

      for (var i = 0; i < 4; i++) {
        await h.detector.performProbeRound();
      }

      expect(h.detector.effectiveProbeInterval, greaterThan(base));
    });

    test('a missed probe snaps the interval back to base', () async {
      final h = FailureDetectorTestHarness();
      h.addAnsweringPeer('peer1');
      final base = h.detector.effectiveProbeInterval;
      for (var i = 0; i < 4; i++) {
        await h.detector.performProbeRound();
      }
      expect(h.detector.effectiveProbeInterval, greaterThan(base));

      h.addSilentPeer('deadpeer'); // never acks
      // Rounds until the silent peer is probed and misses.
      for (var i = 0; i < 3; i++) {
        await h.detector.performProbeRound();
      }

      expect(h.detector.effectiveProbeInterval, base);
    });

    test('a static probeInterval bypasses the pacer', () async {
      final h = FailureDetectorTestHarness(
        probeInterval: const Duration(seconds: 2),
      );
      h.addAnsweringPeer('peer1');
      for (var i = 0; i < 4; i++) {
        await h.detector.performProbeRound();
      }
      expect(h.detector.effectiveProbeInterval, const Duration(seconds: 2));
    });
  });
}
```

The harness (`failure_detector_test_harness.dart`) already builds a
detector over `InMemoryMessagePort`/`InMemoryTimePort` with auto-ack
`TestPeer`s; if helper names differ (`addPeer` + a responder flag rather
than `addAnsweringPeer`/`addSilentPeer`), use the harness's names — add
thin helpers if missing, mirroring `TestPeer`'s existing auto-responder.

- [ ] **Step 2: Run to verify failure**

Run: `dart test test/protocol/failure_detector_pacing_test.dart`
Expected: test 1 FAILS (interval static at base).

- [ ] **Step 3: Implement** — in `failure_detector.dart`:

(a) Import Task 1's pacer; add fields:

```dart
  /// Two-tier pacing for the probe loop (spec 2026-08-20).
  final QuiescencePacer _pacer =
      QuiescencePacer(ceiling: _maxProbeInterval);
```

(b) `effectiveProbeInterval` (~260): static branch unchanged; adaptive
branch becomes `return _pacer.apply(<existing clamped baseInterval>);`.

(c) `performProbeRound` (~328): track the round's outcome. The round is
quiet when the probe was answered (direct or late) — grow; a full miss
resets via `_handleProbeFailure`:

```dart
      if (!gotDirectAck) {
        final gotIndirectAck = await _performIndirectPing(peer.id);
        _evaluateProbeOutcome(peer.id, sequence, pending, gotIndirectAck);
      } else {
        _pacer.quietRound();
      }
```

and in `_evaluateProbeOutcome` (~647): the recovered/late-ack path calls
`_pacer.quietRound();` before returning; the failure path falls through to
`_handleProbeFailure`, which gains `_pacer.news();` as its first line.

(d) Membership/news resets: `probeNewPeer` (~372) first line
`_pacer.news();`; `_recordPeerContact` (~948) — when
`oldStatus != null && oldStatus != PeerStatus.reachable` (a recovery
transition) also `_pacer.news();`.

- [ ] **Step 4: Run to verify pass + full detector suite**

Run: `dart test test/protocol/failure_detector_pacing_test.dart` → PASS.
Run: `dart test test/protocol/` → all green (the adaptive-timeout and
scheduling tests assert the base formula on fresh detectors — zero quiet
rounds — so they hold).

- [ ] **Step 5: Commit**

```bash
git add lib/src/protocol/failure_detector.dart test/protocol/failure_detector_pacing_test.dart test/protocol/failure_detector_test_harness.dart
git commit -m "feat(gossip): quiescence pacing for the probe loop (WIRE4-4)"
```

---

### Task 7: Failure detector — probe suppression by recent contact (WIRE4-3)

**Files:**
- Modify: `packages/gossip/lib/src/protocol/failure_detector.dart` (`selectRandomPeer` ~477-503; `performProbeRound` ~338)
- Test: `packages/gossip/test/protocol/failure_detector_suppression_test.dart` (new)

**Interfaces:**
- Consumes: `Peer.lastContactMs` (exists; currently write-only), `effectiveProbeInterval` from Task 6.
- Produces: rounds that send nothing when all peers are fresh; an all-fresh round counts as quiet.

- [ ] **Step 1: Write the failing tests**

```dart
// packages/gossip/test/protocol/failure_detector_suppression_test.dart
import 'package:test/test.dart';

import 'failure_detector_test_harness.dart';

/// WIRE4-3: gossip traffic is liveness evidence. lastContactMs — updated
/// by every inbound message, previously write-only — finally gets a
/// reader: peers heard from within the current probe interval are not
/// probed, and an all-fresh round sends nothing.
void main() {
  group('FailureDetector probe suppression', () {
    test('a peer heard from within the interval is not selected', () {
      final h = FailureDetectorTestHarness();
      final fresh = h.addAnsweringPeer('fresh');
      final stale = h.addAnsweringPeer('stale');
      h.peerRegistry.updatePeerContact(fresh.id, h.timePort.nowMs);
      // stale's lastContactMs stays 0 (never heard from).

      for (var i = 0; i < 4; i++) {
        expect(h.detector.selectRandomPeer()!.id, stale.id,
            reason: 'only the stale peer needs a probe');
      }
    });

    test('when every peer is fresh, no probe fires at all', () async {
      final h = FailureDetectorTestHarness();
      final a = h.addAnsweringPeer('a');
      final b = h.addAnsweringPeer('b');
      h.peerRegistry.updatePeerContact(a.id, h.timePort.nowMs);
      h.peerRegistry.updatePeerContact(b.id, h.timePort.nowMs);

      expect(h.detector.selectRandomPeer(), isNull);

      final sentBefore = h.sentMessageCount;
      await h.detector.performProbeRound();
      expect(h.sentMessageCount, sentBefore,
          reason: 'an all-fresh round must be radio silence');
    });

    test('suppression does not mark fresh peers as failed', () async {
      final h = FailureDetectorTestHarness();
      final a = h.addAnsweringPeer('a');
      h.peerRegistry.updatePeerContact(a.id, h.timePort.nowMs);

      for (var i = 0; i < 10; i++) {
        await h.detector.performProbeRound();
      }

      expect(h.peerRegistry.getPeer(a.id)!.failedProbeCount, 0);
    });
  });
}
```

(`h.sentMessageCount` — if the harness lacks it, add a counter over the
local port's sends, mirroring how existing detector tests count pings.)

- [ ] **Step 2: Run to verify failure**

Run: `dart test test/protocol/failure_detector_suppression_test.dart`
Expected: test 1 FAILS (fresh peer gets selected).

- [ ] **Step 3: Implement** — in `selectRandomPeer` (~477), extend the
probable filter:

```dart
    final nowMs = timePort.nowMs;
    final intervalMs = effectiveProbeInterval.inMilliseconds;
    final probable = peerRegistry.probablePeers.where((p) {
      final holdUntil = _probingHeldUntil[p.id];
      if (holdUntil != null && nowMs < holdUntil) return false;
      // Suppression (WIRE4-3): any inbound message already proved this
      // peer alive within the current interval — a probe adds nothing.
      if (nowMs - p.lastContactMs < intervalMs) return false;
      return true;
    }).toList();
    if (probable.isEmpty) return null;
```

And in `performProbeRound` (~338-340), an all-suppressed round is quiet:

```dart
    final peer = selectRandomPeer();
    if (peer == null) {
      // Nothing needs probing (empty registry or everyone fresh) —
      // that is quiescence, not a stall.
      if (peerRegistry.probablePeers.isNotEmpty) _pacer.quietRound();
      return;
    }
```

(`lastContactMs` defaults to 0, so never-heard-from peers are maximally
stale — cold start probes normally.)

- [ ] **Step 4: Run to verify pass + full suite**

Run: `dart test test/protocol/failure_detector_suppression_test.dart` →
PASS. Run: `dart test` (whole package) → all green. Existing detector
tests drive probes at peers with `lastContactMs` 0 or aged clocks, so
selection tests hold; if one seeds fresh contact then expects a probe,
age its clock via `timePort` — do not weaken its assertion.

- [ ] **Step 5: Commit**

```bash
git add lib/src/protocol/failure_detector.dart test/protocol/failure_detector_suppression_test.dart test/protocol/failure_detector_test_harness.dart
git commit -m "feat(gossip): suppress probes for recently-heard peers (WIRE4-3)"
```

---

### Task 8: Integration tests — idle quiescence end to end

**Files:**
- Create: `packages/gossip/test/integration/sync/idle_quiescence_test.dart`
- Consumes: `TestNetwork` DSL (`test/support/test_network.dart`): `corruptLink` identity-tap (message counting), `dropNext`, `runRounds`.

**Interfaces:**
- Consumes: everything from Tasks 1-7 through the public `Coordinator`.
- Produces: the spec's acceptance evidence.

- [ ] **Step 1: Write the failing tests**

```dart
// packages/gossip/test/integration/sync/idle_quiescence_test.dart
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';

import '../../support/test_network.dart';

/// Spec 2026-08-20 acceptance: an idle converged network's traffic decays
/// (structural inequality, not wall rates — InMemoryTimePort quantizes
/// RTT to the advance step), news snaps it back, and a lost push is
/// repaired within the 30s ceiling.
void main() {
  final channelId = ChannelId('quiesce-ch');
  final streamId = StreamId('quiesce-s');

  /// Counts messages crossing both directions of the a<->b link.
  int tapBoth(TestNetwork network, List<int> counter) {
    network.corruptLink('a', 'b', (bytes) {
      counter[0]++;
      return bytes;
    });
    network.corruptLink('b', 'a', (bytes) {
      counter[0]++;
      return bytes;
    });
    return counter[0];
  }

  test('idle traffic decays after convergence and stays low', () async {
    final network = await TestNetwork.create(['a', 'b']);
    await network.connectAll();
    await network.setupChannel(channelId, streamId);
    await network.startAll();
    await network['a'].write(channelId, streamId, [1]);
    await network.runRounds(10);
    expect(await network.hasConverged(channelId, streamId), isTrue);

    final counter = [0];
    tapBoth(network, counter);

    await network.runRounds(30); // early idle window
    final early = counter[0];
    await network.runRounds(60); // let backoff take hold
    counter[0] = 0;
    await network.runRounds(30); // late idle window, same width as early
    final late = counter[0];

    expect(late, lessThan(early),
        reason: 'quiescence pacing must reduce idle traffic over time');
    await network.dispose();
  });

  test('a write snaps the network back and converges promptly', () async {
    final network = await TestNetwork.create(['a', 'b']);
    await network.connectAll();
    await network.setupChannel(channelId, streamId);
    await network.startAll();
    await network['a'].write(channelId, streamId, [1]);
    await network.runRounds(10);
    await network.runRounds(90); // deep idle: both loops at ceiling

    await network['a'].write(channelId, streamId, [2]);
    await network.runRounds(5);

    expect(await network.hasConverged(channelId, streamId), isTrue,
        reason: 'news must snap the cadence back — the reactive push '
            'plus a reset periodic round converge fast even from deep idle');
    await network.dispose();
  });

  test('a lost reactive push is repaired within the 30s ceiling', () async {
    final network = await TestNetwork.create(['a', 'b']);
    await network.connectAll();
    await network.setupChannel(channelId, streamId);
    await network.startAll();
    await network['a'].write(channelId, streamId, [1]);
    await network.runRounds(10);
    await network.runRounds(90); // deep idle

    // Swallow the push (and its debounced flush is one message).
    network.dropNext('a', 'b', count: 1);
    await network['a'].write(channelId, streamId, [2]);

    // Within the ceiling (30 simulated seconds), anti-entropy repairs it.
    await network.runRounds(35);
    expect(await network.hasConverged(channelId, streamId), isTrue,
        reason: 'the safety net must repair a lost push within 30s');
    await network.dispose();
  });

  test('deep idleness never marks healthy peers unreachable', () async {
    final network = await TestNetwork.create(['a', 'b']);
    await network.connectAll();
    await network.setupChannel(channelId, streamId);
    await network.startAll();
    await network.runRounds(120);

    expect(network['a'].reachablePeers, hasLength(1));
    expect(network['b'].reachablePeers, hasLength(1));
    await network.dispose();
  });
}
```

- [ ] **Step 2: Run — tests 1 and 3 must FAIL before Tasks 2-7 land**

If executing this plan in order, Tasks 2-7 are already done — then run
these to confirm they PASS (they are the acceptance gate, written last to
avoid a long red period). If any fails, the bug is in Tasks 2-7; debug
there, do not weaken these assertions.

Run: `dart test test/integration/sync/idle_quiescence_test.dart`

- [ ] **Step 3: Full gates**

Run: `dart test && dart analyze` → 0 failures, 0 issues.
Then the sibling packages (engine behavior change is wire-visible):
`cd ../gossip_bluey && flutter test` → green.

- [ ] **Step 4: Commit**

```bash
git add test/integration/sync/idle_quiescence_test.dart
git commit -m "test(gossip): idle-quiescence acceptance — decay, snap-back, ceiling repair"
```

---

### Task 9: Documentation — ADR-013 two-tier section, stale-claims cleanup

**Files:**
- Modify: `packages/gossip/docs/adr/013-adaptive-timing.md` (add the idle/active distinction + pacer + owner decisions)
- Modify: `packages/gossip/docs/adr/008-anti-entropy-gossip-protocol.md` (line ~76: `Gossip interval: 200ms (configurable)` → the adaptive reality; Consequences "Periodic overhead" bullet → note the 30 s idle backoff)
- Modify: `packages/gossip/lib/src/protocol/gossip_engine.dart` doc comments at lines ~37 (`**Step 1: Digest Request (every 200ms)**`) and ~573 (`/// Performs a single gossip round (called every 200ms).`) and `lib/src/infrastructure/ports/time_port.dart:21`
- No test cycle (docs only), but run `dart analyze` (doc comments can break `comment_references`).

- [ ] **Step 1: ADR-013 addition** — append a section:

```markdown
## Amendment (2026-08-20): Two-Tier Pacing

The original design adapted both intervals to LATENCY only, so a
healthier link produced more idle traffic and a converged network never
went quiet (audit WIRE4-2/4). Both loops now feed a pure
`QuiescencePacer` (domain service): rounds that carry no news stretch
the latency-derived base interval by 1.5x per quiet round toward a 30 s
ceiling; any news (local append, merge, delta traffic, membership
change, missed probe) snaps it back to base. Owner decisions: 30 s
ceiling, not configurable; time-based suppression only (no cached-VV
skipping); minutes-scale detection of half-open links in a deep-idle
mesh is accepted — hard disconnects surface via the transport instantly.
Static `gossipInterval`/`probeInterval` overrides bypass the pacer.
```

- [ ] **Step 2: Fix the stale "200 ms" claims** at the four listed sites —
replace with "adaptive: 2× median RTT, clamped 100 ms–5 s active, backed
off to 30 s when idle (see ADR-013 amendment)".

- [ ] **Step 3: Verify + commit**

Run: `dart analyze` → 0 issues.

```bash
git add packages/gossip/docs/adr/ packages/gossip/lib/src/protocol/gossip_engine.dart packages/gossip/lib/src/infrastructure/ports/time_port.dart
git commit -m "docs(gossip): ADR-013 two-tier pacing amendment; retire stale 200ms claims"
```

---

## Self-Review Notes

- **Spec coverage:** pacer (T1), engine pacing + news (T2, T3), responder
  recording + suppression (T4), dominance filter (T5), detector pacing
  (T6), probe suppression (T7), integration acceptance (T8), docs (T9).
  Spec §5 out-of-scope items appear in no task. ✓
- **Known adaptation points (deliberate, not placeholders):** harness
  helper names (`addAnsweringPeer`, `deliverDeltaRequest`,
  `sentMessageCount`) may need thin additions to the two existing
  harnesses — the assertions are the contract; helpers mirror existing
  harness style.
- **Type consistency:** `QuiescencePacer` API is identical in T1/T2/T6;
  `_recordNews()` defined in T2, called in T3/T4; ceilings both
  `Duration(seconds: 30)` (detector reuses `_maxProbeInterval`). ✓
