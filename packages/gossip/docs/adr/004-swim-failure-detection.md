# ADR-004: Probe-Based Failure Detection

## Status

Accepted 2026-03; **amended 2026-09-18** — indirect (relayed) probing
retired. History below.

## Context

In a distributed system, nodes need to detect when peers become unreachable:
- to avoid wasted sync attempts to dead nodes,
- to keep peer status accurate for the application,
- to steer gossip partner selection.

The library targets small networks (up to 8 devices) with potentially
unreliable connections (mobile, P2P). Under ADR-007 membership is local
metadata: no node ever tells another who it thinks is alive.

## Decision

**Detect failures with direct probes, graded status, and slow recovery
probing.** Each round the detector pings one peer and waits a per-peer
RTT-adaptive timeout; if that expires it holds the ping open for one more
timeout — the grace window (ADR-012) — and counts a failure only if the
window closes empty.

```
Probe:
  A ──ping──> B
  A <──ack─── B            (before the timeout: reachable)
  A <──ack─── B            (inside the grace window: still reachable)
  (nothing)                (window closes empty: one failure counted)
```

No probe is ever relayed through a third peer. In the SWIM literature the
relay exists to stop one node's false "dead" verdict from spreading through
the group; here a verdict never leaves the node that formed it, so the
relay would protect nothing — and keeping a one-way-deaf link marked
reachable would keep the node sending into a link that cannot answer,
while data converges through any healthy third node regardless.

## Rationale

1. **The status means what it says**: "I cannot usefully exchange data
   with this peer directly" is exactly what the status gates.
2. **Scalable**: O(1) probe messages per node per round.
3. **Configurable**: suspicion thresholds tunable for different networks.
4. **Simple state machine**: reachable → suspected → unreachable.
5. **One code path**: every verdict-bearing probe has the same shape,
   so the late-Ack protection (ADR-012) is universal.

## Protocol Details

### States

- **Reachable**: Peer answers probes.
- **Suspected**: After `suspicionThreshold` (default 5) consecutive probe
  failures. Still probed; recovers by answering.
- **Unreachable**: After `unreachableThreshold` (default 15) consecutive
  probe failures. Excluded from regular probing and gossip. Probed for
  recovery every `unreachableProbeInterval` (default 5) rounds.

### Configuration

```dart
CoordinatorConfig(
  suspicionThreshold: 5,       // Failed probes before suspected (default: 5)
  unreachableThreshold: 15,    // Failed probes before unreachable (default: 15)
  unreachableProbeInterval: 5, // Probe unreachable peers every N rounds (default: 5)
  startupGracePeriod: Duration(seconds: 10), // Hold new peers out of probing
)
```

Timing parameters (ping timeout, probe interval, gossip interval) are
RTT-adaptive and not directly configurable — see ADR-013. The grace
window is one more per-peer ping timeout and has no knob of its own.

### No incarnation numbers

SWIM's incarnation numbers let a wrongly suspected node refute the rumor.
There is no rumor here — a suspicion is private to the node that formed
it — so a wrongly suspected peer clears its name by answering the next
probe, or by sending anything at all. Neither library implements
incarnation numbers; the Kotlin twin's leftover scaffolding is scheduled
for deletion.

### Tuning Guide

All parameters are set via `CoordinatorConfig` and passed to
`Coordinator.create()`. Only the policy thresholds below are tunable.

| Parameter | Default | Effect of raising | Effect of lowering |
|-----------|---------|-------------------|--------------------|
| `suspicionThreshold` | 5 | Slower to suspect, fewer false positives | Faster detection, more false positives on flaky networks |
| `unreachableThreshold` | 15 | Longer recovery window for suspected peers | Faster eviction, less chance to recover |
| `unreachableProbeInterval` | 5 | Less overhead probing dead peers, slower deadlock recovery | Faster deadlock recovery, negligible extra bandwidth (~66 bytes/probe) |
| `startupGracePeriod` | 10s | More time for transport to stabilize | Faster initial failure detection |

#### Failure detection timeline (defaults, ~1.5s probe interval)

