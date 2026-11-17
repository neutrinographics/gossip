# Recency window under jitter — design

**Status:** approach B chosen by the owner 2026-11-17 07:38Z; design awaiting approval.
**Raised by:** the Fable review of gossip-kt PR #22, finding 1.
**Applies to:** `gossip` (Dart) and `gossip-kt`, together. No wire change.

## Intent

A node's own gossip cadence must never be what suppresses its next round.
Recency suppression exists so that a peer's initiative (it gossiped with us
a moment ago) spares us a redundant round; it was never meant to make a
lone initiator exchange every 1.5 intervals, or to stretch the 30 s idle
repair bound ADR-013 states to about 66 s.

## The defect, in both twins

The round loop arms `applyJitter(effectiveInterval)`, a wait of 0.8 to 1.2
intervals. The round then drops every peer exchanged with less than one
full interval ago. Two consequences:

1. **Jitter.** A node's previous round recorded the exchange 0.8 to 1.2
   intervals ago; whenever the wait came out short of 1.0, the peer still
   reads as fresh and the round skips. About half the time for a lone
   initiator (mean gap 1.5 intervals, max 2.2); 1.28 for a pair.
2. **Idle growth.** On a quiet round the pacer grows the interval by 1.5x
   *before* the window is read. The grown window (1.5 x old) always covers
   a wait drawn from the old interval, so during idle growth every other
   round skips, and each skip is itself a quiet round.

## Goals

- A round never suppresses the exchange its own previous round made.
- Suppression still spares a round to a peer that initiated since.
- The jitter fraction is named once, where `applyJitter` lives, and the
  window is derived from it, so a change to one cannot strand the other.
- The order of the interval read against the pacer's growth is pinned.
- Equivalent tests on both twins that drive rounds at the short end of the
  jitter, which today's suites cannot see (their steps land past the window).

## Non-goals

- No change to the pacer's growth, ceiling, jitter width, or to what counts
  as news.
- No change to the probe loop. Its freshness window is the same arithmetic,
  but a skipped probe against a peer heard from a moment ago is a saving,
  not a delayed repair, and the 2-minute cap already bounds it.
- No sync-owned copy of the exchange timestamps (review finding 3 stays a
  register row).

## Approaches

**A. Jitter floor only** (the reviewer's fix). Window = 0.8 x interval,
read where it is read today (after the quiet-round growth). Removes the
steady-state self-suppression. During idle growth every other round still
skips, because 0.8 x 1.5 = 1.2 x old still covers the wait.

**B. Jitter floor of the interval this round was scheduled from.** Window =
0.8 x the interval read *before* this round's quiet-round growth, which is
the interval the armed wait was jittered from. A wait is never shorter than
0.8 x that interval, so the node's own previous exchange is never inside the
window, in any phase. Dart's "deliberate: read after quietRound" comment is
rewritten and the order is pinned. Recommended.

**C. Window = the exact wait this round was armed with.** Precise, but the
engine would have to carry the drawn delay from `nextDelay` to `tick`,
coupling the round to the scheduler for no gain over B.

**Owner's pick:** B, 2026-11-17, because A leaves the idle-growth skip in place and B closes both causes with the same change.

## Design (B)

### Shared kernel, both twins

Beside `applyJitter`, in `shared/domain/services/jitter.dart` /
`Jitter.kt`:

- the fraction becomes a named constant (`defaultJitterFraction = 0.2` /
  `DEFAULT_JITTER_FRACTION`), which `applyJitter` defaults to;
- `jitterFloor(base, {fraction})` returns `base * (1 - fraction)`: the
  earliest a jittered wait on `base` can end.

Tests: `applyJitter` never returns less than `jitterFloor` of the same base
and fraction (property over seeds); `jitterFloor` of a zero fraction is the
base.

### The round, both twins

In `performGossipRound`, the interval the window derives from is read
**before** `quietRound()` / `beginRound`, not after:

```
final scheduledFrom = effectiveGossipInterval;   // what nextDelay drew from
quietRound-or-consume-news
...
final window = jitterFloor(scheduledFrom).inMilliseconds;
candidates = stale-by-window ∧ uncongested
```

Kotlin: `GossipPartnerSelector.select` keeps its signature; the engine
passes `jitterFloor(scheduledFrom)` as the interval argument. Its KDoc says
the argument is the window, not the cadence. Dart: `_staleUncongestedCandidates`
takes the window. Both comments explain why the read precedes growth: a
grown interval governs the *next* wait, and the window must match the wait
that just ended.

`nextDelay` is unchanged: it still reads the grown interval after the round.

### Tests, equivalent on both twins

Engine level, adaptive timing on, a `Random` seam that returns the floor
draw (Dart: a `Random` whose `nextDouble` is 0; Kotlin: a `Random` subclass
whose `nextBits` is 0):

1. **Own round is never suppressed at the jitter floor.** One peer, exchange
   recorded by a round at t0; advance exactly `jitterFloor(interval)`; the
   next round sends. Today it skips.
2. **Own round is never suppressed across a quiet-round growth.** Two quiet
   rounds back to back at the floor of each interval: both send. Today the
   second skips. This test also pins the read order (finding 7).
3. **A peer's initiative inside the floor still suppresses.** Record an
   exchange `jitterFloor(interval) - 1 ms` ago; the round sends nothing.
4. Existing pins keep passing: `>=` on the edge, null never fresh, future
   timestamp stale (Kotlin), stalest-first pick.

Integration, both twins: the converged-pair scenario is re-run with the
real jitter (not a fixed 600 ms step) over 30 intervals and asserts one
exchange per interval per pair within the band the KDoc derives; the Kotlin
`RecencySuppressionTest` and Dart's pacing-suite scenario get the same
band and the same derivation.

### Documentation

- ADR-013 amendment: the suppression window is the jitter floor of the
  interval the round was scheduled from, so the repair bound stays
  30 s + jitter.
- gossip `docs/parity.md` / register: one row, closed in the same PRs.
- gossip-kt `CLAUDE.md` pacing paragraph: one sentence on the window.

## Order of landing

gossip-kt first if #22 is still open (stack on its branch, or on main after
its merge); Dart in the same session; opendoor-api bump only after both.

## Left to the builder

- Exact test names; whether the Dart floor-draw `Random` lives in the
  existing harness or a test support file.
- Whether `jitterFloor` takes `Duration` or the engine converts to ms.
