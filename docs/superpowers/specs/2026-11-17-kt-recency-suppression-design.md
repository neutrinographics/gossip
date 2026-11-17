# Recency suppression for the Kotlin library — design

**Status:** draft for the owner's approval, 2026-11-17. **Item:** roadmap
item 11, the last piece of
[wire-efficiency phase 2](../../backlog/kt-port-wire-efficiency.md).
**Applies to:** `gossip-kt` only. The Dart library has carried this since the
two-tier pacing amendment (ADR-013, 2026-08-20); this closes the parity gap.
**Register rows touched:** "Anti-entropy coverage: which side records it"
(closed by this design) and one new flow-back row (the selector's shape).

## Intent

A Kotlin node skips the gossip round with a peer it exchanged digests with
inside the current effective interval, in either direction, and sends
nothing when every peer is that fresh. On the server this removes the
server-initiated rounds to phones that just gossiped with it, and makes the
pair's exchange count one per interval instead of two. It is the Dart
behavior, ported one for one, in the Kotlin library's own shape.

## Goals

- Behavioral parity with Dart's round: fresh peers are skipped; the partner
  is the least-recently-gossiped candidate with a random tiebreak; both ends
  of an exchange record it.
- Coverage is recorded on the same side as Dart: when a digest request is
  sent, and when one is answered. Not when a delta merges.
- Every Dart test that pins the behavior has a Kotlin twin.

## Non-goals

- No wire change. Nothing new is sent or parsed.
- No change to what counts as news, to the pacer, or to the probe loop.
- No suppression of `syncWithPeer` — a join or reconnect always exchanges,
  as in Dart.
- No Dart change in this item. The selector shape goes on the register as a
  flow-back candidate, not into Dart now.

## Anti-goals

- A sync-owned copy of the exchange timestamps. Membership's `Peer` already
  holds `lastAntiEntropyMs` on both twins; a second copy would drift.
- A selection rule with a random draw written inline in the engine, which is
  what the Kotlin purification moved out of the application layer.

## Approaches considered

**A. Inline in the engine, line for line with Dart.** Filter, pick and
record inside `performGossipRound`. Smallest diff, closest text match;
puts a random draw and a selection rule back into application code.

**B. A pure sync domain service for the pick (chosen, 2026-11-17).** The
rule lives in `sync/domain/services`, takes time and randomness as data,
and the engine keeps the port reads, the recording calls and the send.
Same behavior as A; matches the register's standing rule that domain
services take data, not ports; mirrors the membership side's
`ProbeTargetSelector`.

**C. Sync-owned recency state.** Rejected: duplicates state membership
records on both twins.

## Design

### The service

`sync/domain/services/GossipPartnerSelector.kt`, an `object` with one
pure function:

```kotlin
fun select(
    candidates: List<SyncPartner>,   // reachable and uncongested, in any order
    nowMs: Long,
    intervalMs: Long,                 // the effective gossip interval
    random: Random,
): SyncPartner?
```

- A candidate is **fresh** when `lastAntiEntropyMs != null` and
  `nowMs - lastAntiEntropyMs < intervalMs`. Fresh candidates are dropped.
  A peer never exchanged with (`null`) is never fresh — the explicit null,
  not a zero, so the simulated clock starting at 0 cannot read as fresh
  (the same trap the probe selector documents).
- Among the rest, the **stalest** wins: the smallest `lastAntiEntropyMs`,
  with `null` sorting before every real timestamp. Ties are broken by one
  draw from `random`.
- Empty input, or every candidate fresh, answers `null`.

The congestion read (`MessagePort.pendingSendCount`) stays in the engine,
as it does today: it is a port read, and the selector takes data.

### The partner view

`SyncPartner` gains `val lastAntiEntropyMs: Long? = null`.
`MembershipPeerDirectory.toPartner` maps it from `Peer.lastAntiEntropyMs`.
`PeerDirectory`'s interface does not change; its KDoc's "future port note"
comes out, since the port it predicted is this one. `recordMessageReceived`
is not restored: on Kotlin the coordinator credits every inbound frame
before any codec sees it, and Dart's call is metrics, not suppression.

### The round

`performGossipRound` becomes, after the existing `beginRound` and RTT
refresh:

1. `reachable` from the directory; return if empty.
2. `candidates` = reachable filtered by `hasSendCapacity` (unchanged).
3. `interval` read **after** `beginRound`, as Dart does and documents: a
   quiet round has already grown it, so the suppression window is the
   just-grown interval. Self-correcting, because the rule is time-based.
4. `partner = GossipPartnerSelector.select(candidates, nowMs, interval, random)`;
   on `null`, log at DEBUG "Skipping gossip round: no stale, uncongested
   peers" and return.
5. `peerDirectory.recordAntiEntropy(partner.nodeId, nowMs)` then send the
   request. Recording comes before the send, as in Dart, so a failed send
   still counts as this round's attempt and the next round moves on.

### Recording on the responder

`handleDigestRequest` records `recordAntiEntropy(request.sender, nowMs)`
first, before learning holdings or answering, and **ungated**: a paused
engine that still answers digests still records the exchange. This is the
register row's fix.

The merge-time recording goes: `DeltaMerger`'s `onNewEntriesMerged` lambda
in the engine keeps `recordNews()` and drops `recordAntiEntropy`. Dart
records nothing on merge. Its two pins change accordingly (below).

### What does not change

`syncWithPeer` (records news, sends, does not record anti-entropy — Dart's
shape). `GossipTimingPolicy`. The probe loop. The codecs. `BoundaryTest`'s
edge table: the selector is sync-domain code over sync's own value.

## Tests

Pure, in `GossipPartnerSelectorTest`:

- never-exchanged peers are picked before any exchanged peer;
- the stalest exchanged peer wins;
- ties are broken by the draw (seeded `Random`, both outcomes reachable);
- a peer exchanged with inside the interval is dropped; at exactly the
  interval it is eligible (`>=` is stale);
- every candidate fresh, or no candidates, answers `null`;
- a `null` timestamp is not fresh at `nowMs = 0`.

Engine, translating Dart's `gossip_engine_partner_selection_test.dart` and
the recency group of `gossip_engine_pacing_test.dart`:

- rotates through peers: with n peers added, n rounds gossip each peer
  exactly once;
- records the anti-entropy timestamp for the selected peer;
- handling an inbound `DigestRequest` records the exchange;
- a round skips a peer whose exchange is fresher than the interval (and
  sends nothing when it is the only peer);
- a stale peer is still gossiped with.

Changed pins: `DeltaResponse updates peer anti-entropy timestamp` is
replaced by the digest-request test above; `a throwing onEntriesMerged
still records news and anti-entropy credit` keeps its news assertion and
loses the credit one (renamed to say so).

Harness (`gossip-kt-testing`), one scenario: two converged nodes under the
simulated clock exchange at most once per effective interval per pair
after both-side recording, where today they exchange twice.

`GossipEngineTest`'s existing `gossip round selects random reachable peer
and sends DigestRequest` is renamed for the new rule and asserts the stalest
choice.

## Documentation, in the same PRs

- gossip-kt: `CLAUDE.md` services list gains `GossipPartnerSelector`; the
  engine's class doc and README stop saying "random peer".
- gossip (docs-only PR on this thread's branch): roadmap item 11 and the
  wire-efficiency item's status line mark phase 2 complete; the backlog
  item's phase-split section records the port; the register closes the
  "which side records it" row and adds a flow-back row for the selector's
  shape, homed in `health-adopt-kt-flow-backs.md`.

## Left to the builder

- Whether the harness scenario counts digest requests per pair or per node.
- The exact wording of the renamed tests.
- Whether `select` takes `Duration` or `Long` for the interval; the engine
  reads a `Duration` and the probe selector takes one.

## Follow-up outside this item

The server picks this up on the next opendoor-api submodule bump, with that
repository's live-device validation. The phones already run the Dart half;
the pending OpenDoorApp pin bump to 1144eda (roadmap item 10's next step)
is a separate ask.
