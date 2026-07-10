# Integration coverage for adverse network scenarios

**Track:** Testing   **Depends on:** [Simulate adverse network conditions in the test harness](testing-network-condition-simulation.md)

## What this is

Once the test harness can express hostile network conditions, actually use
it: a suite of integration tests that drive the whole sync stack through the
failure modes field devices really hit, and assert the system converges
anyway. The initial target list:

- **Lost messages and retries** — drop individual sync replies and verify
  the pending-request timeout expires, the request is retried, and the data
  still converges (today only unit tests touch this logic).
- **Asymmetric partition** — one-way link failure between two nodes, with a
  third node relaying: verifies the failure detector's indirect probing
  actually rescues the pair.
- **Duplicate frames** — the same message delivered twice must not corrupt
  state or double-apply entries (idempotency is currently only tested by
  re-running rounds, which re-sends equivalent — not identical — traffic).
- **Clock skew** — nodes whose clocks advance at different rates or start
  far apart, exercising the hybrid-logical-clock drift bound end to end.
- **Sustained congestion** — a genuinely slow link (high latency, queued
  messages) and the engine's round-skipping under real, not simulated,
  backpressure.

## Why it matters

These are the production failure modes of a Bluetooth mesh in the field.
Every one of them currently has protocol-level logic dedicated to it —
timeouts, indirect probes, drift bounds, congestion gates — whose end-to-end
behavior is untested because the harness couldn't produce the condition.

## Rough approach

One test file per scenario under the existing integration-test layout,
using the new harness conveniences; deterministic (seeded, virtual-time)
like the rest of the suite.

## Related

- Harness prerequisite: [testing-network-condition-simulation.md](testing-network-condition-simulation.md).
