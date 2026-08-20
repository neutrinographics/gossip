# Wire-Send Scheduling Audit — gossip + gossip_bluey

**Date:** 2026-08-20
**Scope:** Every code path that puts bytes on the wire, and the scheduling that drives it: `packages/gossip` protocol layer (GossipEngine round scheduling, digest/delta exchange, reactive push; FailureDetector probe scheduling; ProtocolCodec wire sizes), the facade paths that trigger sends (`Coordinator.addPeer`, event fan-out), and the whole of `packages/gossip_bluey` (send path, framing, radio configuration, auto-connect). **Excluded:** `packages/gossip_nearby` (the owner's deployment is BLE; the Nearby transport deserves the same audit before any Nearby deployment).
**Rubric (domain-specific):** wire-send scheduling efficiency for a BLE deployment — phones, a few KB/s effective throughput, every radio wakeup costs battery, n ≤ 8. The owner's stated ideal, confirmed as the correct model before the audit began: *event-driven dissemination when there is news, plus a low-rate periodic anti-entropy safety net; a converged network is near-silent apart from a bounded failure-detection heartbeat.* The design is judged against that ideal, against its own ADRs (004, 008, 013), and against the field (see "Where the design sits relative to the field").
**Baseline:** [2026-07-08 comprehensive audit](2026-07-08-comprehensive-audit.md). Findings that audit already owns are cited, not re-counted.
**Method:** 3 deep-read agents by territory (core engine send scheduling · SWIM probe traffic · gossip_bluey transport), each reading its territory **in full** (all 29 gossip_bluey lib files; all protocol/facade/codec files in scope), plus 1 external-research agent surveying comparable systems. Gates run by the orchestrator: `dart test` (gossip, 972 passed) and `flutter test` (gossip_bluey, 200 passed), both green. An empirical wire-traffic probe (link-tap counters over the in-memory bus, since deleted) measured idle and dissemination traffic directly. **Every finding below was personally re-verified by the orchestrator against source, including the bluey dependency in the pub cache**; adjusted and re-graded claims are listed in their own section. IDs are `WIRE4-n` (audit ordinal 4).

---

## Verdict

The owner asked: *do we only send when there is news, plus an occasional safety net — is a balanced network quiet?* The answer today is **no, and it cannot be made quiet with any supported configuration** — but the distance to "yes" is smaller than the finding count suggests, because the hard half is already built.

**What exists and is genuinely good:** the event tier the ideal requires is real — local writes are pushed reactively (150 ms debounce, coalesced per stream, unsolicited `DeltaResponse` to peers), merged entries are deliberately *not* re-pushed (no O(n²) relay amplification), a converged digest exchange terminates after 2 messages, periodic fan-out is exactly 1 peer per round, and the BLE transport invents **zero traffic of its own** — no keepalives, no polling, no handshake, one 10-byte control frame in the whole package. The engineering quality of what's there is high: jitter, generation tokens, budget rotation, `hasMore` continuation with no-progress guards, per-peer priority queues, adaptive RFC-6298-style timeouts on the delta path.

**What's missing is the "quiet" half, in three independent layers that compound:**

1. **The schedulers never rest.** Nothing anywhere remembers "this peer and I were in sync a moment ago." The gossip round fires unconditionally forever; its "adaptive" interval is `2 × RTT` clamped [100 ms, 5 s] — it adapts to *latency*, not to *news*, so a healthier link produces **more** idle traffic, and the quietest reachable cadence is one full digest exchange per peer-pair per 5 s. SWIM is the same shape: probe interval `3 × ping timeout`, floor-pinned at 1.5 s on any good link, and the one signal that could suppress it (`lastContactMs`, updated by every gossip message) is **written but never read**. Measured: a converged 2-node network exchanges full digests plus ping/ack forever; ~500 B and 2+ radio transactions per node per interval, indefinitely, carrying zero information.
2. **The idle bytes are fatter than they need to be.** The converged `DigestResponse` echoes back version vectors the requester's own digest already proves it has (a one-line dominance filter shrinks it to ~63 B); digests repeat full 36-char UUIDs per author per stream per round (~60 % of digest bytes); every peer receives digests for *all* the sender's channels regardless of overlap.
3. **The radio configuration undoes the transport's discipline.** The BLE scan runs continuously at `SCAN_MODE_LOW_LATENCY` (iOS: `allowDuplicates: true`) and advertising at LOW_LATENCY + TX_POWER_HIGH (~1,800 PDUs/min) **forever, even on a fully-connected converged mesh** — the single largest battery item, dwarfing the protocol traffic. And MTU is never negotiated, so Android↔Android links write in 20-byte chunks: a ~250 B idle digest costs ~13 GATT writes; one converged idle exchange-pair ≈ 50 writes.

One finding crosses from efficiency into correctness: the shipped COR3-21 fix (GSP2 rejection frame) is very likely delivered into an unsubscribed characteristic on real hardware — the rejected central never learns, and a live link permanently black-holes gossip at the capacity boundary (WIRE4-9).

Counts: **0 CRITICAL · 10 MAJOR · 16 MODERATE · 10 MINOR · 3 OBSERVATION**, after merging duplicates, re-grading on the ladder, and excluding items the roadmap already owns. Nothing here is unsound-broken-now (sync converges; the prior audit's algebra holds) — these are defects in the thing this library exists to be: a battery-friendly BLE sync engine.

---

## Baseline disposition (findings of prior audits touched by this one)

| Prior item | Status today | Notes |
|---|---|---|
| PERF3-1 (decode twice), PERF3-2 (encode once), PERF3-4 (buffer views), PERF3-5 (GATT re-resolution per chunk) | **Open, already tracked** (`backlog/engine-hot-path-performance.md`) | Re-confirmed present (`gossip_engine.dart:515,650,894`; `bluey_port_impl.dart:682-698` — CPU-only now that `cache: true` is used on the send path). Not re-counted. |
| COR3-21 / `engine-reject-notify-capped-peers` (☑ shipped) | **Fix shipped but its delivery mechanism is unreliable** | The GSP2 frame is sent at heartbeat-identification time, almost certainly before the remote central subscribes to notifications → **WIRE4-9**. The roadmap ☑ should gain a caveat. |
| OBS-3 (responder digest fitting never rotates), COR3-28 (`DeltaRequest.since` unbudgeted) | **Open, already tracked** (`backlog/health-minor-findings-sweep.md`) | Re-confirmed (`gossip_engine.dart:1085` passes `0`; `delta_request.dart` unbudgeted). Not re-counted. |
| OBS-5 (orphaned probe timeout timers), threshold-tuning scope note (send-failure fail-fast) | **Open, already tracked** (`backlog/engine-swim-threshold-tuning.md`) | This audit adds the radio-cost half of the send-failure item → **WIRE4-21**. |
| ADR-013 adaptive timing (shipped) | **Faithfully implemented — and the spec itself lacks an idle/active distinction** | The code matches ADR-013's bounds exactly; the inversion (faster link → more idle traffic) is a spec-level gap → WIRE4-2/4. |

---

## Empirical measurements

Method: temporary probe test over `TestNetwork` (in-memory bus, default `CoordinatorConfig`, simulated time), identity-transform link taps counting messages by type byte. Simulated-time quantization makes *rates* conservative; message *structure* and *sizes* are exact. Probe file deleted after the audit.

| Scenario | Measured |
|---|---|
| n=2, converged, idle, 60 s | 208 msgs / 19,930 B: DigestRequest+Response pairs (115 B each, short test IDs) continuously from **both** sides + Ping/Ack every ~5 s. Never quiet. |
| n=4, converged, idle, 30 s | Same per-node rate (204 msgs/30 s aggregate) — per-node cost is O(1) in n, as designed. |
| n=2, **zero channels**, idle, 60 s | 206 msgs — empty 28 B digest exchanges at the full round rate. The loop doesn't care that there is nothing to sync. |
| One 3-byte write (converged before) | 1 unsolicited 187 B DeltaResponse (the reactive push, ~150 ms after the write; no DeltaRequest observed — confirming push, not pull) + ongoing digest chatter. |
| Write, first 10 ms | 0 bytes — the push is debounced (150 ms), not absent. |

Real-world rates from the verified formulas (36-char UUID node IDs, C channels / S streams / A authors; `protocol_codec.dart:154-219`): a digest message ≈ `27 + |sender| + Σ[29+|ch| + Σ(28+|stream| + Σ(|author|+3+digits))]` bytes → **249 B** at C=1,S=1,A=2; **~2.0 KB** at the target ceiling C=1,S=5,A=8. A converged exchange is request + ≈equal response; both nodes initiate independently → **≈1 KB per interval per pair** at the 2-node shape. At the adaptive interval a healthy BLE link actually produces (SRTT 150 ms → 300 ms interval): **~3.3 KB/s per pair of pure no-news chatter** — a large fraction of the whole link budget; at the 5 s ceiling, ~200 B/s. SWIM adds ~66 B Ping + 66 B Ack per node per ~1.5 s (~87 B/s) — the digest chatter is 10-40× the liveness cost. On today's un-negotiated Android MTU (chunk = 20 B), that idle exchange-pair is **~50 GATT writes per interval**.

---

## Findings

### MAJOR

**WIRE4-1 — A converged network never goes quiet: rounds fire unconditionally, nothing remembers convergence, and both sides of a pair initiate independently.**
Evidence: `performGossipRound` has no news/convergence gate — only "no peers" and "all congested" skips (`gossip_engine.dart:586-612`); the loop self-reschedules forever (`:983-987`). No per-peer memory of exchange *outcome* exists: the only per-peer gossip state is `lastAntiEntropyMs`, used solely for selection ordering (`:623-634`). `updatePeerAntiEntropy` is called only by the initiator (`:610`); the responder path records nothing (verified: `PeerService.recordPeerAntiEntropy` at `peer_service.dart:151` has zero callers), so a peer that just fully reconciled us still looks maximally stale to our selector — at n=2 both nodes run a full exchange every interval, 4 messages where the push-pull design (`:798-827`) needs 2.
Consequence: the owner's ideal is unreachable at any setting; idle cost is permanent (~1 KB + ~4 radio transactions per pair per interval at the 2-node shape).
Fix direction: record the exchange on the responder path too (halves idle traffic at n=2 by itself); cache each peer's last-advertised vectors and demote no-change rounds to a low-rate safety-net cadence (see R3, and WIRE4-2 for the interval half).

**WIRE4-2 — The "adaptive" gossip interval adapts to latency, not news: a faster link produces more idle traffic, and the quietest reachable cadence is 5 s.**
Evidence: `effectiveGossipInterval = median SRTT × 2`, clamped [100 ms, 5 s] (`gossip_engine.dart:178-181, 312-340`); fallback 1000 ms (`:294-296`). No idleness input exists; `mergedBatchCount`/`outstandingPullCount` are exported for apps (`:366-378`) but never fed back into pacing. The class doc itself argues the periodic round is "the anti-entropy safety net" (`:304-308`) — yet it runs at hot-loop rates.
Consequence: healthy BLE (SRTT 150 ms) → 300 ms interval → ~3.3 no-news exchanges/s/node. Adaptation is inverted relative to the battery goal.
Fix direction: two-speed pacing (Trickle-style): keep `2×RTT` as the *active* cadence, back off multiplicatively toward a separate anti-entropy ceiling (30-60 s) after consecutive no-op exchanges, reset on any local append, merge, or membership change. The reactive push already covers latency. This is the single highest-leverage protocol change (field precedent: RFC 6206; memberlist push-pull 30 s; BT Mesh beacons 10→600 s).

**WIRE4-3 — SWIM probes are never suppressed by liveness evidence; `lastContactMs` is write-only.**
Evidence: probe selection filters on status + startup hold only (`failure_detector.dart:477-503`; `peer_registry.dart:130-136`). Gossip receipt already updates contact (`gossip_engine.dart:785` — "unambiguous proof of life") via `updatePeerContact` (`peer_registry.dart:263`), but **nothing in `lib/` reads `lastContactMs`** (verified by exhaustive grep).
Consequence: on a converged network where gossip round-trips every 0.3-5 s, essentially 100 % of steady-state probe traffic (~72 msgs ≈ 4.75 KB/min/node at the healthy-link floor) buys zero information.
Fix direction: in `selectRandomPeer`, skip peers whose `lastContactMs` is within one `effectiveProbeInterval` (advance the round-robin cursor); if all candidates are fresh, send nothing this round. Canonical SWIM's own suppression rule; no comparable implementation surveyed does this, but the evidence (authenticated inbound frame) is strictly stronger than an ack.

**WIRE4-4 — The SWIM probe interval floor-pins at 1.5 s on healthy links and backs off only when the link is nearly dead.**
Evidence: `effectiveProbeInterval = effectivePingTimeout × 3`, clamped [500 ms, 30 s] (`failure_detector.dart:140-144, 260-266`); ping timeout `SRTT + 4·RTTVAR` floored at 500 ms (`rtt_estimate.dart:141-147`). Healthy BLE: 230 ms → floor 500 ms → interval 1.5 s, permanently. The 30 s ceiling is reachable only at SRTT+4·VAR ≥ 10 s.
Consequence: inverted adaptation, same as WIRE4-2, on the second of two independent hot timer loops.
Fix direction: quiescence-keyed multiplicative backoff (×1.5 per all-healthy round, cap 30 s, snap back on failure/membership change); decouple the probe-interval floor from the ping-timeout floor.

**WIRE4-5 — The converged `DigestResponse` echoes version vectors the requester provably already has.**
Evidence: `handleDigestRequest` includes the responder's vector for every requested (channel, stream) pair — the requester's own `streamDigest.version`, in hand in the loop, is used only as a selector, never as a dominance filter (`gossip_engine.dart:1054-1087`).
Consequence: in idle exchanges the entire response payload (≈half the idle bytes) is derivable by the receiver.
Fix direction: skip pairs where `streamDigest.version.dominates(ourVersion)` — safe because the responder-behind direction is handled by the responder's own reciprocal pull (`:823-826`), and the initiator pulls only when the response shows the responder ahead (`:1279`). A converged response becomes ~63 B.

**WIRE4-6 — The reactive push fans out to every reachable peer, unscoped by channel and exempt from the congestion gate.**
Evidence: `_flushPendingPushes` sends to all `reachablePeers` (`gossip_engine.dart:499-520`); receivers routinely discard non-shared channels — the code says so (`:1452-1466`). The `pendingSendCount` filter used by the periodic round (`:591-596`) is absent here.
Consequence: every write is transmitted to peers guaranteed to drop it (multi-channel deployments pay per disjoint channel), with payloads up to 30 KB (~10 s of BLE airtime each), even into congested queues.
Fix direction: cache which channels each peer advertised (the engine sees this at `:811-822` and discards it) and scope pushes to those peers; apply the congestion filter. Consistent with ADR-007.

**WIRE4-7 — The BLE scan and advertising run at maximum rate and power forever, even on a fully-connected converged mesh.**
Evidence: scan started with no timeout and never stopped except by the facade's explicit `stopDiscovery()`/`dispose()` (`bluey_port_impl.dart:743-744`; sole stop caller `bluey_transport.dart:301`); bluey hardcodes `SCAN_MODE_LOW_LATENCY` (bluey `Scanner.kt:70`) and iOS `allowDuplicates: true` (`CentralManagerImpl.swift:156`). Advertising passes no mode (`bluey_port_impl.dart:414-418`) → bluey defaults to `ADVERTISE_MODE_LOW_LATENCY` + `ADVERTISE_TX_POWER_HIGH` (`Advertiser.kt:68,73`). `AutoConnectPolicy`'s at-cap early-return (`auto_connect_policy.dart:184-187`) never signals discovery to stop.
Consequence: 100 % RX duty plus ~1,800 TX PDUs/min at max power, indefinitely — on Android, LOW_LATENCY scanning alone is commonly measured at 10-15 % of a phone battery per hour. This dominates every protocol cost in this report by an order of magnitude and is entirely independent of gossip traffic.
Fix direction: duty-cycle on convergence — stop (or window, e.g. 5 s/55 s) the scan when `connectionCount ≥ targetConnections`, restart on `PeerClosed`; pass `mode: balanced`/`lowPower` to `startAdvertising` (bluey exposes it; scan mode needs a small bluey API addition) and expose both as `BlueyTransport` parameters.

**WIRE4-8 — MTU is never negotiated: Android↔Android links write in 20-byte chunks (~11× write amplification).**
Evidence: `requestMtu` appears nowhere in gossip_bluey (verified grep); bluey exposes it but its Android side keeps `negotiatedMtu[deviceId] ?: 23` (bluey `ConnectionManager.kt:42,538-539,678`) unless asked. `_defaultChunkSize = 20` (`bluey_port_impl.dart:174`); `maxWritePayload` is read (`:555-559`) without ever requesting more. iOS fallback is a conservative 100 B (`:199`, TODO(I325)).
Consequence: a ~250 B idle digest = 13 GATT writes; a 200 B response = 11 writes, 72 % overhead bytes, 11 radio wakeups where 1 suffices. Everything the core sends is amplified ~11×.
Fix direction: call `requestMtu(247)` (or 517) once in `_registerCentralConnection` before reading `maxWritePayload`; ignore failure. One ATT exchange per connection, amortized over the link's lifetime. Highest-leverage transport change.

**WIRE4-9 — The GSP2 capacity-rejection frame races the remote's notification subscribe; a rejected central likely never learns, leaving a live link that black-holes gossip forever.**
Evidence: the rejection notification is sent from the `PortPeerConnected` handler (`connection_manager.dart:264-284`), which fires off bluey's **first lifecycle heartbeat — sent immediately on connect** (bluey `lifecycle_client.dart:277`, verified). The remote central subscribes to the data characteristic only *after* its own service discovery completes (`bluey_port_impl.dart:567` then `:584`), hundreds of ms later. A notification into an unsubscribed characteristic is lost without error, so the "best-effort single shot" comment's failure assumption doesn't hold. The local side then marks the peripheral link rejected and discards all subsequent data from it (`connection_manager.dart:339-343`).
Consequence: at the capacity boundary, the rejected peer keeps a live BLE connection and keeps sending gossip (and SWIM probes) into a void — 100 % discarded, unbounded duration, plus bluey's ~12 heartbeats/min on the link. This also undermines the shipped COR3-21 remediation: in-memory tests deliver the frame; real hardware likely won't. Not previously documented (spec checked).
Fix direction: defer/retry the rejection until the remote's subscribe is observable (bluey CCCD surfacing), or re-send bounded times while a rejected link keeps receiving writes; independently reconsider refusing-to-advertise at cap versus accept-then-reject.

**WIRE4-10 — A single failed or timed-out chunk tears down the whole link with no retry.**
Evidence: any chunk error → `SendFailedError` → `_disconnectRoleGuarded` → rethrow (`connection_manager.dart:511-529`).
Consequence: one transient 20 B write failure (11 chances per message at today's chunk size) costs a full reconnect: GATT connect + two service discoveries (see WIRE4-23) + subscribe + heartbeat — 30-60 ATT PDUs to replace one lost write. Compounds with WIRE4-8; on flaky links this converts write noise into reconnect churn.
Fix direction: retry a transient chunk failure 1-2 times (the single-drain-loop already guarantees ordering); reserve teardown for timeouts/replaced handles.

### MODERATE

**WIRE4-11 — Every `DigestRequest` advertises every local channel to every peer, every round.** `_buildDigestRequest` iterates all channels (`gossip_engine.dart:643-649`); the recipient filters non-shared ones per round (`:811-822`) and nothing caches the result. Idle digest cost scales with total channel count, not shared count. Fix: the same per-peer channel cache as WIRE4-6.

**WIRE4-12 — No batching on the delta path: N streams catching up = N `DeltaRequest` + N `DeltaResponse` messages.** Wire format carries exactly one (channel, stream) per message (`protocol_codec.dart:168-189`); `_sendDeltaRequests` loops one send per request (`gossip_engine.dart:1166-1178`). On BLE, message count ≈ cost. Fix: batched list forms + a same-tick outbound coalescer keyed by recipient.

**WIRE4-13 — Push-pull is half-implemented: the digest reply never carries entries the request provably asked for.** The `DigestRequest` contains the initiator's full vectors; the responder could attach deltas immediately (`computeDelta` exists, `gossip_engine.dart:1037-1043`) but only describes its state (`:960-968`), forcing a second round trip. Common catch-up case: 4 messages/2 RTT where 2/1 suffice. Mitigated by the reactive push covering the fresh-write case. Fix: attach budget-fitted deltas for streams where the requester is behind.

**WIRE4-14 — The wire encoding is ~1.6-1.8× larger than necessary; digests repeat 36-char UUIDs per author per stream per round.** JSON text (`protocol_codec.dart:131`), version-vector keys are full node IDs (`:217-219`); at C=1,S=5,A=8 a digest is ~2.0 KB of which ~1.5 KB is repeated UUID text — 2-3× past the codec's own documented size envelope (`values/channel_digest.dart:20`). Fix: per-message author-index table (~60 % digest reduction, format-local); varint/binary later if needed.

**WIRE4-15 — The only knob that quiets the radio also disables adaptivity entirely.** A static `gossipInterval` short-circuits the adaptive path wholesale (`gossip_engine.dart:313-316`); the repo's own example reaches for it (`examples/gossip_chat/.../gossip_config_service.dart:18`, 2 s). Fix: expose `min/maxGossipInterval` bounds that keep adaptation between them. (Subsumed by R3's two-tier design.)

**WIRE4-16 — Unreachable-peer recovery never backs off and drags 3 other radios with it every attempt.** Every 5th round, forever (`failure_detector.dart:330-336`); a dead peer always fails direct → the 3-way PingReq fan-out always fires (`:437-441`). ~606 B and 7 radio transmissions per attempt per prober; at n=8 with one departed peer ≈ 28 KB/min cluster-wide until `removePeer`. ADR-004's "~9 B/s, negligible" understates by ~9× (`adr/004:108-113`). Mitigated on bluey (closed connections remove peers); bites on half-open links. Fix: exponential backoff per unreachable peer; direct-only (or 1-in-N indirect) recovery probes; correct ADR-004.

**WIRE4-17 — PingReq fan-out is hard-coded k=3 — half the cluster at n≤8.** `_selectRandomIntermediaries(target, 3)` (`failure_detector.dart:678`). SWIM's k=3 is calibrated for clusters of hundreds. Fix: scale k with n (1 at n≤4, 2 at n≤7) and/or sequential-with-early-exit.

**WIRE4-18 — No leave/goodbye message: a clean shutdown costs the cluster the full detection storm.** `stop()` flips flags only (`failure_detector.dart:281-285`). Each remaining node pays 15 failed probes with fan-out (~9 KB/node) then perpetual recovery probing (WIRE4-16). Mitigated where the transport reports the disconnect and the app removes the peer (bluey does); the most predictable transition still costs the most. Fix: a 1-byte leave to reachable peers on stop; receivers jump straight to the backed-off recovery schedule.

**WIRE4-19 — Nothing is piggybacked across the two control planes; two independent hot timers each wake the radio.** Ping/Ack carry sender+sequence only (`protocol_codec.dart:136-142`); the gossip and SWIM loops are fully independent. SWIM's defining optimization (dissemination piggybacked on probes) and memberlist's compound messages both do the opposite. Fix: piggyback the digest (or a digest hash) on Ack, and/or count a gossip exchange as this period's probe (with WIRE4-3).

**WIRE4-20 — Backpressure is honored on one send path out of six.** Only `performGossipRound` consults `pendingSendCount` (`gossip_engine.dart:591-596`); `syncWithPeer`, pushes, delta requests, and both response sends ignore it, so under congestion the engine throttles exactly the one path a timer already limits. Fix: apply the per-peer gate (or a byte-budget variant) to pushes and request bursts; responses may deserve exemption (serving is cheap for the requester's progress).

**WIRE4-21 — A send the transport reports as failed is swallowed; the detector still waits the full timeout and still fans out.** `_safeSend` catches and proceeds (`failure_detector.dart:926-945`) although the port contract makes the throw actionable (`message_port.dart:98-104`) and the gossip engine uses it (`gossip_engine.dart:893-911`). Detection-latency half already tracked (threshold-tuning scope note); the radio half (fan-out to 3 intermediaries for a peer the local transport already knows is unroutable) is new. Fix: `_safeSend` returns bool; short-circuit the direct phase on known failure.

**WIRE4-22 — Every `addPeer` fires up to 3 pings + a full digest exchange with no dedup or congestion check; flapping links amplify it.** `_probeNewPeerWithRetry` (3 attempts, no delay/no contact re-check) + immediate `syncWithPeer` (`coordinator.dart:675-712`; `gossip_engine.dart:743-758`); `probeNewPeer` has no in-flight guard (`failure_detector.dart:372-398`). Correct on genuine joins; per-flap cost on reconnect churn. Fix: per-peer in-flight guard; skip `syncWithPeer` if `lastAntiEntropyMs` is within one interval; short-circuit retries once contact/RTT lands.

**WIRE4-23 — A redundant second GATT service discovery runs on every connection.** `peerConnection.services()` at `bluey_port_impl.dart:567` defaults `cache: false`, re-issuing full discovery although `connectAsPeer` just populated the cache; the send path gets it right (`:688`, `cache: true`). ~10-30 ATT PDUs + hundreds of ms per connect, including every WIRE4-10 reconnect. Fix: `services(cache: true)` — one word.

**WIRE4-24 — Writes from not-yet-identified clients are silently dropped while the sender records success.** Pre-heartbeat writes are discarded unlogged (`bluey_port_impl.dart:390-396`; mirror at `connection_manager.dart:339-343`); the sender's chunks "succeeded" (write-without-response), metrics count them as delivered. Recovery rides on anti-entropy; the waste is invisible to diagnostics. Fix: log + counter at minimum; better, buffer a small bounded window per client address and replay on identification.

**WIRE4-25 — No transport coalescing: every message pays its own 8-byte frame header and partial-PDU tail.** `_drainQueue` sends one message at a time (`connection_manager.dart:443-469`); no path merges queued sends into one GATT write. Strictly downstream of WIRE4-8 (at 20 B chunks there is nothing to coalesce into). Fix (after WIRE4-8): drain the normal lane into one buffer up to `chunkSizeFor`, preserving the high lane's jump and per-peer ordering.

**WIRE4-26 — Auto-connect redials a present-but-always-failing peer every 60 s forever.** `maxBackoff` 60 s (`auto_connect_policy.dart:35,285-296`); each attempt is a full connect + discovery + timeout. A *non-bluey* device gets the gentler 10 min (`longBackoff`). Bounded maps TODO already noted at `:91-95`. Fix: promote to `longBackoff` after N consecutive failures; add jitter.

### MINOR

**WIRE4-27 — The push debounce is a transport-blind 150 ms constant** (`gossip_engine.dart:228`); on 300-500 ms-RTT links it coalesces almost nothing. Fix: scale with median SRTT, clamped.
**WIRE4-28 — `adaptiveTimingEnabled: false` is chattier than leaving it on**: static fallback 500 ms (`gossip_engine.dart:270-271`) vs adaptive fallback 1000 ms (`:294-296`). Align the defaults.
**WIRE4-29 — `adaptiveTimingEnabled` never reaches the FailureDetector** (constructor `failure_detector.dart:115-134` lacks it; wired only into GossipEngine). Mirror the gossip-engine handling.
**WIRE4-30 — Four version-vector storage reads per stream per idle round** (`gossip_engine.dart:1011,1071-1074,1243`); with a persistent `EntryRepository` that's 4 async I/O round-trips to re-derive an unchanged value. Pass computed vectors through.
**WIRE4-31 — An oversized reactive push is dropped silently** (`gossip_engine.dart:515` `continue` with no `ErrorCallback`), violating the project's no-silent-errors rule; the sibling digest path emits (`:708-719`). Emit a `ChannelSyncError`.
**WIRE4-32 — Up to one probe round's sends escape after `stop()`** — no generation check on the send path (`failure_detector.dart:906-920`, `_handlePingReq`). Bounded (≤342 B); still traffic after the app asked for silence. Gate sends on generation.
**WIRE4-33 — Acks and PingReq relays are served unconditionally to unknown senders** (`failure_detector.dart:746-753, 762-798`) — uncapped reflected transmissions under someone else's control. Drop or rate-limit non-registry senders.
**WIRE4-34 — Documentation drift bundle:** "every 200 ms" in `gossip_engine.dart:37,573`, `time_port.dart:21`, ADR-008:76 (actual: 0.1-5 s adaptive, 1 s fallback); ADR-004's incarnation section describes unimplemented behavior (code says so, `failure_detector.dart:561-563`) and its unreachable-probe bandwidth is ~9× understated; digest docstring size envelopes (`stream_digest.dart:17-18`) exceeded ~2-3× at target scale. Fold into `health-minor-findings-sweep`.
**WIRE4-35 — `chunkSizeFor` clamps upward to 20**, silently cancelling the `_safetyMargin` at the default MTU and masking sub-minimum reports (`bluey_port_impl.dart:654-655`). Guard + log instead.
**WIRE4-36 — Every advertisement rebuilds an unmodifiable snapshot and walks the policy** (`discovery_service.dart:102-108`): ~40 rebuilds/s at 4 peers under LOW_LATENCY, forever concluding "already connected". CPU-only; largely moot once WIRE4-7 lands. Rate-limit snapshots.

### OBSERVATION

**WIRE4-37 — Serial `await` in push fan-out and delta bursts** (`gossip_engine.dart:516-518, 1170-1176`) is a latency hazard only if a transport completes `send()` on transmit; the contract forbids blocking (`message_port.dart:97`) and gossip_bluey completes on hand-off. Tighten the contract wording or `Future.wait`.
**WIRE4-38 — Indirect-phase RTT samples (2-hop + queueing of 3 sends) feed the global tracker** that drives the probe interval (`failure_detector.dart:830` unconditional vs `:835-837` per-peer filter). Error direction is battery-favourable; still skews degraded rounds. Record direct-path samples only.
**WIRE4-39 — `PeerService.recordMessageReceived/Sent` would put a disk write on every ping if ever wired in** (`peer_service.dart:165-187`); the detector deliberately bypasses them and nothing calls them. Document the constraint or delete them.

---

## What is genuinely healthy (verified strengths — protect these)

1. **The event tier exists and is correctly shaped:** reactive push on local append, debounced 150 ms, coalesced per (channel, stream), suppressed when stopped (`gossip_engine.dart:463-520`); **merged entries are never re-pushed** (`coordinator.dart:409-420` — sole `notifyLocalWrite` call site, verified), so there is no O(n²) relay flood.
2. **A converged exchange terminates at step 2** — dominance check `gossip_engine.dart:1279`; measured: zero delta traffic when in sync; pending flags released, not leaked.
3. **Periodic fan-out is exactly 1 peer per round** (`:607-611`), with least-recently-synced selection + random tiebreak (`:623-634`) bounding coverage to ~(n-1) rounds; ±20 % jitter decorrelates nodes (`:406-408`); generation tokens prevent forked loops doubling traffic across pause/resume (`:148-154,388-428`).
4. **Digests are properly batched** (channels→streams in one message) and carry vectors only, never entries; oversized digests rotate through a byte budget so every stream is covered (`:643-735`); `hasMore` continuation drains backlogs at link speed with a no-progress guard (`:866-871,1591-1604`).
5. **Duplicate-pull suppression with an RFC-6298 timeout measured from real delta round-trips** — the right signal for 30 KB pages on BLE (`:199-219,344-357,1224-1241`).
6. **SWIM is O(1) per node in n, never broadcasts, one-hop indirect only; late Acks are honored instead of retried; failures self-throttle (self-clocked loop); high-priority lane keeps pings ahead of bulk transfers** (`failure_detector.dart:328-362,643,653-668,872-881,932`).
7. **The BLE transport invents no traffic:** zero timers/keepalives/polling in the package (verified exhaustive grep); one 10-byte control frame total; no version-negotiation handshake; write-without-response/notify on the data path (no per-chunk ATT acks); per-peer two-lane queues with contiguous frames; auto-connect is purely reactive (absent peers cost nothing) with dedup, in-flight caps, and typed rejection backoff; the mutual-connect tie-break costs zero wire messages; `dispose()`/adapter-off leave nothing scanning or advertising.
8. **Failed sends complete with an error, never silently as success** (`connection_manager.dart:452-459`), matching the `MessagePort` contract so the core rolls back instead of timing out (WIRE4-24 is the one leak).

---

## Where the design sits relative to the field

Surveyed: Demers et al. 1987, Trickle (RFC 6206; RPL/Contiki/Thread parameters), Cassandra, HashiCorp memberlist/Serf, van Renesse Scuttlebutt flow-control, Secure Scuttlebutt EBT, SWIM + Lifeguard, Bluetooth Mesh secure-network beacons, BitChat, Ditto, Bitcoin Erlay, Automerge sync. Full entries with URLs in the research appendix of the audit workpapers; the durable conclusions:

- **Two-tier scheduling is universal.** Every surveyed system separates an event-driven dissemination tier from a periodic repair tier running **1-3 orders of magnitude slower** (memberlist: 200 ms gossip vs 30 s push-pull; Erlay: 1 s flood vs 16 s sketch; BitChat: live relay vs 15 s filter exchange; Demers: immediate mail vs *nightly* anti-entropy). This library has the event tier; its repair tier runs at 0.1-5 s — one to three orders hotter than field practice.
- **Idle suppression is standard:** memberlist's `gossip()` returns without sending when its broadcast queue is empty; Automerge's `generate_sync_message` returns `None` at convergence; Trickle doubles its interval every consistent round (Imax 32 s-2.3 h in deployed stacks) and resets on news; Bluetooth Mesh nodes back their beacons off 10 s→600 s based on how many they hear. Nothing in this library suppresses anything when converged.
- **Piggybacking is SWIM's own headline feature** (membership on ping/ack; memberlist compounds broadcasts onto probe packets). This implementation runs two fully independent hot timers with disjoint payloads.
- **Hash-first convergence checks** (Demers checksums, Merkle roots, Erlay sketches, Automerge heads) make the safety-net exchange O(1) when nothing changed; this library re-sends full vector sets every round.
- **Notable:** no surveyed gossip implementation suppresses probes on recent *application* traffic (WIRE4-3's fix would be ahead of the field, not behind it), and this transport's zero-self-traffic discipline is genuinely better than typical BLE middleware.

Verdict relative to the field: the reconciliation *algebra* is at or above the field standard; the *scheduling* is roughly where pre-Trickle (2004) constrained-network gossip was — correct, latency-tuned, and unable to be quiet.

---

## Adjusted / discarded claims (the verification pass, made visible)

- **Orchestrator's own interim claim corrected:** the mid-audit statement "the claimed reactive push looks absent" was **wrong** — the empirical probe's 10 ms window was shorter than the 150 ms debounce; the push exists and was observed (unsolicited DeltaResponse, no DeltaRequest) in the wider window. ADR-008's reactive-push claim is TRUE.
- **Two agent CRITICALs re-graded MAJOR** (engine never-quiet finding; bluey scan/advertise and MTU findings): on this repo's severity ladder CRITICAL means unsound/broken now; sync converges and data is safe — these are defects in the deployment goal, graded MAJOR and ranked first. WIRE4-9 stays MAJOR (not CRITICAL) because it requires the at-capacity boundary and in-range recovery paths exist (link drop/reconnect).
- **Downgrades:** full-digest-to-all-peers (MAJOR→MODERATE — bites only multi-channel deployments); push-pull-half (MAJOR→MODERATE — the reactive push covers the common case); no-delta-batching (MAJOR→MODERATE — catch-up path, zero idle cost); unreachable-probing and no-leave (MAJOR→MODERATE — bluey's disconnect→removePeer path bounds reachability to half-open links); static-fallback mismatch and serial-await (downgraded — contract-dependent or config-edge).
- **Merged:** FailureDetector `probeNewPeer` redundancy + Coordinator `addPeer` sync burst → WIRE4-22 (same event, one fix).
- **Excluded as already owned by the roadmap:** encode-once-send-many (PERF3-2), decode-twice (PERF3-1), GATT re-resolution per chunk (PERF3-5 — and the send path already uses `cache: true`, so it is CPU-only), frame-codec buffer copies (PERF3-4-adjacent), orphaned probe timers (OBS-5), responder digest rotation (OBS-3), `DeltaRequest.since` budget (COR3-28), BLE queue depth cap and frame multiplexing (their own backlog items).
- **Fabrications: none.** Every citation spot-checked (≈70 across four reports, including the bluey pub-cache sources) existed and said what the reporting agent claimed. One agent grep (`recordPeerAntiEntropy` callers) was re-run by the orchestrator to first-hand-confirm a "never invoked" claim.
- **Unverifiable-statically, stated as likelihood not fact:** WIRE4-9's "notification into an unsubscribed characteristic is lost without error" is platform behavior; the race ordering itself (heartbeat-immediate vs discovery-then-subscribe) is verified in source. Real-hardware confirmation is part of the fix work.

---

## Recommendations

| # | What | Findings | Effort |
|---|---|---|---|
| R1 | Negotiate MTU once per connection (`requestMtu(247)` + re-read `maxWritePayload`); raise the iOS fallback | WIRE4-8, enables -25 | XS |
| R2 | Duty-cycle scan + advertising on convergence; expose advertise mode; window the scan at cap | WIRE4-7, moots -36 | S (needs a small bluey API addition for scan mode) |
| R3 | Two-tier gossip pacing: responder records exchanges; per-peer convergence memory; Trickle-style backoff to a 30-60 s safety net with reset-on-news; dominance-filter the DigestResponse; split the interval knob into bounds | WIRE4-1, -2, -5, -15 | M — the core design change of this audit |
| R4 | SWIM quiet: skip probes to recently-heard peers; quiescence backoff; decouple floors; wire `adaptiveTimingEnabled` through | WIRE4-3, -4, -29 | S-M |
| R5 | Capacity-boundary correctness: fix GSP2 delivery race; chunk retry before teardown; `services(cache: true)` | WIRE4-9, -10, -23 | S |
| R6 | Scope reactive push to sharing peers + congestion gate; per-peer channel cache also trims digests | WIRE4-6, -11, -20 | S-M |
| R7 | Coalescing tier: transport-level Nagle (after R1), batched delta forms, push-pull completion, SRTT-scaled debounce | WIRE4-25, -12, -13, -27 | M-L |
| R8 | Wire-format diet: author-index table for version vectors | WIRE4-14 | M (format change, both ends) |
| R9 | Small-fixes + docs sweep: WIRE4-16..19, -21, -22, -24, -26, -28, -30..36; fold -34 into `health-minor-findings-sweep` | — | S each |

**Suggested order: R1 → R2 → R5 → R3 → R4 → R6 → R7 → R8 → R9.** R1 and R2 are the two biggest battery levers and are nearly free; R5 closes the one correctness hole; R3/R4 are the design work that actually delivers the owner's "quiet when balanced" ideal; R7/R8 only pay off once R1/R3 exist.

---

## Coverage

- **Core engine territory** (read in full by its agent; orchestrator re-read `gossip_engine.dart` and `protocol_codec.dart` in full, plus targeted `coordinator.dart`, `channel_service.dart`, message/value classes, time ports): all send triggers enumerated; none found outside the inventory.
- **SWIM territory** (agent full read; orchestrator re-read `failure_detector.dart` in full, plus `peer_registry.dart`, `peer_service.dart`, `rtt_estimate.dart` excerpts and exhaustive greps for `lastContactMs`/`recordPeerAntiEntropy`).
- **gossip_bluey**: all 29 lib files (3,629 lines) read in full by its agent; orchestrator re-verified every MAJOR and the cited lines of every MODERATE/MINOR, including the bluey dependency sources in the pub cache (Scanner.kt, Advertiser.kt, ConnectionManager.kt, lifecycle_client.dart, CentralManagerImpl.swift).
- **Gates:** `dart test` (gossip) 972 passed; `flutter test` (gossip_bluey) 200 passed — run by the orchestrator on this branch (`working-connection`, clean tree).
- **Empirical probe:** temporary `test/idle_traffic_probe_test.dart` (link-tap counters), run under simulated time, deleted after the audit; raw numbers reproduced in the Measurements section.
- **Not covered:** `packages/gossip_nearby` (excluded by scope — audit it before any Nearby deployment; its per-peer-queue gap is already `engine-nearby-per-peer-queues`); the `bluey` library itself beyond the send/scan/advertise/MTU/lifecycle surfaces gossip_bluey exercises; examples read only as config evidence; real-hardware measurements (all rates here are derived from verified formulas or simulated time — a field measurement pass would strengthen WIRE4-7/8 numbers and is recommended as part of R1/R2 acceptance).
