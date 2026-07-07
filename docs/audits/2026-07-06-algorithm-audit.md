# Gossip Algorithm & Scheduling Audit — `gossip` core

**Date:** 2026-07-06
**Scope:** `packages/gossip` protocol layer — the gossip *algorithm* and *scheduling policy*, judged against theory (Demers et al. 1987 anti-entropy; SWIM — Das/Gupta/Motivala 2002) and the actual BLE deployment. This is a **design/behavior** audit, distinct from and following the [correctness audit](2026-07-06-correctness-audit.md) whose race/leak/silent-error findings are already remediated.
**Focus (per request):** how gossip is scheduled, and whether the algorithm is implemented properly.
**Method:** three parallel deep-read audits (scheduling & timing, anti-entropy protocol theory, SWIM conformance), each finding then verified against source by the orchestrator.

**Verification status:** every HIGH finding traced and confirmed directly in source (transport `pendingSendCount`/priority, static-timeout flag, pull-only responder, unbounded digest). MEDIUM/LOW are auditor-reported; the load-bearing ones (dead incarnation subsystem, gossip-never-resets-SWIM-contact, dead partner-rotation, fixed intermediary timeout) are spot-verified by grep.

---

## Bottom line

**Correctness: sound.** The reconciliation core is textbook-correct — version-vector domination, concurrent-VV handling, deterministic total order, idempotent merge, no split-brain. Post the correctness-audit remediation, the algorithm does not lose or corrupt data.

**Scheduling & flow-control: not properly implemented for the BLE target**, in three compounding ways:

1. The **backpressure and priority mechanisms the scheduler relies on do not exist in the BLE transport** — so the design's protection against SWIM-ping starvation is absent in production.
2. **SWIM detection latency scales the wrong way** with peer count (≈2 min to suspected, ≈6 min to unreachable at n=8) because there is no suspicion dissemination and detection is per-node with a consecutive-failure threshold of 5 under pure-random probe selection.
3. The **chat config silently disables the adaptive timing** ADR-013 introduced, pinning the ping timeout at the exact 500 ms value ADR-013 was written to eliminate.

The through-line: the adaptive/backpressure/priority machinery is well-shaped *in the abstract* but is fed by the wrong signal (tiny pings pacing large payloads), neutralized by the real transport, and accidentally switched off by config.

| Severity | Count | Themes |
|----------|-------|--------|
| HIGH | 4 | Transport neutralizes backpressure+priority; static-timeout config regression; O(n·threshold) detection latency; unbounded digest sync-death |
| MEDIUM | 6 | Pull-only (not push-pull); gossip doesn't reset SWIM liveness; sub-page pending timeout; min-SRTT pacing; dead incarnation subsystem; fixed intermediary timeout |
| LOW | 5 | Dead partner-rotation; no jitter; stale convergence claim; unqualified convergence guarantee; ADR drift |

---

## 🔴 HIGH

### H1. The BLE transport neutralizes the core's backpressure *and* priority
- `packages/gossip_bluey/lib/src/application/services/connection_manager.dart:345,348` — `pendingSendCount(peer) => 0`, `totalPendingSendCount => 0` (hardcoded).
- `:240,256` — `sendGossipMessage` accepts a `priority` param but the per-destination `_sendQueue` chains **every** send (ping or 30KB delta) into one FIFO regardless of priority.
- Core assumptions that this breaks: `gossip_engine.dart:421-435` (congestion gate), `failure_detector.dart:885` (`priority: MessagePriority.high` on pings).

**Consequences.** The gossip engine's per-peer congestion gate never filters anyone (`candidates` is never empty; the all-congested skip branch is dead code on BLE). A high-priority SWIM ping enqueues *behind* an in-flight ≤30 KB `DeltaResponse` (~150 chunks at BLE MTU); at a few KB/s that is multiple seconds of head-of-line blocking → the ping exceeds its timeout → a **false probe failure**. Compounding: the RTT estimate only advances on *successful* acks (`failure_detector.dart` `_recordRtt` needs a matched ack), so an HOL-blocked ping yields no sample, the timeout stays pinned at its floor, and it keeps timing out — a positive-feedback path straight into suspicion.

