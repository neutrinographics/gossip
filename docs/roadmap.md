# Roadmap

The at-a-glance index of planned work. Each item links to a stand-alone
description in [`backlog/`](backlog/). **Priority and status live here only** —
never in a backlog file.

- **Status:** ☐ not started · ◐ in progress · ☑ done
- **Priority:** High · Medium · Low · Launch (gated to before public exposure)

## Guardrails (design invariants)

Constraints that new work must respect (see `packages/gossip/docs/adr/`):

- **Single-isolate execution** — no locks; all engine state is touched from one isolate.
- **~32 KB message cap** — the largest a single message may be on the wire (Android Nearby Connections + BLE frame codec share this limit).
- **≤ 8 devices per channel** recommended.
- **Transport- and discovery-external** — the library defines the `MessagePort` interface and is told about peers; it neither opens sockets nor finds devices itself.
- **Payload-agnostic** — the library syncs opaque bytes; the application defines their meaning.

## Sync engine

Robustness of the gossip sync engine, its Bluetooth transport, and failure
detection. Seeded from the deferred follow-ups of the 2026-07 audits
(shipped fixes are recorded in
[`audits/2026-07-06-algorithm-audit.md`](audits/2026-07-06-algorithm-audit.md) and
[`audits/2026-07-08-comprehensive-audit.md`](audits/2026-07-08-comprehensive-audit.md)).

- ☑ **High** — [One Bluetooth link per device pair in a mesh](backlog/engine-mesh-connection-tiebreak.md) · post-connect tie-break (smaller NodeId is central; loser closes its own central) — shipped in 5a6a764
- ☑ **Medium** — [Tell a rejected Bluetooth peer it was rejected](backlog/engine-reject-notify-capped-peers.md) · GSP2 control frame + receiver close + policy backoff — shipped in b210fdb..4f3d072
- ☐ **Medium** — [Cut redundant work on the message hot path](backlog/engine-hot-path-performance.md) · type-byte dispatch before decode, encode-once-send-many, checkpointed rebuilds, cache the GATT characteristic
- ☐ **Medium** — [Per-peer send queues for the Nearby transport](backlog/engine-nearby-per-peer-queues.md) · one stalled endpoint currently head-of-line-blocks pings to every other peer; port the BLE transport's per-peer design
- ☐ **Low** — [Eliminate head-of-line blocking on the Bluetooth transport](backlog/engine-ble-frame-multiplexing.md) · an urgent message can still wait out one in-flight transfer; frame multiplexing would remove even that
- ☐ **Low** — [Bound the Bluetooth send-queue depth](backlog/engine-send-queue-depth-cap.md) · add a size ceiling so a slow/stalled link can't grow the outgoing queue without limit (backstop; the congestion gate already throttles in practice)
- ☐ **Low** — [Revisit the failure-detection sensitivity thresholds](backlog/engine-swim-threshold-tuning.md) · measure and possibly tighten the 5/15 consecutive-miss thresholds now that fair-rotation probing, adaptive timeouts, and indirect checks are in place
- ☐ **Low** — [Best-effort pre-connect identity hash in the Android advertisement](backlog/engine-preconnect-adv-hash.md) · skip initiating a losing mutual connect on Android↔Android pairs; post-connect tie-break stays the backstop

## Testing

Test-infrastructure quality: making simulated network conditions expressive
enough to exercise the failure modes the protocol logic exists for.

- ☑ **High** — [Simulate adverse network conditions in the test harness](backlog/testing-network-condition-simulation.md) · per-link drop/duplication/corruption/one-way-partition/held-latency policies, async delivery default, emergent backpressure — shipped in 4b0106f
- ☑ **High** — [Integration coverage for adverse network scenarios](backlog/testing-adverse-scenario-coverage.md) · 20 tests across loss/retry, asymmetric partition, duplicate frames, clock skew, congestion — shipped in 4b0106f
- ☑ **High** — [Run full syncs over a faulty BLE link in the end-to-end tests](backlog/testing-bluey-adverse-e2e.md) · chunk drop, hung write + send timeout, mid-message disconnect, supersession, connect backoff — shipped in c8c35ae
- ☐ **High** — [A stateful fake network for the Nearby transport](backlog/testing-nearby-fake-port.md) · bring gossip_nearby up to bluey's standard: fake endpoint network + end-to-end Coordinator tests
- ☐ **Low** — [Quality-of-life additions to the adverse-network harness](backlog/testing-harness-niceties.md) · type-selective drop/duplicate predicates, per-node runRounds steps, duplicate-rate DSL wrapper, BLE facade test knobs
- ☐ **Low** — [Close the recorded test debt from the tie-break/rejection reviews](backlog/testing-tiebreak-followup-tests.md) · queued-send-across-swap, backoff dedup branch, both-orders stagger, codec edges, backoff-reset product decision

## Code health

Internal structure, documentation honesty, and audit-hygiene work — no
runtime behavior changes.

- ☐ **Medium** — [Realign the module layout with the documented architecture](backlog/health-architecture-alignment.md) · ports to domain, delete the dead bridge, re-home transport codecs, owned lifecycle enums, amend ADR-010/011
- ☐ **Medium** — [Sweep the remaining minor audit findings](backlog/health-minor-findings-sweep.md) · MIN-series plus two correctness latents (unbudgeted sync-request size, uncopied payload buffers)
