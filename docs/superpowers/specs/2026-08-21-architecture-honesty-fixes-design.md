# Architecture Honesty Fixes (Batch 3, Part 1)

**Date:** 2026-08-21
**Status:** Approved (design); implementation pending
**Drives:** ARCH3-2, ARCH3-3, ARCH3-4, ARCH3-5, ARCH3-6 from the
[2026-07-08 comprehensive audit](../../audits/2026-07-08-comprehensive-audit.md)
(recommendations R12 minus ARCH3-1, plus R13's unfinished half). ARCH3-1
(port interfaces inward) is deliberately deferred to Part 2, where the
bounded-context move fixes it once instead of twice.

## Problem

Five places where the code contradicts the architecture the docs claim:
a dead application↔protocol bridge that imports the facade; wire-format
knowledge executing in the application layer of both transports; a
bidirectional application↔infrastructure cycle in nearby; third-party
`bluey` lifecycle enums leaking through gossip_bluey's public API; and a
peer-persistence extension point that silently drops every SWIM-driven
mutation. None of these breaks behavior today; each misleads the next
reader or the next extension.

## Owner decisions (Joel, 2026-08-21)

1. **ARCH3-6: SWIM-driven peer state is memory-only by design.**
   Status, contact times, and metrics are ephemeral runtime observations,
   meaningless across restarts. Document it, simplify `PeerService` to
   add/remove/query, fix the false doc claims. Do NOT route protocol
   mutations through the application service.
2. **gossip_nearby is in scope** — fix it alongside core and bluey.

## Design

### 1. ARCH3-2 — delete the dead bridge (core)

Delete `lib/src/application/coordinator_sync_service.dart`,
`lib/src/application/interfaces/sync_coordinator_service.dart`, and
their tests. Zero production consumers (audit-verified; re-verify with a
grep at implementation time). ADR-010's diagram is redrawn in Part 2;
this part only removes the code that made the diagram false.

### 2. ARCH3-3 — wire-format knowledge out of the application layer (both transports)

Each transport gains a `protocol/` layer (the core package's pre-Part-2
convention; transports keep layer-first layout — they are single-context
adapter packages):

- **gossip_nearby:** `HandshakeCodec` moves from `infrastructure/` to
  `protocol/`; the `WireFormat.typeOffset` byte-dispatch inside
  `ConnectionService` (~lines 425-440) is extracted into a protocol-layer
  service (e.g. `WireDispatcher`) that classifies inbound bytes;
  `ConnectionService` calls it and never touches byte layout again.
- **gossip_bluey:** `FrameEncoder`/`FrameDecoder` (and the GSP2
  control-frame encode/decode used by `ConnectionManager`'s rejection
  path) move from `infrastructure/` to `protocol/`. `ConnectionManager`
  keeps orchestration (retry counts, backoff policy) and delegates all
  byte-shaping.

Amend gossip_nearby's ADR-005 (which the current placement contradicts)
to record the protocol-layer home.

### 3. ARCH3-4 — break nearby's application↔infrastructure cycle

`NearbyMessagePort` (infrastructure) imports the concrete
`ConnectionService` and wires a public mutable callback slot
(`connection_service.dart:96`). Copy gossip_bluey's `MessageDispatcher`
seam: an application-owned dispatcher interface that the port depends
on; `ConnectionService` implements it; the callback slot dies. Also
move gossip_bluey's own dispatcher interface from `infrastructure/` to
`application/` — the seam existed but was homed on the wrong side.

### 4. ARCH3-5 — owned lifecycle enums (bluey)

New owned enums in `gossip_bluey/lib/src/domain/value_objects/`:
`AdvertisingState { idle, advertising }` and
`ScanState { stopped, scanning }` (values mirror the bluey enums the
facade exposes today; exact variant list read from bluey at
implementation time). Translated in `BlueyPortImpl` exactly like the
existing `BluetoothAdapterState` ACL and the `ScanMode`/`AdvertiseMode`
enums added in Batch 1. `BlueyTransport.advertisingState`/`scanState`
return the owned types; the barrel exports them; the example app drops
all four `package:bluey` imports. This is a public-API type change for
gossip_bluey — acceptable, all consumers are in-repo.

### 5. ARCH3-6 — peer persistence honesty (core)

Per owner decision: `PeerService` shrinks to add/remove/query; its doc
(and `PeerRepository`'s) states that SWIM-driven state (status, contact,
metrics) lives only in the in-memory `PeerRegistry` by design and is
never persisted; the false "Used by: Protocol services" claim is
removed. Verify the ChannelService half of this finding (already fixed
per the backlog) still holds and fix any residue.

## TDD posture

- Moves and deletions (ARCH3-2, file moves in ARCH3-3): behavior-neutral
  refactors — the existing suites are the net; no new tests required,
  gates green after every commit.
- New seams (ARCH3-3 dispatch service, ARCH3-4 dispatcher interface,
  ARCH3-5 enum translation): new behavior, test-first — failing test
  demonstrating the seam (e.g. the owned enum reflects the port state;
  the dispatcher routes bytes) before the implementation.
- ARCH3-6: tests covering removed `PeerService` API are removed with it;
  the simplification must not change any passing assertion about
  add/remove/query behavior.

## Out of scope

- ARCH3-1 (port interfaces inward) — Part 2 fixes it in the shared
  kernel move.
- ADR-010 rewrite — Part 2 (one rewrite after both parts).
- Any core-package file moves — Part 2.

## Gates

Full monorepo after every task: `melos run test` + `melos run analyze`
(gossip, gossip_nearby, gossip_bluey all green, analyzers zero).