**Severity:** design-flaw, highest priority (live in the shipping transport).
**Recommendation:** implement a real per-peer priority queue in `ConnectionManager` (two-lane: high-priority pings/acks jump ahead of, or preempt between chunks of, normal gossip) and return a real `pendingSendCount` (queued depth / bytes). Until then the core's backpressure/priority provides zero protection on the deployment transport.

### H2. Static config silently pins the ping timeout at 500 ms on BLE (ADR-013 regression)
- `failure_detector.dart:126` — `_staticTimeoutsProvided = pingTimeout != null || probeInterval != null`.
- `:122` — `_pingTimeout = pingTimeout ?? 500ms`.
- `:212-235` — `effectivePingTimeout`/`effectivePingTimeoutForPeer` short-circuit to `_pingTimeout` whenever the flag is set (per-peer RTT never consulted).
- `examples/gossip_chat/lib/application/services/gossip_config_service.dart:18-19` — chat passes `probeInterval=3s`, leaves `pingTimeout=null`.

**Consequence.** Passing *any* static timing knob flips the all-or-nothing flag true, so the chat runs a fixed **500 ms ping timeout for every peer** and per-peer RTT adaptation is dead weight. 500 ms is precisely the pre-ADR-013 value that ADR blames for false positives on 100–500 ms BLE links. The "ease BLE pressure" config slowed cadence but simultaneously re-introduced the fixed 500 ms timeout.

**Severity:** design-flaw (trivial fix, high impact).
**Recommendation:** make the three knobs independently overridable — a static `probeInterval` must not disable adaptive `pingTimeout`. Track a separate "provided" boolean per knob (or derive each `effectiveX` from its own null-check). Short-term chat mitigation: pass `pingTimeout ≥ 1.5s` explicitly, or `probeInterval: null` to re-engage adaptation.

### H3. SWIM detection latency scales O(n · threshold · interval) — minutes at n=8
- One pure-random probable peer per round: `failure_detector.dart:452-461`.
- Per-peer consecutive-failure counting, thresholds 5/15: `checkPeerHealth:524-553`, `coordinator_config.dart:127-128`.
- Suspicion dissemination is an unimplemented TODO: `failure_detector.dart:517-523`.

**Quantitative.** For a dead peer, `failedProbeCount` is monotonic (no contact, never reset). Selecting that specific peer is geometric with p = 1/(n−1), so E[rounds per selection] = (n−1):

| n | → suspected = 5·(n−1) rounds | ≈ time | → unreachable = 15·(n−1) | ≈ time |
|---|---|---|---|---|
| 2 | 5 | ~20 s | 15 | ~60 s |
| 4 | 15 | ~54 s | 45 | ~2.7 min |
| 8 | 35 | ~2.1 min | 105 | ~6.2 min |