**This timeline assumes n=2** (one probable peer, so every round probes the
dead peer). Probe selection is round-robin over a shuffled order, so a
specific dead peer is probed roughly once every (n−1) rounds; multiply the
times below by ~(n−1) for larger groups. In practice, on the BLE transport a
closed connection removes the peer immediately, so this timeline mainly
governs half-open links.

1. **0–7.5s**: First 5 probes fail → peer becomes **suspected**
2. **7.5–22.5s**: 10 more probes fail → peer becomes **unreachable**
3. **Every ~7.5s thereafter**: One recovery probe fires. If the peer
   answers, directly or inside the grace window, it recovers to
   **reachable** immediately.

#### Recovery paths

- **Suspected → Reachable**: the peer answers any regular probe, or sends
  anything the node receives.
- **Unreachable → Reachable**: three ways:
  1. A periodic recovery probe gets an answer
  2. The peer sends an incoming Ping (handled by the detector)
  3. Transport reconnection triggers `addPeer()` (e.g., BLE reconnect)

#### Bandwidth cost of unreachable probing

A Ping is ~66 bytes. At `unreachableProbeInterval: 5` with ~1.5s probe
intervals, that's one 66-byte message every ~7.5s per unreachable peer —
roughly 9 bytes/second, or 0.06% of typical gossip traffic. Lowering the
interval to 1 (probe every round) costs ~44 bytes/second, still negligible.

## Consequences

### Positive

- Fast detection of actual failures (~7.5s to suspected, ~22.5s to unreachable)
- Low false-positive rate from the grace window and two-tier thresholds
- Works well with unreliable mobile networks
- Automatic recovery from mutual-unreachable deadlocks via periodic probing
- Minimal bandwidth overhead
- One probe shape on both libraries

### Negative

- A one-way-deaf pair is reported as degraded even when a third node
  could reach both sides (intended: data still converges through it)
- Small delay before declaring a node unreachable

### Integration

- FailureDetector runs alongside GossipEngine
- Shares MessagePort for network communication
- Updates PeerRegistry with status changes
- Emits PeerStatusChanged events
- A `PingReq` frame from a peer on an older build is decoded and ignored;
  the type leaves the wire at the next dialect revision.

## History

### Original decision (2026-03): SWIM

The detector was first specified as SWIM (Scalable Weakly-consistent
Infection-style Membership): direct probes plus, on a direct timeout, an
indirect probe relayed through up to three intermediaries. The rationale
was fewer false positives from transient network issues, and precedent in
HashiCorp Serf and Consul. SWIM proper is three mechanisms — probing,
dissemination of verdicts, and refutation by incarnation number — and only
the probing was ever built; ADR-007 made membership deliberately local.

### Retirement (ruled 2026-09-01, Kotlin shipped 2026-09-15, Dart 2026-09-18)

With no dissemination, the relay's purpose — insulating the group from one
node's false verdict — had no referent, and its local effect was
counterproductive (a deaf link kept marked reachable). On the Kotlin twin
the relay had also been structurally inert since the port, so the server
fleet had been running without it unnoticed. Both libraries now converge
on the slimmer detector; the full argument is the retirement decision
record in `docs/superpowers/specs/2026-09-01-swim-slimdown-decision.md`,
and the Dart batch's rulings are in
`docs/superpowers/specs/2026-09-18-dart-relay-retirement-rulings.md`.
The mechanism is no longer called SWIM anywhere the library describes
itself, since neither dissemination, refutation, nor indirect probing
remain.

## Alternatives Considered

### Simple Heartbeat

Each peer broadcasts "I'm alive" periodically: simpler, but O(n) messages
per period, higher false-positive rate, poor scaling.

### Phi Accrual Detector

Adaptive threshold based on heartbeat history: more accurate for stable
networks but complex to tune, assumes regular heartbeats, overkill here.

### Passive liveness only

No dedicated probes; liveness from transport link events plus sync-traffic
recency. Rejected in the retirement record: quiescence pacing makes a
converged mesh deliberately quiet, so passive observation cannot tell
"paced and healthy" from "dead" — the idle probe is load-bearing.

### No Failure Detection

Let gossip timeouts handle failures: wastes bandwidth on dead peers, gives
the application no status, slow to detect.
