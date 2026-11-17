# Recency window under jitter — design

**Status:** approved by the owner 2026-11-17 07:56Z; plan approved 08:04Z. Approach B chosen 07:38Z; shape "the
timing policy owns the schedule" chosen 07:52Z. Built: gossip PR #22, gossip-kt PR #23 (merged 2026-11-17).
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

Both have one root: the wait and the window are derived from the interval
at two different moments, by the application layer, with nothing holding
them together.

## Goals

- A round never suppresses the exchange its own previous round made.
- Suppression still spares a round to a peer that initiated since.
- The wait and the window that belongs to it are one decision, made in one
  place in the domain, so "window never exceeds wait" is a property of a
  value rather than an ordering of reads in the engine.
- The jitter fraction is named once, where `applyJitter` lives.
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

**B. Jitter floor of the interval this round was scheduled from.** A wait
is never shorter than 0.8 x the interval it was drawn from, so a window of
exactly that never covers the node's own previous exchange, in any phase.

**C. Window = the exact wait this round was armed with.** Precise, but no
gain over B, and it couples the round to the scheduler's draw.

**Owner's pick:** B, 2026-11-17, because A leaves the idle-growth skip in
place and B closes both causes.

Within B, two shapes were weighed:

- **B1. The engine derives the window.** Read the interval before the
  quiet-round growth, pass its floor as the window. Minimal, but the
  invariant lives in the application layer, held by read order, a comment
  and a pin. Rejected as the less cohesive shape.
- **B2. The timing policy owns the schedule** (chosen). Arming a round is
  one policy decision that answers the wait and remembers the interval it
  was drawn from; the window is that interval's floor, read back from the
  same value. The read-order subtlety disappears because the window
  travels with the wait it belongs to.

## Design (B2)

### Shared kernel, both twins

Beside `applyJitter` (`shared/domain/services/jitter.dart`, `Jitter.kt`):

- the default fraction becomes a named constant (`defaultJitterFraction`,
  `DEFAULT_JITTER_FRACTION` = 0.2) that `applyJitter` defaults to;
- `jitterFloor(base, fraction = default)` = `base * (1 - fraction)`: the
  earliest a jittered wait on `base` can end.

Tests: over seeds, `applyJitter` never answers less than `jitterFloor` of
the same base; a zero fraction makes `jitterFloor` the base.

### The timing policy, both twins (`sync/domain/services`)

The policy gains the schedule:

- **Arm.** `armRound(random)` reads the effective interval as it stands,
  remembers it as the *armed interval*, and answers `applyJitter` of it.
  This is what `nextDelay` calls; nothing else jitters the gossip cadence.
- **Window.** `recencyWindow` = `jitterFloor(armedInterval)`. Before any
  wait has been armed (a round run directly, as tests and `syncWithPeer`
  do), it is the floor of the current effective interval.
- `effectiveInterval`, `news`, `quietRound` / `beginRound` and the RTT
  refresh are unchanged. A quiet-round growth changes what the *next* arm
  draws from; it does not move the armed interval.

Kotlin: `GossipTiming` gains `armedInterval: Duration?`; `armRound` is a
`Transition<GossipTiming, Duration>` (the draw is an input, as in
`GossipPartnerSelector`); `recencyWindow(timing)` is a pure read. The
update runs inside the cell's monitor with no port read, within the lock
rule. Dart: the policy class gains a private `_armedInterval`, a
`Duration armRound(Random)` and a `Duration get recencyWindow`.

### The round, both twins

- `nextDelay` becomes `timing.armRound(random)`.
- `performGossipRound` reads `recencyWindow` (before or after the
  quiet-round step no longer matters; it is read where the interval is read
  today) and filters by it. Kotlin passes it to
  `GossipPartnerSelector.select` as the window, with the parameter renamed
  from `interval` to `window` and the KDoc saying so. Dart's
  `_staleUncongestedCandidates` takes the window.
- The "deliberate: read after quietRound" comment (Dart) and its Kotlin
  twin come out; the policy's doc explains the schedule instead.

### The wake, a known and accepted edge

`wake()` re-arms through `nextDelay` and keeps the earlier of the fresh
wait and the pending one. When the pending wait stands, the armed interval
is now the fresh (smaller, post-news) one while the wait was drawn from a
larger one. The window is then smaller than it could be, never larger, so
the invariant holds; the cost is at most one redundant round after news.
Documented on `armRound`; not pinned.

### Tests, equivalent on both twins

Policy, pure (`gossip_timing_policy_test`, `GossipTimingPolicyTest`):

1. `armRound` answers a wait inside the jitter band of the effective
   interval and remembers that interval.
2. `recencyWindow` never exceeds any wait `armRound` can answer (seeded
   property over many draws).
3. A quiet round after arming grows the effective interval but leaves
   `recencyWindow` at the armed interval's floor until the next arm.
4. Before any arm, `recencyWindow` is the floor of the current effective
   interval; a static interval gives a static window.

Engine, adaptive timing on, with a floor-draw `Random` (Dart: `nextDouble`
answers 0; Kotlin: `nextBits` answers 0) so every wait is the floor:

5. **Own round is never suppressed at the floor.** One peer; a round
   records the exchange; advance exactly the armed wait; the next round
   sends. Today it skips.
6. **Own round is never suppressed across a quiet-round growth.** Two quiet
   rounds back to back, each at its floor wait: both send. Today the second
   skips.
7. **A peer's initiative inside the window still suppresses.** An exchange
   recorded one millisecond inside the window; the round sends nothing.
8. Existing pins keep passing: `>=` on the edge, null never fresh, a future
   timestamp stale (Kotlin), stalest-first pick, the pacing suite.

Integration, both twins: the converged-pair scenario runs under the real
jitter rather than a fixed step and asserts one exchange per interval per
pair within a band its doc derives (Kotlin `RecencySuppressionTest`; Dart's
pacing scenario gets the same band and derivation).

### Documentation

- ADR-013 amendment: the suppression window is the jitter floor of the
  interval the pending wait was drawn from, held by the timing policy, so
  the 30 s + jitter repair bound holds.
- gossip-kt `CLAUDE.md`: the pacing paragraph gains one sentence on
  `armRound` / `recencyWindow`; the services list is unchanged.
- gossip register: one flow-back row, closed in the same PRs.

## Order of landing

gossip-kt first if #22 is still open (stack on its branch, or on main after
its merge); Dart in the same session; opendoor-api bump only after both.

## Left to the builder

- Exact test names; where the floor-draw `Random` lives on each twin.
- Whether `armedInterval` is nullable with the fallback above or
  initialised from the construction-time interval. Nullable is the honest
  state ("no wait armed yet") and is the default unless it reads badly.