(≈3.5–4 s/round at the chat's static 3 s interval; adaptive ≈1.5 s interval roughly halves it but the congestion ceiling of 30 s makes it pathological.) Canonical SWIM detects in ~1 protocol period *independent of n* because all n−1 members probe (collectively covering each target ~once/period) and one failed direct+indirect probe → suspicion is **disseminated**. Neither exists here, so observations are never pooled and detection is 5·(n−1) periods with a heavy geometric tail. ADR-004's "0–7.5 s → suspected" timeline is valid only at n=2.

**Mitigating nuance (important).** In this deployment BLE `PeerClosed → removePeer` is the real, fast membership oracle (`connection_service.dart:31`), so slow SWIM detection mostly does not matter — *except* for half-open links (transport reports connected, peer unresponsive), which is exactly the regime where SWIM is both slow (this finding) AND prone to false-evicting live peers (H1, M2). So the practical harm is concentrated, not broad.

**Severity:** design-flaw (deepest algorithmic issue), but practical impact bounded by the transport oracle.
**Recommendation:** shuffle-based round-robin for the main probe (bounds worst-case coverage to (n−1) rounds — the mechanism already exists for the *unreachable* path via `_unreachableProbeIndex`), and reconsider `suspicionThreshold=5` toward the paper's single-period intent now that indirect-ack recovery + late-ack grace absorb false positives. Fix the ADR-004 timeline to state its n=2 assumption. Full fix would be suspicion dissemination piggybacked on gossip — likely overkill at n≤8 given the transport oracle.

### H4. Digests and `DeltaRequest.since` are unbounded → latent silent sync-death
- `generateDigest:651-659` — full VersionVector per stream per channel, every round, no budget.
- `handleDigestResponse:781` — `DeltaRequest.since = ourVersion` (full VV), no budget.
- Asymmetry: `DeltaResponse` got `maxDeltaResponseBytes = 30KB`; digests and `since` did not.
- VVs are monotonic high-water marks that survive compaction (`in_memory_entry_repository.dart` `removeEntries` deliberately never regresses the cache), so the author set only grows for the channel's lifetime.

**Quantitative.** JSON with UUID NodeIds ≈ 44 bytes per author-entry. The 32 KB transport limit is exceeded at ~745 lifetime (stream × distinct-author) pairs — e.g. a long-lived chat channel with ~100 lifetime devices × 8 streams. Past the cliff, `messagePort.send` throws → `_sendMessage:536-555` catches it as a generic `peerUnreachable` error → the identical oversized digest is rebuilt next round → **the node can never complete Step 1, never reaches delta exchange, and sync for that node is permanently dead**, surfaced only as a stream of generic per-round errors (no distinct "digest too large" signal). ADR-008/009 list digest growth as a known negative but defer mitigation.

**Severity:** design-flaw, correctness-adjacent (a genuine liveness hole). Latent at ≤8 *concurrent* devices; real for long-lived channels whose *lifetime* membership exceeds a few dozen.
**Recommendation:** paginate digests under a byte budget the way `DeltaResponse` is paginated (split by channel/stream across rounds), and/or cap/rotate the author set, and/or delta-encode VVs. At minimum, detect oversize before send and emit a distinct fatal error instead of silent per-round send failures. Apply the same to `DeltaRequest.since`.

---

## 🟠 MEDIUM

### M1. Pull-only per round, not push-pull — contradicts the "bidirectional" claim
`_handleDigestRequest:603-611` maps the initiator's digests to a channel-ID list and **discards the version vectors**; `handleDigestRequest:697-707` then replies with the responder's *own* fresh digests and never compares, requests, or pushes based on the free VVs it just received. So one full 4-step exchange transfers data **only toward the initiator**. The class doc (`gossip_engine.dart:57`) and ADR-008 both claim "Bidirectional sync: each round can sync in both directions" — false. Convergence still holds (everyone initiates) but pairwise full-sync latency and message count roughly double versus push-pull.
**Severity:** doc-mismatch (primary) + suboptimal design.
**Recommendation (cheap win):** in `handleDigestRequest`, run the same domination check `handleDigestResponse` already does against the *incoming* request digests and piggyback reciprocal `DeltaRequest`s. The digests are already in hand — this restores true push-pull at ~zero extra bandwidth.

### M2. Gossip receipt never resets SWIM liveness
`gossip_engine.dart` contains zero calls to `updatePeerContact`/`updatePeerStatus` (grep-verified). Only SWIM ping/ack/forwarded-ack and `addPeer` reset `failedProbeCount`/status. So a peer **actively exchanging gossip deltas** — unambiguous proof of life — can still be driven to suspected → unreachable (and evicted from the local `reachablePeers` gossip set) purely because its pings are HOL-blocked (H1). SWIM ignores the strongest liveness signal available.
**Severity:** suboptimal (real internal-oracle inconsistency).
**Recommendation:** call `updatePeerContact` on incoming gossip receipt (one line in the incoming handler). Removes the only scenario where an alive, actively-syncing peer is falsely evicted.

### M3. Pending-delta timeout (5 s) is shorter than one page's BLE transmit time
`gossip_engine.dart:194` — fixed 5 s, non-adaptive; flag keyed `(ChannelId, StreamId)` with no peer identity (`:187`). One ≤30 KB page at ~4 KB/s takes ~7.5 s > 5 s → the flag is deemed stale mid-transmission → a duplicate `DeltaRequest` is issued next round → the peer recomputes and re-enqueues another ≤30 KB page (correctness holds via VV dedup at merge, but the resend is pure congestion amplification, positive-feedback with H1). The per-stream key also lets a stalled slow source block issuing the same stream's request to a faster peer for up to 5 s.
**Severity:** design-flaw on BLE (suboptimal elsewhere).
**Recommendation:** adaptive timeout `≥ max(k·peerSRTT, maxDeltaResponseBytes / estimatedThroughput)` so it always exceeds one page's transmit time; key the flag per-`(peer, channel, stream)` so a stalled slow peer doesn't block faster sources (now safe since duplicates are filtered before merge).

### M4. Gossip interval tracks the *fastest* peer
`effectiveGossipInterval:266-292` — `2 × min(SRTT over reachablePeers)`, clamp [100 ms, 5 s], fed only by 66-byte SWIM pings. One fast peer (SRTT 100 ms) pins the whole loop to a 200 ms cadence even if the other peers sit at SRTT 2 s; with uniform-random selection ~(n−1)/n of those fast-cadence rounds target a slow peer with a potentially 30 KB payload — over-driving exactly the links that need protection. RTT from tiny pings underestimates true round cost by 1–2 orders of magnitude.
**Severity:** design-flaw on mixed-latency BLE mesh (mild when all peers have similar RTT).
**Recommendation:** pace the round's payload against the *selected* peer's SRTT, or at minimum use median/max SRTT rather than min.

### M5. Incarnation / refutation is an entirely dead subsystem
No `Suspicion`/`Suspect` message type exists; incarnation is **never serialized** on any Ping/Ack/PingReq (grep-verified); `incrementLocalIncarnation` and `updatePeerIncarnation` have **no non-test callers** (grep-verified — the only `lib/` hit is the TODO comment at `failure_detector.dart:518`). With no dissemination and no Suspicion message, refutation is definitionally meaningless — a node is never told it is suspected, and `Peer.incarnation` stays `null` forever.
**Severity:** dead-code + misleading docs.
**Recommendation:** **delete** the incarnation apparatus (`Peer.incarnation`, `updatePeerIncarnation`, both `incrementLocalIncarnation`s, `saveIncarnation` persistence, the incarnation-refutation branch and TODO). Recovery is already handled by contact/`addPeer`. Completing it would re-add exactly the dissemination machinery this deployment correctly forgoes.

### M6. Intermediary probe timeout fixed at 500 ms
`failure_detector.dart:137,741` — the intermediary probes the target with a fixed `_intermediaryTimeout = 500ms` while the requester waits the adaptive/static `peerTimeout` for the forwarded ack. On BLE where target RTT can exceed 500 ms, the intermediary abandons the relay before the target answers and never forwards — the requester then waits out its full `peerTimeout` for a relay that was given up early, wasting the whole indirect phase.
**Severity:** suboptimal on BLE.
**Recommendation:** make the intermediary timeout adaptive (or ≥ the requester's `peerTimeout`).

---

## 🟡 LOW

- **L1. Dead partner-rotation.** `lastAntiEntropyMs`/`updatePeerAntiEntropy` are written but the value is never read in selection, and `PeerService.recordPeerAntiEntropy` has no production caller (grep-verified). Selection is pure uniform random — the docstring's "prefer peers we haven't synced with recently" is unimplemented. Bandwidth waste / slower coverage, not incorrect. Either wire it up or delete the field.
- **L2. No jitter → phase-lock risk.** Both schedulers call `timePort.delay(interval)` with an un-jittered value (`gossip_engine.dart:320`, `failure_detector.dart:567`); `_random` is used only for peer selection. Nodes computing intervals from a shared BLE RTT signal can phase-lock → correlated request/response bursts → correlated ping timeouts → correlated false suspicions. Add a ±20% uniform random factor (standard SWIM practice).
- **L3. Stale convergence claim.** "Sub-second convergence ~150 ms" (`gossip_engine.dart:56-58`, package CLAUDE.md/README) is achievable only at n=2 with a ≤150 ms interval. Real figure is O(log n) × interval ≈ 3–5 s at the 1 s default, 6–10 s at the chat's 2 s. Fan-out=1 is the correct call for a few-KB/s BLE mesh — but incompatible with the sub-second claim at n=8. Correct the doc.
- **L4. Unqualified convergence guarantee.** ADR-008 states "all peers converge" without the preconditions it actually requires: both sides independently created the same channel+stream (creation is local-only and never propagates — intentional per code comments but undocumented at ADR level), entries within the payload budget, and digests within the transport limit (H4). Scope the guarantee in ADR-008 and the class doc.
- **L5. ADR drift.** ADR-004 says thresholds 3/9; code (via `CoordinatorConfig`) uses 5/15. ADR-013 says min ping timeout 200 ms; code uses 500 ms, and claims timing params were removed from `CoordinatorConfig` though `gossipInterval`/`probeInterval`/`pingTimeout` still exist there. Reconcile docs to code.

---

## Correctly designed (keep — don't touch)

- **Version-vector reconciliation.** `!ourVersion.dominates(theirs)` with `since: ourVersion` is exactly right; concurrent VVs (neither dominates) converge because each node evaluates domination from its own side; disjoint author sets reduce to the concurrent case; no split-brain (mutual domination forces equality). Verified.
- **Convergence safety.** Append-only + idempotent/commutative/associative max-merge + duplicate filtering before merge + deterministic total order (timestamp→author→sequence) + compaction-safe monotonic high-water marks. No divergence or lost-update path found.
- **RTT estimation.** RFC-6298-faithful EWMA (α=1/8, β=1/4, first-sample init, timeout = SRTT + 4·RTTVAR) with sample clamping [50 ms, 30 s]. Textbook.
- **Forwarded-ack RTT attribution.** 2-hop indirect acks are correctly excluded from the per-peer estimate (fed only to the global tracker) — avoids systematic inflation. Subtle and right.
- **Indirect probing core.** Up to 3 intermediaries, `PingReq` with local re-sequencing at the intermediary and the requester's sequence echoed back — the core SWIM innovation, correctly implemented, including forwarded-ack sender validation.
- **`probeNewPeer` bootstrap + `startupGracePeriod`.** Directly mitigates the (n−1)-round first-RTT delay and startup false positives.
- **Timing feedback stability.** The congestion loop (RTT↑ → timeout↑ → interval↑ → less probing) is negative feedback / self-damping, bounded by EWMA smoothing, hard clamps, and sample clamping. No runaway path.
- **Generation-token loop guards** and the *shape* of per-peer congestion gating and DeltaResponse budgeting (just needs a real `pendingSendCount` and the same treatment extended to digests).

---

## Suggested priority

1. **H1** — real priority queue + `pendingSendCount` in the BLE transport (highest value, most involved; worth a design discussion first).
2. **H2** — decouple the static-timeout config flag (small, high impact).
3. **M2** — feed gossip receipt into `updatePeerContact` (one line; stops false eviction of syncing peers).
4. **H4** — bound/paginate digest and `DeltaRequest.since` size (prevents silent sync-death on long-lived channels).
5. **M5** — delete the dead incarnation subsystem (removes complexity + misleading docs).
6. **H3 / M1 / M3 / M4 / M6** — scheduling refinements (round-robin probe, push-pull reciprocation, adaptive pending timeout, per-selected-peer pacing, adaptive intermediary timeout).
7. **L1–L5** — doc reconciliation and jitter.

Items H1–H3 and M2 are the ones that change real BLE behavior today; the rest are latent, doc, or scale-dependent.
