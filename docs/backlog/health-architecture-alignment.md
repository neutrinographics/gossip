# Realign the module layout with the documented architecture

**Track:** Code health   **Depends on:** nothing

## What this is

The project's architecture rule is that dependencies point inward: the domain
layer defines interfaces, outer layers implement them. Several places violate
this today, and the architecture decision records partly codify the
contradiction:

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

Amend the affected architecture decision records (ADR-010/011) so docs and
code agree.

## Why it matters

None of this changes runtime behavior — it prevents the *next* class of bug:
wire formats drifting per layer, dead components misleading readers, a
supposedly transport-agnostic API that isn't, and a persistence extension
point that silently drops data. Findings ARCH3-1 through ARCH3-6 from the
2026-07-08 audit (round "R12" plus R13's unfinished half).

## Related

- Findings ARCH3-1..5 in
  [audits/2026-07-08-comprehensive-audit.md](../audits/2026-07-08-comprehensive-audit.md).
