# Gossip Algorithm & Scheduling Audit — `gossip` core

**Date:** 2026-07-06
**Scope:** `packages/gossip` protocol layer — the gossip *algorithm* and *scheduling policy*, judged against theory (Demers et al. 1987 anti-entropy; SWIM — Das/Gupta/Motivala 2002) and the actual BLE deployment. This is a **design/behavior** audit, distinct from and following the [correctness audit](2026-07-06-correctness-audit.md) whose race/leak/silent-error findings are already remediated.
**Focus (per request):** how gossip is scheduled, and whether the algorithm is implemented properly.
**Method:** three parallel deep-read audits (scheduling & timing, anti-entropy protocol theory, SWIM conformance), each finding then verified against source by the orchestrator.

**Verification status:** every HIGH finding traced and confirmed directly in source (transport `pendingSendCount`/priority, static-timeout flag, pull-only responder, unbounded digest). MEDIUM/LOW are auditor-reported; the load-bearing ones (dead incarnation subsystem, gossip-never-resets-SWIM-contact, dead partner-rotation, fixed intermediary timeout) are spot-verified by grep.

**Remediation status (updated as fixes land):**
- ✅ **H2** — static ping-timeout / probe-interval flags decoupled (`8b8ab80`). Chat now gets adaptive per-peer ping timeouts.
- ✅ **M2** — gossip receipt feeds `updatePeerContact`, so an actively-syncing peer isn't false-evicted (`0ed2c58`).
- ✅ **M1** — push-pull reciprocation on `DigestRequest`, gated on running so pause semantics hold (`f8c2e1c`).
- ✅ **Contiguity guard** — `handleDeltaResponse` applies only the per-author contiguous run, hardening the merge path and making unsolicited pushes safe (`7526336`).
- ✅ **G1** — reactive push-on-write: a local write is debounced and pushed directly to peers; paused engines serve but don't ingest/pull (`52a6d25`).
- ✅ **G2** — sync-on-connect: `addPeer` kicks off an immediate targeted DigestRequest (`708575c`).
- ✅ **G4** — catch-up continuation: `DeltaResponse.hasMore` drives an immediate continuation request, draining a backlog at link speed (`62aa4c9`).
- ✅ **H4** — digests budgeted with round-robin stream rotation; responder scopes/budgets its reply; single oversized stream skipped with a distinct error (`f2eba32`).
- ✅ **G3** — periodic auto-compaction enforces retention policies (`CoordinatorConfig.compactionInterval`, default 5 min); fixes the chat presence-stream leak (`b483f1d`).
- ⏳ Remaining: H1 (transport priority queue — port from nearby), H3, M3–M6, G5, L1–L5.

---

## Bottom line

**Correctness: sound.** The reconciliation core is textbook-correct — version-vector domination, concurrent-VV handling, deterministic total order, idempotent merge, no split-brain. Post the correctness-audit remediation, the algorithm does not lose or corrupt data.

**Scheduling & flow-control: not properly implemented for the BLE target**, in three compounding ways:

1. The **backpressure and priority mechanisms the scheduler relies on do not exist in the BLE transport** — so the design's protection against SWIM-ping starvation is absent in production.
2. **SWIM detection latency scales the wrong way** with peer count (≈2 min to suspected, ≈6 min to unreachable at n=8) because there is no suspicion dissemination and detection is per-node with a consecutive-failure threshold of 5 under pure-random probe selection.
3. The **chat config silently disables the adaptive timing** ADR-013 introduced, pinning the ping timeout at the exact 500 ms value ADR-013 was written to eliminate.

The through-line: the adaptive/backpressure/priority machinery is well-shaped *in the abstract* but is fed by the wrong signal (tiny pings pacing large payloads), neutralized by the real transport, and accidentally switched off by config.

**Dissemination: only half the canonical design is present, and the engine is purely timer-driven.** The library runs periodic anti-entropy (the completeness safety net) but the gossip engine **never reacts to events** — not to a local write (G1), not to a peer connecting/reconnecting (G2), not to a known-incomplete backlog after a truncated page (G4). Everything waits for the next random timer tick. Compounded by pull-only (M1), a sent chat message can take several seconds to appear; a reconnecting peer isn't reconciled until randomly selected; a large backlog drains at ~1 page per *n* intervals. Separately, retention policies are declared per stream but **nothing ever enforces them** (G3), so storage grows unbounded. These are scope choices, not defects, but collectively they are the biggest gap between the library and a production offline-first sync engine.

