# Two-Tier Pacing: Quiet Anti-Entropy + SWIM Probe Suppression

**Date:** 2026-08-20
**Status:** Approved (design); implementation pending
**Drives:** WIRE4-1, WIRE4-2, WIRE4-3, WIRE4-4, WIRE4-5 and the responder
half of WIRE4-1 — recommendations R3 + R4 of the
[2026-08-20 wire-scheduling audit](../../audits/2026-08-20-wire-scheduling-audit.md).

## Problem

A fully-converged, healthy network never goes quiet. Both scheduling
loops adapt to *latency*, not *news*: the gossip round runs at
`2 × median SRTT` clamped [100 ms, 5 s], the SWIM probe at
`3 × ping timeout` floored at 1.5 s — so a healthier link chatters
*more*, and the quietest reachable state is a full digest exchange per
pair per 5 s plus a ping/ack per 1.5 s, forever (~3.5 msgs/s, ~330 B/s
at n=2). The one signal that could suppress probes (`lastContactMs`,
updated by every inbound message) is written but never read. The
converged `DigestResponse` echoes version vectors the requester already
proved it has. Field systems run their repair tier 1–3 orders of
magnitude slower than their event tier (memberlist 30 s, Erlay 16 s,
Bluetooth Mesh 10→600 s); this library's event tier (reactive push,
150 ms debounce) already exists — only the "rest when idle" half is
missing.

## Owner decisions (Joel, 2026-08-20)

1. **Idle ceiling: 30 s** for both loops. Worst-case repair of a lost
   push = 30 s + scheduling jitter (±20%, see `applyJitter`) per affected
   pair — not a flat 30 s, since every scheduled round is jittered before
   it fires. Not configurable (no new knobs).
2. **Backoff only — no convergence-memory skip.** The safety net always
   actually exchanges, just rarely. No cached-VV skip: a stale cache
   would silently desync; time-based mechanisms only, every exchange
   verifies reality on the wire.
3. **Minutes-scale detection of half-open links in a deep-idle mesh is
   acceptable.** Hard disconnects are unaffected (BLE link layer →
   transport → `removePeer` is instant); SWIM idle probing only covers
   the rare half-open case.

## Design

### 1. `QuiescencePacer` — pure domain service

`domain/services/quiescence_pacer.dart`. One instance per loop.

- State: a single growth multiplier, starting at 1.
- `news()` → multiplier = 1.
- `quietRound()` → multiplier ×= 1.5 (capped so `apply` can hit the
  ceiling; no unbounded growth).
- `apply(Duration base)` → `min(base × multiplier, ceiling)`.
- No clocks, timers, or I/O. Constructor: `QuiescencePacer(ceiling:
  Duration, growth: 1.5)`.

Both loops reach their ceiling from base within ~8–10 quiet rounds.

### 2. Gossip engine (protocol layer)

- `effectiveGossipInterval` = `pacer.apply(adaptiveBase)`;
  `adaptiveBase` is today's formula unchanged (median SRTT × 2, clamped
  [100 ms, 5 s]). A user-pinned static `gossipInterval` bypasses the
  pacer entirely (explicit override stays verbatim, as today).
- **Quiet round:** no news occurred since the previous round completed.
  Implemented as a news flag the round loop reads-and-clears.
- **News (resets the pacer):**
  - local append (`notifyLocalWrite`);
  - any `DeltaRequest` sent or received;
  - any non-empty `DeltaResponse` we *send* (serving a puller — the act of
    serving is news regardless of what the puller does with it);
  - a `DeltaResponse` we *receive* only when it actually merges at least
    one new entry — refined during implementation to be stricter than
    "non-empty": a response that is non-empty on the wire but resolves to
    zero accepted entries (all already held, or dropped by the contiguity
    guard) is redundancy, not novelty, and must not reset the pacer;
  - peer added or removed (registry membership change);
  - `syncWithPeer` (join/reconnect fast path).
- **Responder-side exchange recording** (missing half of WIRE4-1):
  handling an inbound `DigestRequest` records
  `updatePeerAntiEntropy(sender, now)`, so a reciprocated exchange
  counts as coverage in both directions.
- **Round-level recency suppression** (time-based; distinct from the
  rejected VV-cache skip): a round skips candidates whose
  `lastAntiEntropyMs` is fresher than the current effective interval;
  if every candidate is fresh, the round sends nothing. Worst case of a
  wrong skip is one interval of extra delay — self-correcting by
  construction.
