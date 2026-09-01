# Drop peer persistence from the Dart library

**Track:** Code health   **Depends on:** nothing

## What this is

The Dart library exposes an optional persistence interface for the peer
list — which devices are currently known. The Kotlin twin deleted its
equivalent long ago on the grounds that persisting peers is pointless: a
restart drops every connection, so peers must reconnect and re-register
anyway. The owner reviewed the asymmetry (2026-09-01) and ruled that the
Dart side should match.

The evidence that nothing needs it is unusually complete. The library never
reads the interface back — there is no restore path at startup, and the one
read method's own documentation says the library never calls it. The
2026-08-21 architecture-honesty ruling already stripped all liveness state
from it, leaving only a bare add/remove journal of identifiers that carry no
address (transports own those). The only consumer application never touches
it and rides the in-memory default. And the server independently reached the
same conclusion: it has already deleted its peers table by migration.

## Why it matters

Dead API surface costs real weight here: an interface, its in-memory default,
a constructor parameter, and — the expensive part — a per-peer write-ordering
chain inside the peer service that exists solely to serialize writes nobody
reads. Removing it also closes one of the parity program's open joint
decisions and the structural asymmetry it caused (the Kotlin side has no
membership interfaces sublayer because it deleted this).

## Rough approach

Remove the interface, the in-memory implementation, the constructor
parameter, the peer service's persistence path and its write chain, and the
clear call in the reset path (reset keeps working; there is simply nothing
to clear). Applications that want a "recently seen devices" feature keep the
membership events as their extension point. Breaking change, ships in the
next major (the library is unpublished; the sole consumer is unaffected).

## Related

- Ruled on the owner's review of the parity program's open joint decisions,
  2026-09-01 — see the [twin parity program](../parity.md).
- The Kotlin-side precedent: gossip-kt
  `docs/superpowers/plans/2026-03-27-remove-peer-repository.md`.
- The earlier ruling that stripped liveness state from this interface:
  [architecture honesty fixes](../superpowers/specs/2026-08-21-architecture-honesty-fixes-design.md).
- Recorded as a divergence-register row in
  [Record where the Dart library and its Kotlin twin diverge, with a verdict](kt-normalize-twin-divergences.md).
