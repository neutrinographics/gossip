# Run full syncs over a faulty BLE link in the end-to-end tests

**Track:** Testing   **Depends on:** nothing

## What this is

The BLE transport package already owns the best fault-injection tooling in
the repo: a stateful fake of the Bluetooth layer that can drop chunks
mid-transfer, hang or fail writes, delay or fail connections, and disconnect
peers on demand. But those injectors are only exercised in service-level
unit tests. The package's end-to-end tests — the ones that run the real sync
coordinator over the fake in mesh and star topologies — are happy-path only.

This item drives the full stack through the faults: complete gossip syncs
over links that drop chunks, writes that hang until the send timeout fires,
disconnects that land mid-message, and reconnects that supersede a stale
link — asserting the system converges and recovers every time.

## Why it matters

Chunked BLE writes are exactly where partial-failure bugs live: a message is
~165 chunks at a good MTU and ~1,540 at the worst, and a fault in the middle
must corrupt nothing. The per-write timeout added in the 2026-07 audit
remediation has never been tested through the whole stack. All the tooling
exists; only the scenarios are missing.

## Rough approach

New test files alongside the existing end-to-end tests, reusing the
coordinator helpers and the fake's existing injectors (extending the fake —
test code — where a scenario needs a new hook).

## Related

- The existing fake and end-to-end tests: `packages/gossip_bluey/test/fakes/`,
  `packages/gossip_bluey/test/integration/`.
- Deepened by
  [Make the Bluetooth test fake faithful to real GATT behavior](testing-bluey-gatt-fidelity-fake.md)
  — this suite's fake models the transport's port interface; that item
  models the Bluetooth semantics beneath it (subscriptions, setup ordering,
  write sizes).
- [Simulate adverse network conditions in the test harness](testing-network-condition-simulation.md)
  — the same philosophy at the protocol layer.
- [A stateful fake network for the Nearby transport](testing-nearby-fake-port.md).
