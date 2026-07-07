# Bound the Bluetooth send-queue depth

**Track:** Sync engine   **Depends on:** nothing

## What this is

Each connected device keeps a queue of outgoing messages waiting their turn
on the slow Bluetooth link. Right now that queue has no size limit. This item
adds a ceiling, so a device that keeps producing data faster than the link
can drain doesn't build up an ever-growing backlog in memory.

## Why it matters

Without a limit, a sustained burst of activity against a slow or stalled
connection could grow memory use without bound. In everyday operation this
doesn't happen — the sync engine already eases off sending to a peer whose
queue is getting deep — so this is a safety backstop rather than an active
problem. It closes the gap for a producer that ignores that backpressure or a
link that stalls for a long time.

## Rough approach

Give each peer's queue a maximum size (a message count or a total byte
budget). When it's exceeded, either drop the oldest non-urgent messages or
push back on whatever is producing them. Urgent messages (health checks)
stay exempt so failure detection is never starved.

## Related

- Builds on the priority send queue introduced for the
  [algorithm audit](../audits/2026-07-06-algorithm-audit.md) (finding H1),
  which the audit noted was intentionally left unbounded.
- Sibling: [Eliminate head-of-line blocking on the Bluetooth transport](engine-ble-frame-multiplexing.md).
