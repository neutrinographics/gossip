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
- ☑ **Medium** — [Tell a rejected Bluetooth peer it was rejected](backlog/engine-reject-notify-capped-peers.md) · GSP2 control frame + receiver close + policy backoff — shipped in b210fdb..4f3d072; the WIRE4-9 subscribe race found by the 2026-08-20 audit was re-fixed in 3cf8445 (paced rejection re-sends triggered by inbound writes)
- ☐ **Medium** — [Cut redundant work on the message hot path](backlog/engine-hot-path-performance.md) · type-byte dispatch before decode, encode-once-send-many, checkpointed rebuilds, cache the GATT characteristic
- ☐ **Medium** — [Per-peer send queues for the Nearby transport](backlog/engine-nearby-per-peer-queues.md) · one stalled endpoint currently head-of-line-blocks pings to every other peer; port the BLE transport's per-peer design
- ☐ **Low** — [Eliminate head-of-line blocking on the Bluetooth transport](backlog/engine-ble-frame-multiplexing.md) · an urgent message can still wait out one in-flight transfer; frame multiplexing would remove even that
- ☐ **Low** — [Bound the Bluetooth send-queue depth](backlog/engine-send-queue-depth-cap.md) · add a size ceiling so a slow/stalled link can't grow the outgoing queue without limit (backstop; the congestion gate already throttles in practice)
- ☐ **Low** — [Revisit the failure-detection sensitivity thresholds](backlog/engine-swim-threshold-tuning.md) · measure and possibly tighten the 5/15 consecutive-miss thresholds now that fair-rotation probing, adaptive timeouts, and indirect checks are in place
- ☐ **Low** — [Best-effort pre-connect identity hash in the Android advertisement](backlog/engine-preconnect-adv-hash.md) · skip initiating a losing mutual connect on Android↔Android pairs; post-connect tie-break stays the backstop
- ☐ **Medium** — [Send reactive pushes only to peers that share the data](backlog/engine-push-scoping.md) · scope push fan-out by channel membership + congestion-gate pushes and request bursts (2026-08 audit R6)
- ☐ **Medium** — [Coalesce wire traffic into fewer radio wakeups](backlog/engine-message-coalescing.md) · SRTT-scaled debounce, batched deltas, push-pull completion, transport hold window (2026-08 audit R7)
- ☐ **Low** — [Shrink version vectors on the wire with an author-index table](backlog/engine-author-index-wire-format.md) · wire-format change, both ends (2026-08 audit R8)
- ☐ **Low** — [Piggyback sync summaries on liveness probes](backlog/engine-digest-on-probe-piggyback.md) · one radio wakeup serves both loops; crosses the PeerDirectory seam with an opaque payload (WIRE4-19)
- ☐ **Low** — [Make Bluetooth advertising transmit power configurable](backlog/engine-ble-advertise-tx-power.md) · bluey hardcodes HIGH; add the knob upstream then plumb an owned enum like AdvertiseMode

## Testing

Test-infrastructure quality: making simulated network conditions expressive
enough to exercise the failure modes the protocol logic exists for.

- ☑ **High** — [Simulate adverse network conditions in the test harness](backlog/testing-network-condition-simulation.md) · per-link drop/duplication/corruption/one-way-partition/held-latency policies, async delivery default, emergent backpressure — shipped in 4b0106f
- ☑ **High** — [Integration coverage for adverse network scenarios](backlog/testing-adverse-scenario-coverage.md) · 20 tests across loss/retry, asymmetric partition, duplicate frames, clock skew, congestion — shipped in 4b0106f
- ☑ **High** — [Run full syncs over a faulty BLE link in the end-to-end tests](backlog/testing-bluey-adverse-e2e.md) · chunk drop, hung write + send timeout, mid-message disconnect, supersession, connect backoff — shipped in c8c35ae
- ☐ **Medium** — [A stateful fake network for the Nearby transport](backlog/testing-nearby-fake-port.md) · bring gossip_nearby up to bluey's standard: fake endpoint network + end-to-end Coordinator tests
- ☐ **Medium** — [Make the Bluetooth test fake faithful to real GATT behavior](backlog/testing-bluey-gatt-fidelity-fake.md) · subscription state + real 20 B write sizes first, then a fake beneath the platform adapter — the WIRE4-9 bug class is invisible to today's tests
- ☐ **Low** — [Quality-of-life additions to the adverse-network harness](backlog/testing-harness-niceties.md) · type-selective drop/duplicate predicates, per-node runRounds steps, duplicate-rate DSL wrapper, BLE facade test knobs
- ☐ **Low** — [Close the recorded test debt from the tie-break/rejection reviews](backlog/testing-tiebreak-followup-tests.md) · queued-send-across-swap, backoff dedup branch, both-orders stagger, codec edges, backoff-reset product decision

## Code health

Internal structure, documentation honesty, and audit-hygiene work — no
runtime behavior changes.

- ☑ **Medium** — [Realign the module layout and make the architecture scream](backlog/health-architecture-alignment.md) · concept-first bounded contexts (shared/sync/membership/coordinator) with a machine-checked boundary — part 1 shipped in 202bf6d..00420fc, part 2 shipped in 4024678..544efe8
- ☐ **High** — [Sweep the remaining minor audit findings](backlog/health-minor-findings-sweep.md) · two correctness latents (unbudgeted sync-request size, uncopied payload buffers) + transport minors + hygiene
- ☐ **Low** — [Converge the transports' MessagePort close() semantics](backlog/health-transport-port-close-semantics.md) · nearby gates its own view only, bluey's close() tears down the whole connection layer — converge on port-gates-itself, facade owns teardown
- ☐ **Low** — [Give the sync engine its own sizing interface instead of downcasting its codec](backlog/health-sync-codec-sizing-port.md) · the injected `MessageCodec` gets cast to the concrete `SyncMessageCodec` for two byte-budget helpers; a sync-owned sizing interface would close the gap
- ☐ **Low** — [Normalize formatter drift so diffs stop lying](backlog/health-format-normalization.md) · one pinned-SDK formatting-only commit per package, then the format gate becomes a no-op

## Kotlin port

Keeping the standalone Kotlin library (`gossip-kt`) current with what the
Dart library has learned since it was ported.

- ☐ **Medium** — [Port the wire-efficiency behaviors to the Kotlin library](backlog/kt-port-wire-efficiency.md) · quiescence pacing, probe suppression + cap, dominance filter — kt still chats at full cadence forever; interop-safe to port incrementally
- ☐ **Low** — [Mirror the bounded-context structure in the Kotlin library](backlog/kt-mirror-bounded-contexts.md) · port back the four evaluated divergences + a Kotlin edge-table boundary test so the twins converge
- ☐ **Medium** — [Audit the Kotlin library for the bug classes fixed in Dart](backlog/kt-audit-legacy-bug-classes.md) · kt predates the 2026-07 remediation; check it against the known defect list (scheduler forking, silent duplicate drops, VV regression, compaction lockout)
