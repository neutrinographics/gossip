# Give the sync engine its own sizing interface instead of downcasting its codec

**Track:** Code health   **Depends on:** nothing

## What this is

The sync engine is handed a message codec through a shared interface at
construction time, so in principle any implementation of that interface
could be plugged in. In practice, the engine needs two extra byte-counting
helpers — estimating how big an entry or a stream summary will be once
encoded — that aren't part of the shared interface, because they're a
sync-specific concern the other context's codec has no reason to offer. To
get at them, the engine casts its codec down to the concrete sync
implementation at runtime and calls the helpers directly.

## Why it matters

This works today because the composition root only ever wires the real sync
codec in. But it leaves an application-layer file depending on an
infrastructure-layer concrete class, and it's a trap for the next codec
implementation someone plugs in for testing or an alternate wire format: if
it doesn't happen to be that exact concrete class, the cast fails at
runtime instead of being caught by the type system.

## Rough approach

Introduce a small sizing interface owned by the sync context (alongside its
other domain-level ports) that exposes just the two byte-budget helpers.
Have the concrete sync codec implement it, and have the engine depend on
that interface instead of downcasting. While in the area, the failure
detector also imports the concrete membership codec class purely so a doc
comment can link to it — that import isn't needed for anything the code
actually does and should come out too.

## Related

- `packages/gossip/lib/src/sync/application/gossip_engine.dart` — the
  `_syncCodec` downcast getter and its two call sites
  (`encodedEntrySize`/`encodedStreamDigestSize`).
- `packages/gossip/lib/src/sync/infrastructure/sync_message_codec.dart` —
  where those two helpers live today.
- `packages/gossip/lib/src/membership/application/failure_detector.dart` —
  the doc-comment-only import of the concrete membership codec.
- [ADR-010](../../packages/gossip/docs/adr/010-ddd-layered-architecture.md)
  — the per-context codec split this interface would slot into.
