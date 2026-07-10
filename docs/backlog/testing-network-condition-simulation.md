# Simulate adverse network conditions in the test harness

**Track:** Testing   **Depends on:** nothing

## What this is

The in-memory "network" the core integration tests run on is deliberately
perfect: every message arrives instantly, in order, exactly once, and the
only failure that can be simulated is a node dropping off the network
entirely (in both directions at once). Real radio links fail in far richer
ways, and today none of them can be expressed in a test:

- **Latency** — a message taking time to arrive, so it can race with state
  changes that happen while it is in flight.
- **Loss of individual messages** — one dropped reply, not a dead node, so
  retry and timeout logic actually runs.
- **One-way (asymmetric) partitions** — A can hear B but B can't hear A: the
  classic degraded-radio case the failure detector's indirect probing was
  built for, currently impossible to construct.
- **Duplicate delivery** — the same frame arriving twice.
- **Corruption** — mangled bytes on the wire.
- **Real backpressure** — today "congestion" is a number a test writes into
  the transport; with delayed delivery it could instead emerge from messages
  genuinely queuing.

The upgrade adds per-link condition policies to the in-memory message bus,
plus matching conveniences on the test-network helper, while keeping runs
fully deterministic (seeded randomness, virtual time).

## Why it matters

The sync engine's hardest bugs — merge races, retry storms, wedged pending
requests — live exactly in the conditions the harness cannot produce. Today
those paths are reachable only by unit-testing internals. A perfect-network
harness also made test timing *less* realistic than production: message
delivery never yields to the event loop, which helped hide a real deadlock
for a whole debugging session.

## Rough approach

The bus is one small class. Give it a per-link policy hook (latency, drop,
duplicate, corrupt, one-way block) consulted at delivery time, defaulting to
today's behavior; route delivery through an asynchronous yield; expose
scenario helpers (e.g. "drop the next delta from A to B", "partition A→B
only") on the test-network DSL. Determinism holds: policies use seeded
randomness and virtual-time delays.

## Related

- [Integration coverage for adverse network scenarios](testing-adverse-scenario-coverage.md)
  builds on this harness.
- [A stateful fake network for the Nearby transport](testing-nearby-fake-port.md)
  is the same idea one layer down, for the Android Nearby transport.
