# Per-peer send queues for the Nearby transport

**Track:** Sync engine   **Depends on:** nothing

## What this is

The Android Nearby transport pushes all outgoing messages through one global
queue pair shared by every connected peer. If a single endpoint stalls, every
message behind it waits — including the small, time-critical health-check
pings to *other*, perfectly healthy peers, which can then be falsely suspected
of being offline.

The BLE transport already solved this with one send queue per peer; Nearby
has no frame-contiguity constraint that would force a global lane, so the
same design ports over directly.

## Why it matters

One slow peer shouldn't be able to make every other peer look dead. This is
exactly the failure regime the failure detector's earlier hardening was built
for, reintroduced through the transport. Audit finding PERF3-6 (2026-07-08).

## Rough approach

Mirror the BLE transport's per-peer queue + drain-loop structure, keeping the
priority split (health-check pings ahead of bulk sync data) within each
peer's queue.

## Related

- Finding PERF3-6 in
  [audits/2026-07-08-comprehensive-audit.md](../audits/2026-07-08-comprehensive-audit.md).
- [Eliminate head-of-line blocking on the Bluetooth transport](engine-ble-frame-multiplexing.md)
  — the same theme one level deeper, for BLE.
- [Bound the Bluetooth send-queue depth](engine-send-queue-depth-cap.md).
