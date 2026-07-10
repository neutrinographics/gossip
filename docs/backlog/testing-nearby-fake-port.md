# A stateful fake network for the Nearby transport

**Track:** Testing   **Depends on:** nothing

## What this is

The two transport packages are tested very differently. The BLE transport
has a rich, hand-written fake of its platform layer — fake devices that
discover each other, connect, exchange data, and can be told to fail in
specific ways (connection failures, latency, silently dropped chunks,
disconnects) — plus end-to-end tests that run the real sync coordinator over
that fake in mesh and star topologies.

The Android Nearby transport has none of that: its tests stub individual
method calls with a mocking library. Error paths are covered call-by-call,
but there is no simulated network of endpoints, no fault injection, and no
test that runs the full sync stack over the transport.

This item brings the Nearby package up to the BLE package's standard: a
stateful fake of the Nearby platform API (endpoints that discover, request,
accept, and exchange payloads, with injectable failures and delays) and
end-to-end coordinator tests on top of it.

## Why it matters

The Nearby transport's trickiest logic — the identity handshake, endpoint
bookkeeping, dispose-time queue draining — is exactly the kind of stateful,
order-sensitive behavior that per-call mocks verify weakly. The BLE package
demonstrated the payoff: its fake caught real connection-identity bugs the
mocks never would have.

## Rough approach

Mirror the BLE package's structure: a fake port class in the test tree
modeled on the existing BLE fake, a shared helper that wires the real
coordinator to it, and integration tests for the handshake, two-node sync,
and failure recovery.

## Related

- The BLE package's fake and integration tests are the template
  (see `packages/gossip_bluey/test/fakes/` and
  `packages/gossip_bluey/test/integration/`).
- [Simulate adverse network conditions in the test harness](testing-network-condition-simulation.md)
  — the same philosophy at the core-package layer.
