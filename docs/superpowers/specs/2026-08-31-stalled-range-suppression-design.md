# Stalled-range suppression — design

**Date:** 2026-08-31
**Status:** Draft for review
**Roadmap item:** [Suppress pulling an author's range a peer has already failed to supply](../../backlog/engine-stalled-range-request-backoff.md)
**Follow-on:** [Port stalled-range suppression to the Kotlin library](../../backlog/kt-stalled-range-suppression-port.md)

## Problem

When a peer answers a delta request with a per-author sequence hole (we expect
sequence N, its first available entry is M > N), the contiguity filter rightly
rejects that author's entries: merging them would leave an interior gap the
version vector cannot represent. But nothing remembers the failure. Our vector
for that author never advances, so **every subsequent exchange with that peer
re-ships the author's entire surplus range** — which grows forever on a live
stream — and we reject it every time, at full gossip cadence, for as long as
the pair stays connected.

This is not hypothetical. On 2026-08-31 the opendoor server, newly syncing
presence, entered exactly this loop against two phones whose presence logs are
truncated (first available 149 and 1161) and which, running pre-floor builds,
cannot say the range is gone for good. Quiescence pacing does not help: the
loop's own delta traffic counts as news and holds the pacer at full cadence
(`gossip_engine.dart:237`).

**Correction (2026-08-31, later the same day):** an earlier draft of this spec
blamed the loop for the server's R14 memory-quota incident. That attribution
was wrong, and the measurements say so plainly. The dyno sat at 113.8% of quota
*while idle* — its last client traffic was at 10:25 UTC and it still read
586 MB at 13:17 — which no traffic-driven loop explains. The actual cause was a
JVM with no heap cap: the app deploys as a Docker image, which bypasses
Heroku's JVM buildpack and its container-aware `-Xmx` default. Adding
`-Xmx256m -XX:MaxMetaspaceSize=96m` dropped it to 313.8 MB (61.3%) with zero
swap, and R14 stopped instantly. The stalled-range loop then ran **16 more
times** over the following 36 minutes and produced no memory pressure at all.

The loop is still real and still worth fixing — it was measured on the device
side at 2041 entries / 765 KB re-shipped 59 times in a few minutes, converging
on nothing — but it should be prioritised as **wasted bandwidth and battery on
constrained links**, not as the cause of a production outage. Anyone weighing
this work against other items deserves the accurate version.

The fix must be **per-author**, not per-stream or per-request. A stream with
live traffic (presence heartbeats) merges *something* on almost every
exchange, so any stream-level "no progress → back off" signal never fires, and
any "peer state changed → reset" trigger fires constantly. Only the author
axis separates the stalled part of a stream from the healthy part.

## Goal

When a solicited response reveals a gap for an author, stop asking that peer
for that author's surplus — while every other author on the stream, and every
other stream, syncs exactly as before. Re-probe the stalled range on a growing
interval so recovery stays automatic, and drop the suppression the instant the
range becomes obtainable.

## Non-goals

- **No wire or protocol change.** Only the numbers inside `DeltaRequest.since`
  change — a value the responder already treats as "send entries above this".
- **No floor inference.** A gap without a floor claim means the range may
  still be obtainable elsewhere; suppression is per-peer request shaping,
  never an adoption of truncation.
- **No change to gap reporting.** The one-time warning per
  (peer, channel, stream, author, expectedNext) stays exactly as it is.
- **No change to our own responses or digests.** We advertise and serve
  exactly what we hold; suppression shapes only what we ask others for.
- The Kotlin port is a separate item (translated after this lands).

## Design

### New domain aggregate: `StalledRangeRegistry`

*(Amended 2026-09-01 on the owner's review: the first draft shaped this as a
stateful "domain service" with lazily-mutating queries, following
`PendingPullTracker`'s precedent. The owner rejected both deviations — a
domain service is stateless, queries don't mutate, and precedent is not a
justification. Modeled honestly, this state is an **aggregate**: entries
with identity and a lifecycle, behind one root that owns the invariants.
That is also exactly the Kotlin twin's `PeerRegistry` +
`SynchronizedPeerRegistry` shape, so the port becomes a pattern match. The
`PendingPullTracker` smell is queued separately —
[Reshape the runtime trackers into honest domain objects](../../backlog/health-pure-runtime-trackers.md).)*

`lib/src/sync/domain/aggregates/stalled_range_registry.dart` — the root —
plus `lib/src/sync/domain/entities/stalled_range.dart`, the entry entity.

**`StalledRange` (entity):** identity is `(peer, channelId, streamId,
author)`; attributes:

- `expectedNext` — our `ourVersion[author] + 1` at the moment the gap was
  observed. The staleness sentinel: if our expectation ever differs, the
  world changed and this entry no longer describes it.
- `advertisedMax` — the highest sequence for the author seen in the gapped
  response. The overlay value: asking "since `advertisedMax`" makes the peer
  send nothing for this author.
- `retryAt` — when the next probe is allowed. First suppression lasts
  `initialBackoff` (default 30s); each re-recorded gap doubles it up to
  `maxBackoff` (default 10min).
- `probeCount` — how many times this stall has been re-confirmed (drives the
  doubling; also useful in debug logs).

Behavior on the entity: `isStale(ourVersion)`, `isProbeDue(nowMs)`,
`rearmed(nowMs, advertisedMax)` (returns the doubled-backoff successor —
transitions produce new values, never mutate in place).

**`StalledRangeRegistry` (aggregate root):** owns the entries and every
invariant. **Fully deterministic and dependency-free** — no `TimePort`, no
ports at all: every operation that needs time takes `nowMs` as an argument
(the application layer already holds the clock). Commands and queries are
strictly separated:

Queries (pure — no state change, same inputs same answer):

- `shapeSince(peer, channelId, streamId, base, {digestCeiling, required nowMs})`
  → the shaped vector for an outgoing request. Owns the **never-lower rule**
  in one place: each suppressed author contributes
  `max(base[author], advertisedMax, digestCeiling[author] if given)`.
  A stale entry contributes nothing (correctness never depends on when it is
  pruned); an entry whose probe window is open (`isProbeDue`) contributes
  nothing — that request *is* the probe.

Commands:

- `recordGap(peer, channelId, streamId, author, {expectedNext, advertisedMax, required nowMs})`
  — creates the entry, or replaces an existing one with its `rearmed(...)`
  successor.
- `evictSatisfied(peer, channelId, streamId, ourVersion)` — removes entries
  whose `isStale(ourVersion)` holds: our coverage moved, because the range
  arrived from another peer or a floor claim was adopted (floor adoption
  raises the vector, so no separate floor wiring is needed). Memory hygiene
  only — `shapeSince` already ignores stale entries, so eviction timing can
  never affect a request.
- `clearForPeer(peer)` / `clearAll()` — mirror the pull tracker's clears.

No timers, no async, no persistence. The registry is touched only at the
recording and shaping seams below.

### Lifecycle at the seams

1. The engine's request builder calls `evictSatisfied(...)` then
   `shapeSince(...)` — eviction is an explicit command at the same seam the
   lazy version would have fired, just visible.
2. A probe is simply a request built while `isProbeDue` holds: the author is
   unshaped, the range is asked for again. If the response gaps again,
   `recordGap` re-arms with doubled backoff; if it supplies the range, the
   entry goes stale and the next `evictSatisfied` removes it.
3. The explicit clears: `clearForPeer` where the engine already calls
   `_pendingPullTracker.clearForPeer` (peer removal), `clearAll` where
   `stop()` already clears the pull tracker and reported gaps — same
   rationale: a restart or reconnection is a fresh diagnosis window.

### Ownership and the recording seam

The engine constructs the registry (alongside `PendingPullTracker`) and hands
the same instance to `DeltaMerger`'s constructor; engine and merger share it
the way they already share pull-tracker state through callbacks, but without
an indirection — the merger both records and shapes directly, because both
facts it needs (the gap, and whether the response was solicited) live there.
Both are application-layer orchestrators issuing commands and queries to one
domain aggregate; the rules stay inside the aggregate.

`_selectContiguousEntries` already computes exactly what recording needs:
`ContiguityGap(author, expectedNext, firstAvailable)` per gapped author
(`delta_merger.dart:279`). Alongside the existing report call at line 168, the
merger calls `recordGap` — **solicited responses only**, matching the
reporting rule: an unsolicited gapped response already means "anti-entropy
will catch up" and must not poison the pull path. `advertisedMax` is the
highest sequence for that author among the response's entries.

### Shaping seam 1: the engine's request builder

In the engine's per-stream request construction (`gossip_engine.dart:1300`),
after `ourVersion` is computed and `_adoptClaimedAuthorshipFloor` has run,
shape the vector **before** the dominance check:

```
_stalledRanges.evictSatisfied(peer, channelId, streamId, ourVersion);
final since = _stalledRanges.shapeSince(
  peer, channelId, streamId, ourVersion,
  digestCeiling: streamDigest.version, nowMs: _timePort.nowMs,
);
```

The never-lower max lives inside `shapeSince`, not at this seam.
Taking the digest's value too means a peer that has since gained *newer*
entries for the stalled author still ships nothing — without it, those new
entries would be shipped, rejected as gapped, and re-recorded (correct but
wasteful). The dominance check then runs against the shaped vector, so when
the stalled surplus was the only difference, **no request is sent at all** —
the request-cadence half of the waste disappears for free at the same seam.

The shaped vector exists only inside the outgoing `DeltaRequest`; nothing
persists it, and `getVersionVector` is untouched.

### Shaping seam 2: the merger's continuation requests

`hasMore` continuations build their own `DeltaRequest` from the advanced
vector (`delta_merger.dart:211-232`), so a multi-chunk drain from a peer with
one stalled author would re-ship that author's range in every chunk. The
merger therefore calls the same query on the shared registry:
`shapeSince(peer, channelId, streamId, advanced, nowMs: ...)` — no digest
ceiling is available here and none is passed; the stored `advertisedMax`
suffices, and staleness self-corrects through the probe cycle. Same method,
same invariant, one owner.

### Observability

- The existing one-time stall warning is unchanged.
- `recordGap` logs at debug: first suppression ("suppressing author X to peer
  P for 30s") and each re-arm ("probe failed, backing off to 120s,
  probeCount=3").
- No new public counters in this change (YAGNI; the logs carry diagnosis).

## Edge cases

- **Multiple gapped authors in one response:** each is recorded and suppressed
  independently.
- **The overlay never lowers `since`:** every overlay value is `max`-ed with
  the vector it modifies.
- **A stalled author coming back alive through the same peer:** its new
  entries sit above `advertisedMax`; the digest-max term suppresses them
  engine-side until a probe confirms the gap still exists, after which
  `recordGap` refreshes `advertisedMax`. They remain unobtainable (correctly)
  until the underlying range is supplied or written off by a floor.
- **Memory:** bounded by (connected peers × stalled authors); entries are
  evicted by the explicit `evictSatisfied` command at the request-build seam
  and cleared on peer removal and `stop()`. No persistence —
  a restart re-diagnoses in one exchange, which is also what makes the
  behavior self-healing after upgrades.
- **`_adoptClaimedAuthorshipFloor` interaction:** ordering is compute →
  adopt → overlay, so the overlay applies to the freshest vector and cannot
  mask the authorship-floor adoption.

## Testing (TDD, in implementation order)

Unit — `stalled_range_registry_test.dart` (pure: `nowMs` passed in, no fakes
needed):
1. A recorded gap shapes the author's `since`; other authors and peers
   unaffected; the shaped value is the max of base, `advertisedMax`, and the
   digest ceiling (the never-lower rule, pinned at its one owner).
2. The probe window opens after `initialBackoff` (the author is unshaped);
   re-recording doubles the backoff per probe up to `maxBackoff`.
3. `shapeSince` is a pure query: a stale entry contributes nothing even
   before eviction, and repeated calls with the same inputs return the same
   answer with no state change.
4. `evictSatisfied` removes exactly the entries whose expectation the vector
   has passed; `clearForPeer` / `clearAll` drop the right entries.

Engine + merger (existing unit-test seams):
5. After one solicited gapped response, the next `DeltaRequest.since` for that
   peer carries `advertisedMax` for the stalled author.
6. When the stalled surplus is the peer's only surplus, no `DeltaRequest` is
   sent at all.
7. Continuation requests carry the shaped vector.
8. An unsolicited gapped response records nothing.
9. Peer removal and `stop()` clear suppressions.

Scenario (TestNetwork DSL):
10. A truncated-history peer plus a live author: live data converges; after
    the first exchange, no further wire message to the truncated peer requests
    the stalled range (inspect `since` on the bus); after the backoff elapses
    (fake clock), exactly one probe goes out.
11. The stalled range arriving from a third peer un-suppresses the author
    (evicts) and normal sync with the original peer resumes.

## Rollout

1. Dart lands on gossip `main` (this spec).
2. Kotlin port (own roadmap item) → opendoor-api submodule bump + deploy —
   ends the live server-side waste.
3. Phone fleet: next app gossip pin bump **after** OpenDoorApp PR #486 merges
   (decided 2026-08-31; #486 stays as verified for its device session).

## Decisions taken during brainstorming (2026-08-31)

- Dart first, as the reference implementation; kt translates its tests.
- Fleet rollout as a follow-up pin bump, not folded into PR #486.
- Author-level suppression chosen over whole-stream request backoff (the
  latter is defeated by live-stream traffic; see Problem).
- Backoff 30s → ×2 → 10min cap.

## Decisions from the owner's review (2026-09-01)

- **Approved, with a pure-DDD reshape folded in above.** The owner rejected
  the draft's two deviations — a stateful "domain service" and a
  lazily-mutating query — with the standing rule that a deviation from pure
  DDD needs a really good reason, and precedent inside this codebase is not
  one. The state is modeled as what it is: a domain **aggregate**
  (`StalledRangeRegistry` root, `StalledRange` entries) with strict
  command/query separation and time passed in as data (no ports in the
  domain object at all).
- **The never-lower rule has one owner**: `shapeSince`. Both seams call it;
  neither re-implements it.
- **`PendingPullTracker`'s pattern is a recorded smell**, not a precedent —
  queued at [Reshape the runtime trackers into honest domain objects](../../backlog/health-pure-runtime-trackers.md).
- **Glossary duty:** the implementation's docs pass adds *stalled range*,
  *suppression*, and *probe window* to `GLOSSARY.md`.
- **Kotlin note:** the pure aggregate translates as kt's existing
  `PeerRegistry` + `SynchronizedPeerRegistry` pattern — the port's
  thread-safety adaptation becomes a wrapper, not internal locking.