- **Dominance filter (WIRE4-5):** `handleDigestRequest` omits (channel,
  stream) pairs whose requester vector dominates ours. Safe because the
  initiator only pulls when the response shows the responder ahead, and
  the responder-behind direction is handled by the responder's own
  reciprocal pull. A fully converged response encodes to ~63 B.

### 3. Failure detector (protocol layer)

- `effectiveProbeInterval` = `pacer.apply(base)`; base is today's
  formula (ping timeout × 3, floor 500 ms); ceiling = the existing
  30 s max. Static `probeInterval` override bypasses the pacer.
- **Probe suppression (WIRE4-3):** `selectRandomPeer` skips peers whose
  `lastContactMs` is fresher than the current effective probe interval
  (gossip traffic is liveness evidence — `lastContactMs` finally gets a
  reader). Skipped peers advance the round-robin cursor; if every
  candidate is fresh, no probe fires this round (a quiet round).
- **Probe suppression is capped (final review, item 2):** freshness alone
  keys on INBOUND evidence, which under asymmetric one-way loss (our
  probes to a peer die, but the peer's own traffic — e.g. its own
  unreachable-probing of us — keeps arriving) never stops, suppressing
  the peer forever with no detection. Every peer is therefore actually
  probed at least once per 2-minute cap window (4× the 30 s ceiling, not
  configurable) regardless of freshness, bounding half-open detection
  under one-way loss.
- **Quiet round:** the round's probe (if any) was answered, or all
  candidates were suppressed-by-freshness.
- **Reset:** any missed ack (direct + indirect both failed), any
  suspicion/unreachable transition, a peer becoming newly probable
  (added, or `start()` after a pause — final review, item 1), or an
  unreachable peer recovering. A peer's *removal* deliberately does NOT
  reset this pacer — the registry shrinking is self-evident and needs no
  immediate re-probe of the remaining peers. This differs from the
  gossip engine's pacer (§2), which resets on both addition and removal.

### 4. Expected idle footprint (n=2, converged, healthy BLE)

Today: ~3.5 msgs/s, ~330 B/s, forever. After: both loops at 30 s within
~10 quiet rounds → about one ~310 B digest exchange per 30 s (a ~249 B
request plus a ~63 B dominance-filtered response; recency suppression
means only one side of the pair initiates per window), with probes
mostly suppressed because the exchange itself refreshes `lastContactMs`
≈ **~10 B/s, ~4 radio wakeups/min**, plus the 150 ms reactive push and
instant snap-back on any news.

### 5. Out of scope (deliberately)

- Convergence-memory / VV-cache round skipping (rejected, decision 2).
- Digest hashing, batched deltas, push-pull completion, SWIM/gossip
  piggybacking, author-index wire format (R7/R8, later batches).
- New configuration knobs (ceiling and growth are constants).
- Trickle's redundancy constant k / listen windows (broadcast-medium
  concepts; degenerate at n≤8 point-to-point).

### 6. Testing

- **Pacer:** pure unit tests (growth curve, reset, ceiling clamp, cap).
- **Engine/detector units:** structural assertions under simulated time
  — grow/reset/skip decisions, not wall-clock rates (InMemoryTimePort
  quantizes RTT to the advance step; rate assertions are artifacts).
  Use static-interval configs where determinism is needed.
- **Integration:** an idle converged network's per-window message count
  decays round over round; a local write snaps the cadence back to
  base; a deliberately dropped reactive push is repaired within
  30 s + scheduling jitter (±20%); suppressed probes do not mark peers
  stale; a half-open peer is still detected (suspected → unreachable)
  after backoff; a peer suppressed only by continuous inbound freshness
  is still actually probed once every 2-minute cap window.
- **Regression:** the full suites stay green. Convergence-speed tests
  are protected: news resets keep the active phase at today's cadence.

### 7. Documentation

- ADR-013 gains the idle/active (two-tier) distinction and the pacer.
- The stale "every 200 ms" claims in `gossip_engine.dart` docs and
  ADR-008's timing section are corrected in passing (engine half of
  WIRE4-34).

## DDD placement

The pacer is pure domain (`domain/services/`), like `HlcClock` and
`jitter`. News classification and suppression decisions are protocol
policy expressed as small pure predicates; timers and sends stay in the
protocol layer. No new infrastructure. This anticipates the planned
`sync/` / `detection/` restructure: the pacer is shared-kernel-adjacent
and moves cleanly.
