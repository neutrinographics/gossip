# Realign the module layout and make the architecture scream

**Track:** Code health   **Depends on:** nothing

## What this is

Two structural rounds, done as one item because the first's fixes are
prerequisites for the second's moves.

**Part 1 — make the current architecture honest.** The project's architecture
rule is that dependencies point inward: the domain layer defines interfaces,
outer layers implement them. Several places violate this today, and the
architecture decision records partly codify the contradiction:

- The time and messaging port *interfaces* live in the outermost
  (infrastructure) layer while inner layers depend on them — backwards. Move
  the interfaces inward next to the repository interfaces, which already
  model this correctly.
- The application↔protocol "bridge" component named in the architecture docs
  is dead code with zero production users that itself imports the facade.
  Delete it and redraw the diagram.
- In both transport packages, application-layer services import the concrete
  wire codecs, so wire-format knowledge executes a layer too high. Home the
  codecs as protocol-level services or hide them behind an interface.
- The Nearby transport has imports running in both directions between its
  application and infrastructure layers; the BLE transport's dispatcher seam
  is the in-repo fix to copy.
- The BLE transport leaks the third-party Bluetooth library's enums through
  its public API, forcing consuming apps to import that library just to name
  advertising/scanning states. Introduce owned lifecycle enums and translate
  at the adapter, as the package already does for adapter state.
- The protocol layer mutates peer state (health status, contact times,
  metrics) directly, bypassing the service whose docs claim to own that
  path — so anyone who plugs in a *persistent* peer store will silently
  lose every one of those changes (only add/remove ever reach storage).
  Decide the honest contract: document protocol-driven peer state as
  memory-only by design (and simplify the service accordingly), or route
  the mutations through it. Fix the false "Used by: Protocol services"
  doc claim either way. (The ChannelService half of this finding was
  already fixed; this is the PeerService half.)

**Part 2 — make the architecture scream the domain.** Every package is laid
out by layer (domain / application / protocol / infrastructure), so the file
tree says "DDD template" rather than what the software does. Inside the core
package, two subdomains are invisible: **anti-entropy synchronization** (the
core domain — channels, streams, digests, deltas) and **failure detection /
membership** (peers, probes, liveness), plus a small **shared kernel**
(identities, clocks, version vectors). Reorganize to concept-first packaging
so those bounded contexts are visible in the tree. The project's Kotlin port
already proved this exact layout — sync / detection / a true-leaf shared
kernel, with the one cross-cutting codec compromise explicitly documented —
so this is porting a working structure back, not inventing one.

Two seams become explicit that today are invisible:

- the shared kernel is a named leaf both subdomains may use;
- the sync↔detection interaction becomes a **named contract**. Today the two
  subsystems run side by side and barely talk — the 2026-08 audit found
  liveness evidence recorded on the sync path is never consumed by
  detection, and its recommended digest-on-probe piggybacking would couple
  the two further. Whatever they exchange (liveness evidence, piggybacked
  digests) should cross one explicit interface, not reach-ins.

Amend the affected architecture decision records (ADR-010, and 011 where
touched) so docs and code agree.

## Why it matters

Part 1 changes no runtime behavior — it prevents the *next* class of bug:
wire formats drifting per layer, dead components misleading readers, a
supposedly transport-agnostic API that isn't, and a persistence extension
point that silently drops data. Part 2 makes the bounded contexts visible to
a newcomer in the file tree, gives the new concepts from the wire-scheduling
work (pacing policy, convergence memory, probe suppression) an obvious home,
and turns accidental coupling between sync and detection into something a
review can see and judge.

## Rough approach

Part 1 first (interface moves, deletions, doc fixes). Part 2 is a mechanical
move under a green test gate, best done **after** the wire-scheduling
pacing redesign lands, so its new concepts move once into their final homes
rather than being reorganized mid-change. Mirror the Kotlin port's layout
decisions — including its documented codec compromise — unless a
Dart-specific reason argues otherwise.

## Related

- Part 1: [design spec](../superpowers/specs/2026-08-21-architecture-honesty-fixes-design.md), [implementation plan](../superpowers/plans/2026-08-21-architecture-honesty-fixes.md).
- Part 2: [design spec](../superpowers/specs/2026-08-21-bounded-contexts-restructure-design.md), [implementation plan](../superpowers/plans/2026-08-22-bounded-contexts-restructure.md) — the shipped layout is `shared/ sync/ membership/ coordinator/`, documented in
  [ADR-010](../../packages/gossip/docs/adr/010-ddd-layered-architecture.md)
  and the root [GLOSSARY.md](../../GLOSSARY.md).
- Findings ARCH3-1..6 in
  [audits/2026-07-08-comprehensive-audit.md](../audits/2026-07-08-comprehensive-audit.md)
  (round "R12" plus R13's unfinished half).
- Findings WIRE4-3 and WIRE4-19 in
  [audits/2026-08-20-wire-scheduling-audit.md](../audits/2026-08-20-wire-scheduling-audit.md)
  motivate the explicit sync↔detection contract.
- The Kotlin port (`gossip-kt` repository), design doc
  `docs/plans/2026-03-09-gossip-kt-design.md`: its `sync/`, `detection/`,
  `shared/` layout was evaluated against the real Dart import graph and
  diverged in four places when this part shipped (recorded in ADR-010 as
  findings to port back to `gossip-kt`).
