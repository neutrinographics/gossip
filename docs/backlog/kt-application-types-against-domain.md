# Let the Kotlin application layer name only domain types

**Track:** Kotlin port   **Depends on:** nothing

## What this is

After the purification, every lock in the Kotlin library lives in a
`Synchronized*` wrapper under `infrastructure/`. The application classes
that use those wrappers — the gossip engine, the reactive pusher, the peer
service, the failure detector — import them by name. That points a
dependency outward: the use-case layer knows an infrastructure type, which
is the one direction Clean Architecture forbids.

The purification already solved this once, where it had no choice: the
scheduler is a domain class and cannot name an infrastructure wrapper, so
its pure state class is `open`, the wrapper subclasses it, the consumer
types against the pure class, and the composition root passes the
synchronized one. A reflection test pins that the wrapper overrides every
public member, so nothing can run unguarded by omission. This item extends
that shape to the application-layer consumers and adds a test that fails
the build on any inward layer importing an outer one.

## Why it matters

Structural parity is half of the parity program, and "dependencies point
inward" is the rule both repositories state. The server that embeds this
library adopted the subclass shape on 2026-09-03 for its own sync ledger
and identities, with a reflection pin per wrapper and a layer-direction
test — the library should not be looser than its consumer. Without a
machine check, the next wrapper import lands silently; the server's first
one did, and only a hand audit caught it.

## Rough approach

- For each pure class whose wrapper is consumed from `application/`
  (the HLC clock, the pull tracker, the timing policies, the gap and
  stalled-range registries, the peer registry, the ping registry, the
  probe target selector, the pending pushes): make it `open`, have the
  wrapper subclass it and override every public member under its monitor,
  and add the reflection pin (`SynchronizedLoopGenerationTest` is the
  model).
- Application constructors take the pure type with no default; every
  construction site passes the synchronized instance explicitly, as the
  scheduler's already do.
- Add a layer-direction test beside the boundary test: `domain/` imports
  only `domain/`, `application/` never imports `infrastructure/`. The lock
  placement test is unchanged.
- Dart companion: no wrappers exist, so nothing to port; the
  layer-direction check itself is a flow-back candidate for the Dart
  boundary test.

## Related

- The [divergence register](kt-normalize-twin-divergences.md) row
  "Application classes naming `Synchronized*` wrappers" is homed here.
- [The purification](kt-pure-domain-concurrency.md) and its
  [rulings page](../superpowers/specs/2026-09-02-kt-domain-purification-rulings.md),
  ruling 4 — the subclass shape this extends.
- The consumer's implementation: opendoor-api PR #20, post-audit commit
  (`SynchronizedSyncActivityLedger`, `SynchronizedPeerIdentities`,
  `LayerDirectionTest`).
- Sibling: [Mirror the bounded-context structure in the Kotlin library](kt-mirror-bounded-contexts.md).
