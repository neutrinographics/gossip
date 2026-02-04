# Adaptive Timing: Evaluation & Improvement Plan

Post-implementation evaluation of ADR-013 (Adaptive Timing) based on 6-device BLE testing.

## Before vs After Comparison

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| Max failed probe count (single line) | 15 | 2 | 87% reduction |
| Suspected peer events | 10 | 0 | Eliminated |
| "Cannot send" warnings | 97 | 34 | 65% reduction |
| Message gaps > 5s | 6 (max 32.4s) | 7 (max 23.9s) | Similar count, worst gap improved |
| Disconnections | 12 | 6 | 50% reduction |
| Warnings total | 107 | 56 | 48% reduction |
| Avg final reachable peers | 2.17 | 2.83 | +30% improvement |
| Devices with 0 reachable peers | 1 | 0 | Eliminated |
| Total messages sent | 5,008 | 3,302 | 34% less (adaptive throttling) |
| Send/receive delta | 483 (9.6% loss) | 153 (4.6% loss) | Message loss halved |

### Key Wins

- **Failure detection works correctly on BLE.** Max failed probe count dropped from 15 to 2, zero peers suspected.
- **Transport congestion reduced.** Backpressure-aware throttling and adaptive intervals prevent overwhelming BLE.
- **No isolated devices.** Before, Pixel 4a ended with 0 reachable peers. After, every device sees at least 2.
- **More efficient.** 34% fewer messages while maintaining better connectivity.

### What Didn't Improve

Message gaps > 5s are still present (7 after vs 6 before), with I2505 (vivo) showing a 23.9s gap. These appear to be OS/transport-level (Android Nearby Connections BLE scheduling, device power management) rather than protocol-level.

---

## Improvement Plan

### 1. Observability Logging for Adaptive Timing

**Priority:** Do first. Every subsequent item depends on being able to see what's happening.

**Problem:** The after logs show zero RTT, backpressure, or adaptive timing entries despite all these systems being active. The `Skipping gossip round: transport congested` log exists in code but never appeared, and it's unclear whether backpressure was never triggered or never logged.

**What to log:**
- **Effective intervals in METRICS dump:** Current `effectivePingTimeout`, `effectiveProbeInterval`, `effectiveGossipInterval`, smoothed RTT, and RTT variance. This is the single most valuable addition.
- **Backpressure state in METRICS dump:** Current `totalPendingSendCount` and per-peer pending counts.
- **Gossip round skips (DEBUG):** Already exists in code, verify it fires.

**Effort:** Small. A few log lines added to the periodic metrics output. No architectural changes.

---

### 2. Per-Peer Backpressure in Gossip Peer Selection

**Priority:** High impact, moderate effort.

**Problem:** The current congestion check is all-or-nothing: if `totalPendingSendCount > 10`, the entire gossip round is skipped. A single congested link (e.g., to the vivo I2505) can starve gossip to all other healthy peers. In the after logs, I2219 had 14 "Cannot send" warnings mostly targeting I2505 -- with per-peer filtering it would have continued syncing with its other 4 peers.

**Current state:** The `pendingSendCount(NodeId)` per-peer API already exists on `MessagePort` and is implemented in `ConnectionService`. It's just not used during peer selection.

**What to change in `GossipEngine.performGossipRound()`:**
1. Get the list of reachable peers.
2. Filter out peers where `messagePort.pendingSendCount(peer) > perPeerThreshold` (e.g., 3).
3. Select randomly from the remaining uncongested peers.
4. Only skip the round entirely if ALL peers are congested.

**Effort:** Moderate. Changes to `performGossipRound()` in `gossip_engine.dart`, plus tests.

---

### 3. Reconnection After Disconnection

**Priority:** Highest long-term impact, largest effort.

**Problem:** The after logs show 6 disconnections with 0 reconnections. Pixel 4a lost 3 of its 5 connections and ended with only 2 reachable peers. Once a BLE link drops, it's gone permanently.

**Current architecture (by design per ADR-006):**
1. Nearby Connections fires `onDisconnected`.
2. `ConnectionService` emits `ConnectionClosed`.
3. `NearbyTransport` emits `PeerDisconnected`.
4. App calls `coordinator.removePeer()` -- peer is gone forever.

