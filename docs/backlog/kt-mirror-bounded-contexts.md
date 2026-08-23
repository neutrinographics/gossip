# Mirror the bounded-context structure in the Kotlin library

**Track:** Kotlin port   **Depends on:** nothing

## What this is

The Dart library's 2026-08 restructure evaluated the Kotlin port's package
layout against the real dependency graph and deliberately diverged from it
in four places: one sync context (not separate channels/entries packages),
one membership context (not separate peers/detection packages), the RTT
tracker in the shared kernel (both loops use it), and per-context wire
codecs that dissolve the central-codec compromise entirely. This item
ports those better answers back, plus the machine-checked boundary test,
so the two codebases converge on one structure.

## Why it matters

The two libraries are meant to be structural twins; every future port in
either direction gets cheaper when they are. The Kotlin layout also still
contains the latent mistakes the Dart evaluation exposed (a service
straddling two of its own packages; a shared utility homed in one
consumer).

## Rough approach

Mechanical move under a green gate, mirroring the Dart migration order
(seams first, then module moves), with a Kotlin edge-table architecture
test equivalent to the Dart one.

## Related

- The evaluation and divergences:
  [adr/010](../../packages/gossip/docs/adr/010-ddd-layered-architecture.md) and
  [the bounded-contexts spec](../superpowers/specs/2026-08-21-bounded-contexts-restructure-design.md).
- Siblings: [Port the wire-efficiency behaviors to the Kotlin library](kt-port-wire-efficiency.md),
  [Audit the Kotlin library for the bug classes fixed in Dart](kt-audit-legacy-bug-classes.md).