| Severity | Count | Themes |
|----------|-------|--------|
| HIGH | 4 | Transport neutralizes backpressure+priority; static-timeout config regression; O(n·threshold) detection latency; unbounded digest sync-death |
| GAP | 5 | Engine is purely timer-driven — no reaction to write (G1), peer connect (G2), or known backlog (G4); retention declared but never enforced (G3); no in-sync signal (G5) |
| MEDIUM | 6 | Pull-only (not push-pull); gossip doesn't reset SWIM liveness; sub-page pending timeout; min-SRTT pacing; dead incarnation subsystem; fixed intermediary timeout |
| LOW | 5 | Dead partner-rotation; no jitter; stale convergence claim; unqualified convergence guarantee; ADR drift |

---

## 🔴 HIGH

### H1. The BLE transport neutralizes the core's backpressure *and* priority
- `packages/gossip_bluey/lib/src/application/services/connection_manager.dart:345,348` — `pendingSendCount(peer) => 0`, `totalPendingSendCount => 0` (hardcoded).
- `:240,256` — `sendGossipMessage` accepts a `priority` param but the per-destination `_sendQueue` chains **every** send (ping or 30KB delta) into one FIFO regardless of priority.
- Core assumptions that this breaks: `gossip_engine.dart:421-435` (congestion gate), `failure_detector.dart:885` (`priority: MessagePriority.high` on pings).

**Consequences.** The gossip engine's per-peer congestion gate never filters anyone (`candidates` is never empty; the all-congested skip branch is dead code on BLE). A high-priority SWIM ping enqueues *behind* an in-flight ≤30 KB `DeltaResponse` (~150 chunks at BLE MTU); at a few KB/s that is multiple seconds of head-of-line blocking → the ping exceeds its timeout → a **false probe failure**. Compounding: the RTT estimate only advances on *successful* acks (`failure_detector.dart` `_recordRtt` needs a matched ack), so an HOL-blocked ping yields no sample, the timeout stays pinned at its floor, and it keeps timing out — a positive-feedback path straight into suspicion.

**Cross-package asymmetry (new — transport audit).** The sibling transport **`gossip_nearby` already implements exactly this**: `connection_service.dart:77-81` has separate `_highPriorityQueue`/`_normalPriorityQueue`, `_processQueues` (`:196-205`) always drains high-priority first, and `pendingSendCount`/`totalPendingSendCount` (`:177-193`) return real queue depths. So the mechanism the core's design assumes is proven and present in-repo — `gossip_bluey` simply omitted it (its `_sendQueue` is a bare per-peer `Future` chain with no depth notion, so `pendingSendCount` can only return 0). The irony: the transport **with** the machinery (`gossip_nearby`) is used by no example, while the transport **without** it (`gossip_bluey`) is the shipping one on the most bandwidth-constrained medium (BLE) — exactly backwards from where the protection is needed. (Minor, both: neither priority queue is depth-bounded, so a sustained-congestion sender can grow the queues without limit; add a drop/backpressure ceiling.)

**Severity:** design-flaw, highest priority (live in the shipping transport).
**Recommendation:** port `gossip_nearby`'s `ConnectionService` priority-queue + `pendingSendCount` pattern into `gossip_bluey`'s `ConnectionManager` (two-lane: high-priority pings/acks jump ahead of, or preempt between chunks of, normal gossip; return real queued depth/bytes). There is a working reference implementation in the same repo — this is a port, not a design problem. Until then the core's backpressure/priority provides zero protection on the deployment transport.

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

## 🟣 DESIGN GAP

**Unifying root cause for G1/G2/G4: the gossip engine is purely timer-driven and reacts to no events.** `performGossipRound` fires only from `_scheduleNextGossipRound`'s timer (verified). It never reacts to a local write, a peer connecting, or a known-incomplete backlog — all three just wait for the next random tick. G3 (retention) and G5 (in-sync signal) are separate absences. None of these are defects in what exists; they are standard capabilities of an offline-first sync engine that are simply not present.

### G1. No reactive dissemination (rumor mongering) — new writes wait for the periodic sweep
**Impact: HIGH for interactive/chat use. Verified: the write path has zero coupling to the gossip engine; `performGossipRound` fires only from the timer loop.**

Canonical epidemic replication (Demers et al. 1987) combines **two** mechanisms: *rumor mongering* (on a new update, actively push it to peers right away — the fast path, O(log n) rounds) and *anti-entropy* (a periodic background digest/delta sweep — the completeness safety net). The recommended design runs both: rumor mongering for speed, anti-entropy for completeness.