Discovery continues running (advertising + scanning are always active), and a re-appearing peer with a new `EndpointId` will be re-discovered and re-handshaked. The gap is that `coordinator.addPeer()` isn't called again automatically.

**What to change (in `gossip_nearby`, respecting ADR-006):**
1. Maintain a set of "known NodeIds" from previous connections in `ConnectionService` or `NearbyTransport`.
2. When a new `EndpointDiscovered` → handshake reveals a previously-known NodeId, automatically emit `PeerConnected` so the app re-adds the peer.
3. Add exponential backoff for reconnection attempts to avoid flapping.

**Effort:** Large. Requires state tracking, reconnection policy, flap detection, and extensive testing. But it's the biggest remaining gap -- a BLE mesh that can't recover from transient disconnections will degrade over any non-trivial session.

---

### 4. Per-Peer RTT Tracking

**Priority:** Medium impact, moderate effort.

**Problem:** The global RTT tracker averages measurements across all peers. If 4 peers have 200ms RTT and 1 peer (vivo I2505) has 2000ms RTT, the global SRTT settles around ~400-500ms. Timeouts become too generous for fast peers and too tight for the slow one.

**Current state:** RTT is measured per-ping in `FailureDetector.handleAck()` (the sender NodeId is known), but the sample is recorded into the global `RttTracker`, losing peer identity. The `Peer` entity already supports `copyWith()` and per-peer `PeerMetrics`.

**What to change:**
1. Add an `RttEstimate` field to `Peer` (or `PeerMetrics`).
2. In `handleAck()`, record the sample both globally and on the specific peer.
3. Add `getEffectivePingTimeout(NodeId)` that uses per-peer RTT when available, falling back to global.
4. Use per-peer timeouts when probing specific peers.
5. Optionally: let `GossipEngine` prefer lower-RTT peers for faster sync convergence.

**Effort:** Moderate. Data structures are ready, the measurement point exists, and `copyWith()` makes updates clean. Main complexity is the fallback to global RTT during early session before per-peer samples exist.

---

### 5. Lower Initial Conservative Timeouts

**Priority:** Small, quick win.

**Problem:** Initial SRTT=1000ms and variance=500ms yield a 3s ping timeout, 9s probe interval, and 2s gossip interval before any RTT samples arrive. The first probe doesn't fire until T+9s, so the first RTT sample arrives at ~T+9.3s. For the first 9 seconds, the system runs on guesses.

**What to change (two options):**
- **Option A (one-line change):** Lower initial SRTT to 500ms. Yields 1.5s timeout, 4.5s probe interval, 1s gossip interval. Still conservative but halves the cold-start penalty.
- **Option B (better, more work):** Send an immediate "discovery ping" on peer connection (before the first scheduled probe round) to seed the RTT tracker with a real measurement. Collapses the convergence window from 9s to <1s.

**EWMA convergence reference:** With alpha=0.125 and BLE RTT ~300ms, SRTT converges in 1 sample (RFC 6298 first-sample rule sets SRTT directly). Variance stabilizes within 5-10 samples. The bottleneck is getting that first sample, not the EWMA math.

---

### 6. Suspicion Threshold Verification

**Priority:** Low. Research/testing task.

**Problem:** The threshold of 5 combined with adaptive timeouts eliminated false suspicions entirely. Verify it still detects actual failures promptly.

**Back-of-envelope:** With stabilized BLE RTT ~300ms, effective ping timeout ~460ms, probe interval ~1.4s. Time to mark a dead peer as suspected: `5 * 1.4s = 7 seconds`. This is reasonable for BLE. But if a slow peer inflates global RTT (before per-peer RTT), detection time could be much higher. Worth a targeted test.

---

## Summary

| # | Recommendation | Effort | Impact |
|---|---------------|--------|--------|
| 1 | Observability logging | Small | Enables everything else |
| 2 | Per-peer backpressure in gossip | Moderate | Prevents slow peers blocking fast ones |
| 3 | Reconnection after disconnect | Large | Fixes permanent mesh degradation |
| 4 | Per-peer RTT tracking | Moderate | More accurate timeouts per device |
| 5 | Lower initial timeouts | Small | Faster cold-start convergence |
| 6 | Suspicion threshold verification | Small | Confidence check |
