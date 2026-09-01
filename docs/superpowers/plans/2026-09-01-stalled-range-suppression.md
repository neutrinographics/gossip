# Stalled-Range Suppression Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop re-requesting an author's range a peer has already failed to
supply — per-author suppression with doubling re-probe backoff — per the
approved spec, in its pure-DDD shape.

**Architecture:** A new pure domain aggregate `StalledRangeRegistry`
(`sync/domain/aggregates/`) rooted over `StalledRange` entities
(`sync/domain/entities/`, new sublayer — membership precedent:
`peer_registry.dart`/`peer.dart`). Fully deterministic: no ports, time passed
in as `nowMs`; strict CQS (`shapeSince` pure query owning the never-lower max;
`recordGap`/`evictSatisfied`/`clearForPeer`/`clearAll` commands). The engine
constructs it beside `PendingPullTracker` and shares the instance with
`DeltaMerger`, which records gaps (solicited only) and shapes continuations.

**Tech Stack:** Dart, package `gossip`; existing harnesses:
`GossipEngineTestHarness`, `delta_merger_test.dart`'s `build()`,
`TestNetwork` DSL.

**Spec:** `docs/superpowers/specs/2026-08-31-stalled-range-suppression-design.md`
(approved 2026-09-01 with the pure-DDD reshape and single-owner never-lower
rule — the "Decisions from the owner's review" section binds).

## Global Constraints

- Branch: `feature/stalled-range-suppression` off local `main` @ 73dd997.
  Baseline: **MEASURE at T1 step 0** (`cd packages/gossip && dart test`),
  never inherit.
- Per-task gates: `dart test` in `packages/gossip` at the chain value
  (includes `test/architecture/boundary_test.dart`) + `dart analyze` clean.
  Final gate: `melos run test && melos run analyze` across the monorepo.
- TDD red-green per task; one commit per task; commit style: short
  imperative + Claude trailer (this repo signs — commit controller-side if a
  subagent hits locked signing).
- Pure DDD is the house standard (owner ruling 2026-09-01): the aggregate
  stays dependency-free and deterministic; `shapeSince` must not mutate;
  no `TimePort` inside the domain objects.
- One class per file; imports in `package:gossip/src/...` form (the boundary
  test rejects relative imports); doc comments state intent/contract, never
  implementation steps.
- New files under `sync/domain/{aggregates,entities}` need no boundary-test
  registration; add them to the `lib/src/sync/sync.dart` barrel's grouped
  export lists (convention, unenforced).
- `VersionVector` facts: construction normalizes away zero entries; modified
  copies are built as `VersionVector({...vv.entries, author: value})`; no
  `copyWith`.

---

### Task T1: `StalledRange` entity + `StalledRangeRegistry` aggregate

**Files:**
- Create: `packages/gossip/lib/src/sync/domain/entities/stalled_range.dart`
- Create: `packages/gossip/lib/src/sync/domain/aggregates/stalled_range_registry.dart`
- Modify: `packages/gossip/lib/src/sync/sync.dart` (barrel exports)
- Test: `packages/gossip/test/sync/domain/aggregates/stalled_range_registry_test.dart`

**Interfaces:**
- Consumes: `NodeId`, `ChannelId`, `StreamId`, `VersionVector` (shared kernel).
- Produces (later tasks rely on these exact signatures):
  - `StalledRangeRegistry({Duration initialBackoff = const Duration(seconds: 30), Duration maxBackoff = const Duration(minutes: 10)})`
  - `VersionVector shapeSince(NodeId peer, ChannelId channelId, StreamId streamId, VersionVector base, {VersionVector? digestCeiling, required int nowMs})`
  - `void recordGap(NodeId peer, ChannelId channelId, StreamId streamId, NodeId author, {required int expectedNext, required int advertisedMax, required int nowMs})`
  - `void evictSatisfied(NodeId peer, ChannelId channelId, StreamId streamId, VersionVector ourVersion)`
  - `void clearForPeer(NodeId peer)` / `void clearAll()`

- [ ] **Step 0: Baseline + branch**

```bash
cd /Users/joel/git/neutrinographics/gossip
git checkout -b feature/stalled-range-suppression main
cd packages/gossip && dart test   # record the measured count
```

- [ ] **Step 1: Write the failing registry tests**

`stalled_range_registry_test.dart` (pure — ints for time, no fakes):