This library implements **only the anti-entropy safety net** (intentional per ADR-008's framing). There is no reactive path:
- `GossipEngine` has no "trigger a round now" method (grep-verified).
- `EventStream.append` → `ChannelService.appendEntry` → repository has **zero coupling to the gossip engine** (grep-verified).
- `performGossipRound` is driven solely by the timer (`gossip_engine.dart:614`).

So a local write sits in the repository until the next timer tick. **Compounded by pull-only (M1):** a round the writer *initiates* pulls data *toward* the writer — it does not push the write outward. The write propagates only when some *other* peer independently selects the writer; each node runs its own timer, so on average ~1 peer picks the writer per interval, then it spreads O(log n) intervals. Net for the chat app at its 2 s interval: **a sent message can take from ~2 s up to several seconds to appear on peers** — a very visible latency on the product's core action.

**Concrete chat impact.** Both `messages` and `presence` (typing) rely on this path. A sent message appears on a 2-peer link in ~0–2 s (avg ~1 s); at n=8 a message takes ~8–10 s to reach all peers (see the network-numbers note below). Worse, the **typing indicator** is an ephemeral `presence` event on the same path, so "user is typing…" also carries ~2 s+ latency — usually too late to be useful (the message often arrives before the indicator).
**Severity:** design gap (intentional scope choice, not a defect), but HIGH-impact for interactive use. It is the single biggest thing between the chat app and instant-feeling delivery.
**Recommendation:** add a debounced reactive push (design sketch in the appendix). De-risked by M2 (so extra traffic can't false-evict peers) and cleanest after H1 (priority lane); composes with M1.

### G2. No sync-on-connect — a newly connected/reconnected peer isn't reconciled until the timer randomly selects it
**Impact: HIGH for partition healing / reconnect. Verified: `addPeer` triggers a SWIM probe but no gossip round.**

`Coordinator.addPeer` (`coordinator.dart:551-577`) fires an immediate `probeNewPeer` for *SWIM RTT bootstrap* — and its own comment notes why ("could take ~45s with 5 peers" to be selected by the random probe loop otherwise). But the identical problem for **gossip** is not solved: nothing triggers an anti-entropy round when a peer arrives. So after a peer connects (a fresh join, or a reconnect after a partition), the two nodes don't reconcile until the random gossip timer happens to select that peer — expected ~(n−1) intervals for a *specific* peer, and worse under pull-only (M1) since the reconnecting peer's own round pulls toward itself. This is precisely the scenario anti-entropy exists to handle well (partition heal), yet the *trigger* is slow. The SWIM path already demonstrates the fix pattern (react to `addPeer`); gossip just doesn't use it.

**Severity:** design gap, HIGH-impact for reconnect/partition-heal latency.
**Recommendation:** on `addPeer` (and on transport `PeerOpened`/reconnect), trigger one immediate gossip round targeted at the new peer — the direct analogue of `probeNewPeer`. Cheap; reuses `performGossipRound` with a forced target. Composes with M1 (so the exchange is push-pull) and the G1 machinery (an expedited round with an explicit target).

### G3. Retention policies are declared but never enforced — storage grows unbounded
**Impact: MEDIUM (a silent storage leak over time). Verified: `compact()` is only the public facade method; no scheduler or example ever calls it.**

`Channel.getOrCreateStream(retention: ...)` attaches a `RetentionPolicy` per stream, which reads as set-and-forget. But `EventStream.compact()` (`event_stream.dart:198`) is the *only* thing that applies retention, it is **app-invoked**, and nothing in the library (no timer, no lifecycle hook) ever calls it — nor does any example (`grep` of `examples/`: zero `.compact()` calls). So retention policies are inert unless the app builds its own compaction scheduler. For a long-running chat app that means the entry log grows without bound (which also feeds the digest-size cliff, H4), while the declared `TimeBasedRetention`/`CountBasedRetention` does nothing.

**Concrete chat impact.** The chat's `presence` stream declares `TimeBasedRetention(30 s)` (`chat_service.dart:25,64`) — but nothing ever compacts it, so every typing event (2 per typing episode: start + stop) accumulates **forever**. `getTypingUsers` then does a `getAll()` scan over that ever-growing log on every read (`chat_service.dart:235`). The 30 s retention is pure fiction today; over a long session the presence stream is an unbounded memory + scan-cost leak. (`messages`/`metadata` also never compact, but KeepAll/rare-write make them less acute.)
**Severity:** design gap + API-implication mismatch (a real footgun).
**Recommendation:** either (a) have the library run a low-priority periodic compaction pass that applies each stream's retention policy (opt-out), or (b) if compaction is deliberately app-driven, make that explicit in the API/docs (e.g. rename toward `manualCompact()`, document that retention is not auto-enforced, and ship a ready-made periodic-compaction helper). Today the API promises retention it doesn't deliver.

### G4. No catch-up acceleration — a truncated delta page triggers no continuation; backlog drains at gossip cadence
**Impact: MEDIUM-HIGH for cold-join / post-offline catch-up. Verified: `DeltaResponse` has no "hasMore" field; `handleDeltaResponse` merges and stops.**

The pagination design (per-author-contiguous prefix under a 30KB budget) is correct and was praised — but the *drain trigger* is missing. `DeltaResponse` carries no truncated/hasMore signal (`delta_response.dart`), and `handleDeltaResponse` merges the page, clears the pending flag, and returns without requesting the remainder. So the next page is pulled only when the random timer next selects that same peer, re-runs a full digest exchange, and re-detects the gap — ~1 page per (interval × peer-selection odds) ≈ **1 page per *n* intervals**. At n=8 / 2s that is ~1 page (≤30KB) per 16s; a 300KB backlog (a device joining a channel with modest history, or returning after an outage) takes minutes, even on an otherwise idle link that could carry it in seconds. Catch-up throughput is coupled to steady-state gossip cadence with no fast path, and no priority for peers known to have a backlog (compounded by dead partner-rotation, L1).

**Severity:** design gap, MEDIUM-HIGH for initial sync / rejoin.
**Recommendation:** add a `hasMore` flag to `DeltaResponse` (or infer truncation from budget) and, when set, immediately issue the next `DeltaRequest` to the same peer — a continuation loop that drains the backlog at link speed instead of gossip cadence, bounded by the same congestion gate. Decouples catch-up from the anti-entropy interval.

### G5. No convergence / "in-sync" signal for applications
**Impact: LOW (missing observability). Verified: no `isSynced`/convergence API — all "convergence" mentions are doc prose.**

An app cannot ask "am I caught up with my peers?" — there is no API surfacing whether the local version vectors have caught up to peers' last-advertised digests, so a chat UI can't show "syncing…" vs "up to date," and initial-sync completion is unobservable. The library can't fully answer this today anyway because it retains no per-peer digest state (it recomputes on demand). A partial signal (last-merge time, pending-delta count, per-peer VV lag) would cover the common UX need.

**Severity:** design gap, LOW (nice-to-have observability).
**Recommendation:** expose a coarse per-peer sync-status (e.g. "have an outstanding delta request" / "last digest showed peer ahead") or at least a "quiescent" signal (no pending requests + last N rounds produced no new entries). Optional; scope to the interactive use case.

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

Ordered to get the interactive/reconnect responsiveness wins (G1/G2) safely and early rather than last:

1. **H2 + M2 (+ M1)** — an afternoon; pure wins. H2 decouples the static-timeout flag; M2 feeds gossip receipt into `updatePeerContact` (one line) and is the specific de-risker that lets the reactive gaps add traffic without false-evicting peers; M1 adds push-pull reciprocation (cheap; composes with G1/G2).
2. **G1 + G2** — the event-driven triggers: reactive push-on-write (G1) and sync-on-connect (G2). Same root cause and same machinery (an expedited round with a target); land them together. Biggest perceived-latency + reconnect wins; safe once M2 is in.
3. **G4** — catch-up continuation (`hasMore` + drain-to-completion). Turns cold-join / rejoin from minutes into seconds; small change to `DeltaResponse` + `handleDeltaResponse`.
4. **H1** — real priority queue + `pendingSendCount` in the BLE transport (highest robustness value, most involved; worth a design discussion). No longer a blocker for the reactive gaps once M2 is done, but still needed for scale/robustness and now more relevant since G1/G2/G4 add traffic.
5. **H4** — bound/paginate digest and `DeltaRequest.since` size (prevents silent sync-death on long-lived channels).
6. **G3** — enforce retention automatically (or make non-enforcement explicit + ship a helper). Prevents unbounded storage growth, which also feeds H4.
7. **M5** — delete the dead incarnation subsystem.
8. **H3 / M3 / M4 / M6** — scheduling refinements (round-robin probe, adaptive pending timeout, per-selected-peer pacing, adaptive intermediary timeout).
9. **G5 / L1–L5** — in-sync signal, doc reconciliation, jitter.

Items G1, G2, G4, H1–H3, and M2 are the ones that change real BLE behavior today; the rest are latent, doc, or scale-dependent.

---

## Appendix — reactive push-on-write design sketch (G1)

Goal: disseminate a local write within ~sub-second, without write storms, on a few-KB/s transport. The periodic anti-entropy loop is left **unchanged** as the completeness safety net.

**1. Write hook (the missing coupling).** After a successful `ChannelService.appendEntry`, the coordinator notifies the engine: `GossipEngine.notifyLocalWrite(channelId, streamId)` (or a coarser `notifyLocalActivity()`).

**2. Debounce / coalesce.** On `notifyLocalWrite`, the engine schedules an *expedited* round after a short delay `D` (~100–200 ms) unless one is already scheduled or a periodic round is imminent. A burst of N writes within `D` collapses to one expedited round. Rate-cap expedited rounds (e.g. ≥250 ms apart) to bound amplification. This keeps human-paced chat gentle and protects against programmatic write bursts.

**3. Direction — two options.**
- **Option A (reuses M1):** the expedited round sends a `DigestRequest`; with M1's push-pull reciprocation the peer sees the writer is ahead and pulls. Pure anti-entropy, reuses the 4-step machinery, but costs a full round-trip and *requires M1*.
- **Option B (push rumor mongering, standalone) — recommended for chat:** on write, push the *new entries* directly as an unsolicited `DeltaResponse` to selected peers. `handleDeltaResponse` already merges unsolicited deltas idempotently (dupes filtered), so no new receive path is needed. One small message, no round-trip — sharpest latency for tiny chat payloads. Independent of M1 (though M1 still helps the periodic path).

**4. Fan-out.** At n≤8, push to **all reachable peers** (≤7 small messages) for deterministic one-hop dissemination. (Classic rumor mongering pushes to a random subset and relies on re-spread + "infect and die"; unnecessary complexity at this scale.)

**5. Priority (H1 interaction).** Pushes ride the normal gossip lane and must not starve SWIM pings. On today's transport (no priority) they compete with pings — which is why **M2 is the prerequisite** (gossip receipt keeps the peer reachable even if a ping is starved), and why H1's priority lane makes it fully clean. Debounce + rate-cap + small payloads keep it bounded before H1 lands.

**6. Safety net unchanged.** The periodic loop still catches anything a push missed (lost message; peer congested/suspected/disconnected at push time; a peer that had no reachable status when the write happened). This is the "safety net" half — already present and correct.

Recommended concrete plan: **Option B**, debounced (~150 ms) + rate-capped, fan-out to all reachable peers, gated behind M2; periodic anti-entropy untouched.

---

## Appendix — network numbers (chat config: 2 s gossip / 3 s probe, 3 streams, full mesh)

Calculated estimates (not measured). Digest ≈ one version vector per stream; ~44 B per author-entry (UUID keys in JSON); fan-out = 1, each node runs its own timers.

| Metric | 2 peers | 8-peer mesh (steady) | 8-peer start (cold) |
|---|---|---|---|
| Digest size / message | ~0.5 KB (2 authors) | ~1.3 KB (8 authors × 3 streams) | ramps as authors appear |
| Idle traffic, per node | ~0.5 KB/s | ~1.3 KB/s each way | spikes with delta bursts |
| Idle traffic, whole mesh | ~1 KB/s | ~10–11 KB/s | higher during convergence |
| BLE connections / node | 1 | 7 (near radio ceiling) | 7, forming over first seconds |
| 1 message → all peers | ~1–2 s | ~8–10 s | ~8–10 s once converged |
| Cold-start trigger delay (G2) | up to +2 s | — | up to +2 s (no sync-on-connect) |
| Backlog catch-up, new joiner (G4) | 1 page / 2 s | — | 1 page / ~14 s → 300 KB ≈ ~2.5 min |
| SWIM time-to-suspected | ~20 s | ~2 min | ~2 min |

Key shifts 2 → 8: per-node overhead grows only ~2.6× (bigger digest, not more rounds — fan-out is 1), but mesh **aggregate** grows ~10× (n × digest) and **message-propagation latency grows ~8–10×** (fan-out 1 + pull-only means a rumor crawls ~5 hops × 2 s). Steady state is fine on bandwidth; the **cold start** is where it hurts, gated by G2 (no trigger) and G4 (slow catch-up). Digest size tracks *lifetime* authors (H4), so it keeps rising past 8 as devices churn.
