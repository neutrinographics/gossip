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
detection. Seeded from the 2026-07 algorithm audit's deferred follow-ups
(all shipped fixes are recorded in
[`audits/2026-07-06-algorithm-audit.md`](audits/2026-07-06-algorithm-audit.md)).

- ☐ **Low** — [Eliminate head-of-line blocking on the Bluetooth transport](backlog/engine-ble-frame-multiplexing.md) · an urgent message can still wait out one in-flight transfer; frame multiplexing would remove even that
- ☐ **Low** — [Bound the Bluetooth send-queue depth](backlog/engine-send-queue-depth-cap.md) · add a size ceiling so a slow/stalled link can't grow the outgoing queue without limit (backstop; the congestion gate already throttles in practice)
- ☐ **Low** — [Revisit the failure-detection sensitivity thresholds](backlog/engine-swim-threshold-tuning.md) · measure and possibly tighten the 5/15 consecutive-miss thresholds now that fair-rotation probing, adaptive timeouts, and indirect checks are in place