```dart
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/sync/domain/aggregates/stalled_range_registry.dart';
import 'package:test/test.dart';

void main() {
  final peer = NodeId('peer-1');
  final otherPeer = NodeId('peer-2');
  final channelId = ChannelId('ch');
  final streamId = StreamId('st');
  final author = NodeId('author-x');
  final otherAuthor = NodeId('author-y');

  StalledRangeRegistry registry() => StalledRangeRegistry();

  group('shapeSince', () {
    test('a recorded gap shapes the author to the never-lower max', () {
      final r = registry();
      r.recordGap(peer, channelId, streamId, author,
          expectedNext: 6, advertisedMax: 208, nowMs: 0);

      final base = VersionVector({author: 5, otherAuthor: 3});
      final shaped = r.shapeSince(peer, channelId, streamId, base,
          digestCeiling: VersionVector({author: 210}), nowMs: 1000);

      expect(shaped[author], 210,
          reason: 'digest ceiling above advertisedMax wins the max');
      expect(shaped[otherAuthor], 3, reason: 'other authors untouched');

      final noCeiling =
          r.shapeSince(peer, channelId, streamId, base, nowMs: 1000);
      expect(noCeiling[author], 208, reason: 'advertisedMax without a digest');
    });

    test('other peers and streams are unaffected', () {
      final r = registry();
      r.recordGap(peer, channelId, streamId, author,
          expectedNext: 6, advertisedMax: 208, nowMs: 0);

      final base = VersionVector({author: 5});
      expect(r.shapeSince(otherPeer, channelId, streamId, base, nowMs: 0),
          base);
      expect(
          r.shapeSince(peer, channelId, StreamId('other'), base, nowMs: 0),
          base);
    });

    test('is a pure query: stale entries contribute nothing and repeated '
        'calls return the same answer', () {
      final r = registry();
      r.recordGap(peer, channelId, streamId, author,
          expectedNext: 6, advertisedMax: 208, nowMs: 0);

      // Our coverage moved past the recorded expectation (range arrived
      // from elsewhere): the entry is stale and must not shape, even
      // though nothing has evicted it.
      final advanced = VersionVector({author: 150});
      final first =
          r.shapeSince(peer, channelId, streamId, advanced, nowMs: 0);
      final second =
          r.shapeSince(peer, channelId, streamId, advanced, nowMs: 0);
      expect(first, advanced);
      expect(second, advanced);

      // And the non-stale view still shapes afterwards — no state changed.
      final base = VersionVector({author: 5});
      expect(r.shapeSince(peer, channelId, streamId, base, nowMs: 0)[author],
          208);
    });

    test('an open probe window unshapes the author', () {
      final r = registry();
      r.recordGap(peer, channelId, streamId, author,
          expectedNext: 6, advertisedMax: 208, nowMs: 0);
      final base = VersionVector({author: 5});

      // Before the window: suppressed.
      expect(
          r.shapeSince(peer, channelId, streamId, base, nowMs: 29_999)[author],
          208);
      // Window open at initialBackoff (30s): the request IS the probe.
      expect(
          r.shapeSince(peer, channelId, streamId, base, nowMs: 30_000)[author],
          5);
    });

    test('re-recording doubles the backoff up to the cap', () {
      final r = registry();
      final base = VersionVector({author: 5});
      r.recordGap(peer, channelId, streamId, author,
          expectedNext: 6, advertisedMax: 208, nowMs: 0);
      // Probe at 30s fails; re-record doubles to 60s.
      r.recordGap(peer, channelId, streamId, author,
          expectedNext: 6, advertisedMax: 209, nowMs: 30_000);
      expect(
          r.shapeSince(peer, channelId, streamId, base, nowMs: 89_999)[author],
          209,
          reason: 'still suppressed inside the doubled window');
      expect(
          r.shapeSince(peer, channelId, streamId, base, nowMs: 90_000)[author],
          5);

      // Many re-records: the window never exceeds maxBackoff (10min).
      var t = 90_000;
      for (var i = 0; i < 10; i++) {
        r.recordGap(peer, channelId, streamId, author,
            expectedNext: 6, advertisedMax: 209, nowMs: t);
        t += 600_000; // jump a full cap each time
      }
      r.recordGap(peer, channelId, streamId, author,
          expectedNext: 6, advertisedMax: 209, nowMs: t);
      expect(
          r
              .shapeSince(peer, channelId, streamId, base,
                  nowMs: t + 600_000)[author],
          5,
          reason: 'probe window must open within maxBackoff');
    });
  });

  group('commands', () {
    test('evictSatisfied removes exactly the passed-expectation entries', () {
      final r = registry();
      r.recordGap(peer, channelId, streamId, author,
          expectedNext: 6, advertisedMax: 208, nowMs: 0);
      r.recordGap(peer, channelId, streamId, otherAuthor,
          expectedNext: 3, advertisedMax: 40, nowMs: 0);

      // author's range arrived (coverage now 150); otherAuthor still stalled.
      r.evictSatisfied(
          peer, channelId, streamId, VersionVector({author: 150, otherAuthor: 2}));

      final base = VersionVector({author: 150, otherAuthor: 2});
      final shaped = r.shapeSince(peer, channelId, streamId, base, nowMs: 0);
      expect(shaped[author], 150, reason: 'evicted — no shaping');
      expect(shaped[otherAuthor], 40, reason: 'survivor still shapes');
    });

    test('clearForPeer and clearAll drop the right entries', () {
      final r = registry();
      r.recordGap(peer, channelId, streamId, author,
          expectedNext: 6, advertisedMax: 208, nowMs: 0);
      r.recordGap(otherPeer, channelId, streamId, author,
          expectedNext: 6, advertisedMax: 208, nowMs: 0);

      r.clearForPeer(peer);
      final base = VersionVector({author: 5});
      expect(r.shapeSince(peer, channelId, streamId, base, nowMs: 0), base);
      expect(
          r.shapeSince(otherPeer, channelId, streamId, base, nowMs: 0)[author],
          208);

      r.clearAll();
      expect(r.shapeSince(otherPeer, channelId, streamId, base, nowMs: 0),
          base);
    });
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd packages/gossip && dart test test/sync/domain/aggregates/stalled_range_registry_test.dart`
Expected: FAIL to compile (types don't exist).

- [ ] **Step 3: Implement the entity**

`stalled_range.dart`:

```dart
import 'dart:math';

import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';

/// One stalled author range: a peer answered a solicited pull with a
/// per-author sequence hole, so asking again is waste until the world
/// changes or the probe window opens.
///
/// Identity is `(peer, channelId, streamId, author)`. Transitions produce
/// new values ([rearmed]); nothing mutates in place.
class StalledRange {
  const StalledRange({
    required this.peer,
    required this.channelId,
    required this.streamId,
    required this.author,
    required this.expectedNext,
    required this.advertisedMax,
    required this.retryAtMs,
    required this.probeCount,
  });

  final NodeId peer;
  final ChannelId channelId;
  final StreamId streamId;
  final NodeId author;

  /// Our `ourVersion[author] + 1` when the gap was observed — the staleness
  /// sentinel: a different expectation means the world changed and this
  /// entry no longer describes it.
  final int expectedNext;

  /// The highest sequence the peer advertised for the author in the gapped
  /// response — asking "since this" makes the peer send nothing for the
  /// author.
  final int advertisedMax;

  /// When the next probe is allowed (epoch milliseconds).
  final int retryAtMs;

  /// How many times this stall has been re-confirmed; drives the backoff
  /// doubling.
  final int probeCount;

  bool isStale(VersionVector ourVersion) =>
      ourVersion[author] + 1 != expectedNext;

  bool isProbeDue(int nowMs) => nowMs >= retryAtMs;

  /// The doubled-backoff successor after a probe re-confirmed the gap.
  StalledRange rearmed({
    required int nowMs,
    required int advertisedMax,
    required int initialBackoffMs,
    required int maxBackoffMs,
  }) {
    var backoffMs = initialBackoffMs;
    for (var i = 0; i <= probeCount && backoffMs < maxBackoffMs; i++) {
      backoffMs = min(backoffMs * 2, maxBackoffMs);
    }
    return StalledRange(
      peer: peer,
      channelId: channelId,
      streamId: streamId,
      author: author,
      expectedNext: expectedNext,
      advertisedMax: advertisedMax,
      retryAtMs: nowMs + backoffMs,
      probeCount: probeCount + 1,
    );
  }
}
```

- [ ] **Step 4: Implement the aggregate root**

`stalled_range_registry.dart`:

```dart
import 'dart:math';

import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/sync/domain/entities/stalled_range.dart';

/// The stalled author ranges observed per peer, and the request shaping
/// they imply.
///
/// Fully deterministic and dependency-free: time arrives as `nowMs`
/// arguments, and [shapeSince] is a pure query — a stale entry contributes
/// nothing whether or not [evictSatisfied] has pruned it yet, so request
/// correctness never depends on eviction timing.
class StalledRangeRegistry {
  StalledRangeRegistry({
    this.initialBackoff = const Duration(seconds: 30),
    this.maxBackoff = const Duration(minutes: 10),
  });

  final Duration initialBackoff;
  final Duration maxBackoff;

  final Map<(NodeId, ChannelId, StreamId, NodeId), StalledRange> _ranges = {};

  /// The shaped `since` vector for a request to [peer] being built now.
  ///
  /// Owns the never-lower rule: a suppressed author contributes
  /// `max(base, advertisedMax, digestCeiling)`. A stale entry (our coverage
  /// moved past its expectation) and an entry whose probe window is open
  /// (that request IS the probe) contribute nothing.
  VersionVector shapeSince(
    NodeId peer,
    ChannelId channelId,
    StreamId streamId,
    VersionVector base, {
    VersionVector? digestCeiling,
    required int nowMs,
  }) {
    Map<NodeId, int>? shaped;
    for (final range in _ranges.values) {
      if (range.peer != peer ||
          range.channelId != channelId ||
          range.streamId != streamId) {
        continue;
      }
      if (range.isStale(base) || range.isProbeDue(nowMs)) continue;
      final ceiling = digestCeiling?[range.author] ?? 0;
      final value = max(base[range.author], max(range.advertisedMax, ceiling));
      if (value > base[range.author]) {
        (shaped ??= {...base.entries})[range.author] = value;
      }
    }
    return shaped == null ? base : VersionVector(shaped);
  }

  /// Records a solicited gap for [author], or re-arms an existing record
  /// with doubled backoff and a refreshed advertised maximum.
  void recordGap(
    NodeId peer,
    ChannelId channelId,
    StreamId streamId,
    NodeId author, {
    required int expectedNext,
    required int advertisedMax,
    required int nowMs,
  }) {
    final key = (peer, channelId, streamId, author);
    final existing = _ranges[key];
    _ranges[key] = existing == null
        ? StalledRange(
            peer: peer,
            channelId: channelId,
            streamId: streamId,
            author: author,
            expectedNext: expectedNext,
            advertisedMax: advertisedMax,
            retryAtMs: nowMs + initialBackoff.inMilliseconds,
            probeCount: 0,
          )
        : existing.rearmed(
            nowMs: nowMs,
            advertisedMax: advertisedMax,
            initialBackoffMs: initialBackoff.inMilliseconds,
            maxBackoffMs: maxBackoff.inMilliseconds,
          );
  }

  /// Removes entries whose expectation [ourVersion] has passed — memory
  /// hygiene only; [shapeSince] already ignores them.
  void evictSatisfied(
    NodeId peer,
    ChannelId channelId,
    StreamId streamId,
    VersionVector ourVersion,
  ) {
    _ranges.removeWhere(
      (key, range) =>
          range.peer == peer &&
          range.channelId == channelId &&
          range.streamId == streamId &&
          range.isStale(ourVersion),
    );
  }

  /// Drops every record for [peer] — a removed peer is a fresh diagnosis
  /// window on reconnect.
  void clearForPeer(NodeId peer) =>
      _ranges.removeWhere((key, range) => range.peer == peer);

  /// Drops everything — a restart is a fresh diagnosis window.
  void clearAll() => _ranges.clear();
}
```

Note the re-record staleness subtlety: `recordGap` keeps the existing
`expectedNext` on re-arm (the successor copies it) — a probe that gaps again
at the same position re-confirms the same stall. If the probe's response
moved our coverage, the entry goes stale and stops shaping regardless.

- [ ] **Step 5: Barrel exports**

In `lib/src/sync/sync.dart`: add `stalled_range_registry.dart` under the
`// Aggregates` group and `stalled_range.dart` under a matching entities
group (create the group comment if absent).

- [ ] **Step 6: Run tests to verify pass**

Run: `dart test test/sync/domain/aggregates/stalled_range_registry_test.dart`
Expected: PASS.

- [ ] **Step 7: Gate + commit**

```bash
dart test && dart analyze
git add -A && git commit -m "feat: stalled-range registry — the domain model for per-author pull suppression"
```

---

### Task T2: Engine seam — shape requests, wire the clears

**Files:**
- Modify: `packages/gossip/lib/src/sync/application/gossip_engine.dart` (field ~:250, ctor param + body :309, `_evaluateStreamDigest` :1300-1322, `stop()` :496-508, `clearPendingRequestsForPeer` :1562-1566)
- Modify: `packages/gossip/test/sync/application/gossip_engine_test_harness.dart` (pass-through param)
- Test: `packages/gossip/test/sync/application/gossip_engine_stalled_range_test.dart` (new)

**Interfaces:**
- Consumes: T1's registry API.
- Produces: `GossipEngine` constructor gains `StalledRangeRegistry? stalledRanges` (defaults to `StalledRangeRegistry()`); field `_stalledRanges` that T3 hands to the merger. Harness factory gains the same optional param.

- [ ] **Step 1: Write the failing engine tests**

New file, following `gossip_engine_contiguity_test.dart`'s harness idiom
(reuse its `harnessAt`-style seeding; `handleDigestResponse` returns the
`DeltaRequest`s directly). Construct the harness with a caller-owned
`final stalled = StalledRangeRegistry();` passed through.

```dart
    test('a recorded gap shapes the next request to the peer', () async {
      // Seeded at {authorA: 5}; peer digest advertises a stalled surplus
      // for authorA AND a live surplus for authorB — the live surplus is
      // what makes a request go out at all (a lone stalled surplus is
      // dominance-suppressed, which the next test pins).
      stalled.recordGap(peer.id, channelId, streamId, authorA,
          expectedNext: 6, advertisedMax: 208, nowMs: h.timePort.nowMs);

      final requests = await h.engine
          .handleDigestResponse(digestOf({authorA: 208, authorB: 3}));

      expect(requests, hasLength(1));
      expect(requests.single.since[authorA], 208,
          reason: 'the digest ceiling equals advertisedMax here; the '
              'shaped since must silence the author');
      expect(requests.single.since[authorB], 0,
          reason: 'the live author is requested from the start');
    });

    test('when the stalled surplus is the only surplus, no request is sent '
        'and the pull flag is released', () async {
      stalled.recordGap(peer.id, channelId, streamId, authorA,
          expectedNext: 6, advertisedMax: 208, nowMs: h.timePort.nowMs);

      final requests = await h.engine.handleDigestResponse(digestAt(208));

      expect(requests, isEmpty,
          reason: 'shaped vector dominates the digest — nothing to ask');
      expect(h.engine.outstandingPullCount, 0,
          reason: 'the dedup flag must be released, not leaked');
    });

    test('stop() clears suppressions', () async {
      h.engine.start();
      stalled.recordGap(peer.id, channelId, streamId, authorA,
          expectedNext: 6, advertisedMax: 208, nowMs: h.timePort.nowMs);
      h.engine.stop();

      final requests = await h.engine.handleDigestResponse(digestAt(208));
      expect(requests.single.since[authorA], 5,
          reason: 'a restart is a fresh diagnosis window — unshaped');
    });

    test('peer removal clears that peer only', () async {
      stalled.recordGap(peer.id, channelId, streamId, authorA,
          expectedNext: 6, advertisedMax: 208, nowMs: h.timePort.nowMs);
      stalled.recordGap(otherPeer.id, channelId, streamId, authorA,
          expectedNext: 6, advertisedMax: 208, nowMs: h.timePort.nowMs);

      h.engine.clearPendingRequestsForPeer(peer.id);

      expect(
          (await h.engine.handleDigestResponse(digestAt(208)))
              .single
              .since[authorA],
          5,
          reason: 'cleared peer is unshaped');
      expect(
          (await h.engine
                  .handleDigestResponse(digestFrom(otherPeer, 208)))
              .single
              .since[authorA],
          208,
          reason: 'other peer keeps its suppression');
    });
```

(Adapt `digestAt`/`digestFrom` helpers from the contiguity test's
`DigestResponse` construction; both tests in one file share the seeded
harness `setUp`. Note the two shaping tests need one non-stalled surplus
variant each way — the first test's digest should also advertise a second
author's surplus so a request IS built; keep the single-surplus shape for
the no-request test.)

- [ ] **Step 2: Run to verify failure**

Run: `dart test test/sync/application/gossip_engine_stalled_range_test.dart`
Expected: FAIL — no `stalledRanges` param, no shaping.

- [ ] **Step 3: Implement**

Engine constructor: add `StalledRangeRegistry? stalledRanges` parameter; in
the body beside the pull tracker (:309):

```dart
    _stalledRanges = stalledRanges ?? StalledRangeRegistry();
```

Field beside `_pendingPullTracker` (~:250):

```dart
  /// Stalled author ranges per peer — shapes outgoing pull requests so a
  /// range a peer already failed to supply is not re-requested at full
  /// cadence (see the stalled-range suppression spec).
  late final StalledRangeRegistry _stalledRanges;
```

`_evaluateStreamDigest` (:1300-1322) — after `_adoptClaimedAuthorshipFloor`,
before the dominance check:

```dart
    _stalledRanges.evictSatisfied(
      peer,
      channelId,
      streamDigest.streamId,
      ourVersion,
    );
    final since = _stalledRanges.shapeSince(
      peer,
      channelId,
      streamDigest.streamId,
      ourVersion,
      digestCeiling: streamDigest.version,
      nowMs: _timePort.nowMs,
    );

    // Only request delta if peer has entries we don't have — judged on the
    // shaped vector, so a peer whose only surplus is a stalled range gets
    // no request at all.
    if (!since.dominates(streamDigest.version)) {
      return DeltaRequest(
        sender: localNode,
        channelId: channelId,
        streamId: streamDigest.streamId,
        since: since,
      );
    } else {
      // Nothing to request after all — release the flag.
      _pendingPullTracker.release(peer, channelId, streamDigest.streamId);
      return null;
    }
```

(Use the engine's actual time port field name — check how the engine reads
`nowMs` today and match it.)

`stop()` — beside the existing clears:

```dart
    // A restart is a fresh diagnosis window for stalled ranges too.
    _stalledRanges.clearAll();
```

`clearPendingRequestsForPeer` — beside the existing per-peer clears:

```dart
    _stalledRanges.clearForPeer(peer);
```

Harness: add `StalledRangeRegistry? stalledRanges` to the factory, pass
through to the engine.

- [ ] **Step 4: Run tests to verify pass**

Run: `dart test test/sync/application/gossip_engine_stalled_range_test.dart`
Expected: PASS.

- [ ] **Step 5: Gate + commit**

```bash
dart test && dart analyze   # chain value: T1 + new tests
git add -A && git commit -m "feat: shape pull requests around recorded stalled ranges"
```

---

### Task T3: Merger seam — record solicited gaps, shape continuations

**Files:**
- Modify: `packages/gossip/lib/src/sync/application/delta_merger.dart` (ctor :47-66, gap-report site :167-169, continuation :226-234)
- Modify: `packages/gossip/lib/src/sync/application/gossip_engine.dart` (merger construction :315-336)
- Modify: `packages/gossip/test/sync/application/delta_merger_test.dart` (`build()` factory gains the registry + a fake/in-memory time port)
- Test: cases added to `delta_merger_test.dart` and `gossip_engine_stalled_range_test.dart`

**Interfaces:**
- Consumes: T1's registry; T2's `_stalledRanges` field.
- Produces: `DeltaMerger` constructor gains `required StalledRangeRegistry stalledRanges` and `required TimePort timePort`.

- [ ] **Step 1: Write the failing merger tests**

In `delta_merger_test.dart` (the `build()` factory now constructs and
returns a `StalledRangeRegistry` and an `InMemoryTimePort`, passing both to
the merger):

```dart
    test('a solicited gapped response records the stall', () async {
      // Repo at {authorA: 5}; response carries 11..12 (gap at 6).
      await h.merger.merge(
        deltaOf([entryOf(authorA, 11, 2011), entryOf(authorA, 12, 2012)]),
        solicited: true,
      );

      final shaped = h.stalledRanges.shapeSince(
        peerId, channelId, streamId, VersionVector({authorA: 5}),
        nowMs: h.timePort.nowMs,
      );
      expect(shaped[authorA], 12,
          reason: 'advertisedMax is the highest sequence in the response');
    });

    test('an unsolicited gapped response records nothing', () async {
      await h.merger.merge(
        deltaOf([entryOf(authorA, 11, 2011)]),
        solicited: false,
      );

      final base = VersionVector({authorA: 5});
      expect(
          h.stalledRanges
              .shapeSince(peerId, channelId, streamId, base,
                  nowMs: h.timePort.nowMs),
          base);
    });

    test('continuation requests carry the shaped vector', () async {
      // Pre-recorded stall for authorA; a clean hasMore response for
      // authorB continues the drain.
      h.stalledRanges.recordGap(peerId, channelId, streamId, authorA,
          expectedNext: 6, advertisedMax: 208, nowMs: h.timePort.nowMs);

      final result = await h.merger.merge(
        deltaOf([entryOf(authorB, 1, 3001)], hasMore: true),
        solicited: true,
      );

      expect(result.continuation, isNotNull);
      expect(result.continuation!.since[authorA], 208,
          reason: 'a multi-chunk drain must not re-ship the stalled range');
      expect(result.continuation!.since[authorB], 1);
    });
```

And the end-to-end pin in `gossip_engine_stalled_range_test.dart` (spec
test 5 — recording and shaping meet over the wire):

```dart
    test('after one solicited gapped response, the next request carries '
        'the advertised max', () async {
      await solicit(); // digest exchange arms the pull
      await h.engine.handleDeltaResponse(
        deltaOf([entryOf(authorA, 149, 2149), entryOf(authorA, 208, 2208)]),
      );

      final requests = await h.engine.handleDigestResponse(digestAt(208));
      expect(requests, isEmpty,
          reason: 'stalled surplus was the only surplus — suppressed and '
              'dominance-quiet');
    });
```

- [ ] **Step 2: Run to verify failure**

Run: `dart test test/sync/application/delta_merger_test.dart test/sync/application/gossip_engine_stalled_range_test.dart`
Expected: FAIL — merger has no registry/time port and records nothing.

- [ ] **Step 3: Implement**

`DeltaMerger`: add `required StalledRangeRegistry stalledRanges` and
`required TimePort timePort` params/fields (`_stalledRanges`, `_timePort`).

At the gap-report site (:167-169), record solicited gaps beside the report:

```dart
    if (selection.gaps.isNotEmpty) {
      _reportContiguityGaps(response, selection.gaps, solicited: solicited);
      if (solicited) {
        for (final gap in selection.gaps) {
          _stalledRanges.recordGap(
            response.sender,
            response.channelId,
            response.streamId,
            gap.author,
            expectedNext: gap.expectedNext,
            advertisedMax: response.entries
                .where((e) => e.author == gap.author)
                .map((e) => e.sequence)
                .reduce(max),
            nowMs: _timePort.nowMs,
          );
        }
      }
    }
```

Continuation (:226-234): shape the advanced vector —

```dart
      return (
        continuation: DeltaRequest(
          sender: _localNode,
          channelId: response.channelId,
          streamId: response.streamId,
          // No digest ceiling here; the stored advertisedMax suffices and
          // staleness self-corrects through the probe cycle.
          since: _stalledRanges.shapeSince(
            response.sender,
            response.channelId,
            response.streamId,
            advanced,
            nowMs: _timePort.nowMs,
          ),
        ),
        mergedNewEntries: true,
      );
```

Engine's merger construction (:315-336): pass `stalledRanges: _stalledRanges,
timePort: timePort` (order the registry construction before `_merger`'s).
`recordGap` debug logging per the spec's Observability section rides in the
merger (`_log` at debug on first record and re-arm) — the registry itself
stays log-free (pure domain).

- [ ] **Step 4: Run tests to verify pass**

Run: `dart test test/sync/application/`
Expected: PASS, including all pre-existing merger/engine tests.

- [ ] **Step 5: Gate + commit**

```bash
dart test && dart analyze
git add -A && git commit -m "feat: record solicited stall gaps and shape continuation pulls"
```

---

### Task T4: Scenarios, harness handle, glossary, docs truth

**Files:**
- Modify: `packages/gossip/test/support/test_network.dart` (retain and expose each node's `EntryRepository` on `TestNode` — created inline at :100 today)
- Create: `packages/gossip/test/integration/adverse/stalled_range_suppression_test.dart`
- Modify: `GLOSSARY.md` (root), `packages/gossip/CHANGELOG.md` (Unreleased), `docs/roadmap.md` + spec status line
- Test: the two scenarios

**Interfaces:**
- Consumes: everything above; `TestNetwork` DSL; `corruptLink` identity-tap idiom (`duplicate_frames_test.dart:67-70`); `SyncMessageCodec(wireVersion: WireVersion.v2).decode` (version-agnostic).
- Produces: `TestNode.entryRepository` (generally useful harness handle).

- [ ] **Step 1: Expose the repository on TestNode**

In `test_network.dart`, retain the `InMemoryEntryRepository()` built at :100
and add it as a `TestNode` field (`entryRepository`). Mechanical; no
behavior change.

- [ ] **Step 2: Write scenario 10 (suppression + probe cadence)**

Seed the truncated peer by direct repository append **before** `startAll()`
(the repo accepts a high-start batch and records no floor — verified: its
`appendAll` checks duplicates only, and `getCompactionFloor` stays empty):

```dart
  test('a stalled range is requested once, then suppressed, then probed on '
      'the backoff cadence', () async {
    final network = await TestNetwork.create(['truncated', 'fresh']);
    addTearDown(network.dispose);
    final truncated = network['truncated'];
    final fresh = network['fresh'];

    await network.connect('truncated', 'fresh');
    await network.setupChannel(channelId, streamId);

    // The truncated peer holds author X only from 149 — no floor, the
    // pre-floor-build shape from the 2026-08-31 incident.
    await truncated.entryRepository.appendAll(
      channelId, streamId, entriesOf(authorX, from: 149, to: 208),
    );

    // Tap every frame fresh sends toward the truncated peer.
    final sinceValues = <int>[];
    final codec = SyncMessageCodec(wireVersion: WireVersion.v2);
    network.corruptLink('fresh', 'truncated', (bytes) {
      final decoded = codec.decode(bytes);
      if (decoded is DeltaRequest && decoded.streamId == streamId) {
        sinceValues.add(decoded.since[authorX]);
      }
      return bytes;
    });

    await network.startAll();
    await network.runRounds(3); // discovery + the one diagnosing exchange

    expect(sinceValues.where((v) => v == 0), hasLength(1),
        reason: 'exactly one request asks for the range before suppression');

    // Live data still converges while the range is suppressed.
    await fresh.write(channelId, streamId, [1]);
    await network.runRounds(3);
    expect(await truncated.entryCount(channelId, streamId), 61,
        reason: '60 seeded + 1 live entry');

    final probesBefore = sinceValues.where((v) => v == 0).length;
    await network.runRounds(30); // 30s of fake clock — the probe window
    final probesAfter = sinceValues.where((v) => v == 0).length;
    expect(probesAfter - probesBefore, 1,
        reason: 'exactly one probe when the window opens, then re-armed');
  });
```

(Adjust round counts to the engine's real cadence during implementation —
the assertion shapes are what matter: exactly one initial ask, zero asks
while suppressed, exactly one probe per window. `entriesOf` builds
`LogEntry` values the way the harness's write path does — copy the
timestamp construction from an existing integration test.)

- [ ] **Step 3: Write scenario 11 (third-peer supply evicts)**

```dart
  test('the stalled range arriving from a third peer lifts the suppression',
      () async {
    final network = await TestNetwork.create(['truncated', 'fresh', 'archive']);
    addTearDown(network.dispose);

    await network.connectAll();
    await network.setupChannel(channelId, streamId);

    await network['truncated'].entryRepository.appendAll(
      channelId, streamId, entriesOf(authorX, from: 149, to: 208),
    );
    // The archive holds the whole history — the range IS obtainable.
    await network['archive'].entryRepository.appendAll(
      channelId, streamId, entriesOf(authorX, from: 1, to: 208),
    );

    await network.startAll();
    await network.runRounds(20);

    expect(await network['fresh'].entryCount(channelId, streamId), 208,
        reason: 'suppression toward the truncated peer must not block '
            'obtaining the range from the archive');
    expect(await network.hasConverged(channelId, streamId), isTrue);
  });
```

- [ ] **Step 4: Run the scenarios**

Run: `dart test test/integration/adverse/stalled_range_suppression_test.dart`
Expected: PASS (acceptance for T1-T3; a red here is a defect in those tasks,
not a reason to weaken the scenario).

- [ ] **Step 5: Glossary + CHANGELOG + docs truth**

- `GLOSSARY.md`, sync section: **Stalled range** (an author's surplus a peer
  failed to supply contiguously — suppressed from pulls to that peer),
  **Suppression** (shaping a pull request's `since` so a stalled range is
  not re-requested), **Probe window** (the backoff-scheduled moment a
  suppressed range is asked for again).
- `packages/gossip/CHANGELOG.md` Unreleased: one line — stalled author
  ranges are suppressed per peer with doubling re-probe backoff; no wire
  change.
- `docs/roadmap.md`: flip the item to ☑ with the landing reference; trim the
  Current-focus step-1 wording to "Dart reference landed; the Kotlin port
  remains". Spec status line → implemented.

- [ ] **Step 6: Final gate + commit**

```bash
cd /Users/joel/git/neutrinographics/gossip && melos run test && melos run analyze
git add -A && git commit -m "test: pin stalled-range suppression end to end, and truth the docs"
```

---

## Completion

- Whole-branch review (code-review skill) before merging; fix wave if needed.
- Merge decision per superpowers:finishing-a-development-branch — the owner
  decides merge/PR; local main is already 13 ahead of origin (unpushed).
- Registry rows to write at completion: none expected (this is the Dart
  reference the kt port item already awaits) — but check whether
  implementation surfaced any.
