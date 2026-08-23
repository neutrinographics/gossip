# Shrink version vectors on the wire with an author-index table

**Track:** Sync engine   **Depends on:** nothing

## What this is

Version vectors — the "who has seen what" summaries exchanged constantly —
repeat every author's full identity string in every message. A small
per-message table that lists each author once and lets the vectors refer to
them by index would cut the dominant repeated cost of digests and deltas.

## Why it matters

Digest exchanges are the steady-state traffic of a converged network; their
size is mostly author identities repeated per stream. On an 8-device
channel the same UUIDs appear dozens of times per message.

## Rough approach

A wire-format change (both ends must understand it): add an author table to
the envelope, encode vectors as index→count maps. Version the change via
the existing type-byte space so old and new peers can coexist, or ship it
as a coordinated break while the deployment is small. This lands in each
context's own codec (sync owns its message shapes).

## Related

- Finding WIRE4-14 (recommendation R8) in
  [audits/2026-08-20-wire-scheduling-audit.md](../audits/2026-08-20-wire-scheduling-audit.md).
- The per-context codec homes:
  [adr/010](../../packages/gossip/docs/adr/010-ddd-layered-architecture.md).
