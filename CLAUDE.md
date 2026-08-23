# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Practices

**Mandatory workflow for all changes:**
1. **TDD (Red-Green-Refactor)**: Write failing tests first, implement minimum code to pass, then refactor
2. **DDD + Clean Architecture**: Strict layer separation with dependencies pointing inward
3. **Clean Code**: Refactor all code to be readable and maintainable
4. **No silent errors**: All errors must be logged or emitted via `ErrorCallback`. Never silently catch and ignore exceptions.

## Build & Development Commands

This is a Dart monorepo managed with [Melos](https://melos.invertase.dev/).

```bash
# Setup
dart pub get && melos bootstrap

# Run all tests across packages
melos run test

# Run tests in a specific package
cd packages/gossip && dart test
cd packages/gossip_nearby && flutter test

# Run a single test file
dart test test/sync/application/gossip_engine_test.dart

# Run tests with name filter
dart test --name "test name pattern"

# Static analysis (all packages)
melos run analyze

# Format (all packages)
melos run format

# Run command in specific package
melos exec --scope="gossip_nearby" -- flutter test
```

## Monorepo Structure

| Package | Type | Description |
|---------|------|-------------|
| `packages/gossip` | Pure Dart | Core gossip protocol - sync engine, SWIM failure detection, HLC |
| `packages/gossip_nearby` | Flutter | Nearby Connections transport (Android) - peer discovery and message delivery |
| `packages/gossip_bluey` | Flutter | BLE transport (Android + iOS) on top of the bluey library - supports mesh and star topologies |

## Architecture Overview

The core package (`gossip`) and the transport packages follow different
architectures — see ADR-010 for the core package's rationale.

**Core package (`gossip`)** is organized as **bounded contexts** (concept-first
modules, not DDD layers):

```
lib/src/
  shared/        # kernel — true leaf; imports nothing outside itself
  sync/          # anti-entropy replication of the event log (channels, streams, entries)
  membership/    # SWIM liveness: peer model + the detector that maintains it
  coordinator/   # facade shell / composition root (not a bounded context)
```

**Boundary rule**: a context may import `shared/` and itself — nothing else.
The single exception: a context's `infrastructure/` layer may import another
context, as a concession, to implement an adapter for an interface its own
domain defines. Today the only exercised concession is
`sync/infrastructure/membership_peer_directory.dart` (`MembershipPeerDirectory`),
sync's anti-corruption layer over membership's `PeerRegistry`. Machine-checked
by `packages/gossip/test/architecture/boundary_test.dart`.

**Transport packages** (`gossip_nearby`, `gossip_bluey`) stay **layer-first,
single-context packages**:

```
Facade Layer         → Public API (NearbyTransport, BlueyTransport)
Application Layer    → Use case orchestration (services)
Domain Layer         → Pure business logic (aggregates, entities, value objects)
Protocol Layer       → Wire protocols (codecs, dispatchers)
Infrastructure Layer → External adapters (platform integration)
```

**Dependency rule** (transports): Dependencies point inward. Domain has no
external dependencies. Infrastructure implements domain interfaces (ports).

## Core Package (gossip)

Synchronizes event streams across devices using anti-entropy gossip protocol.

**Key components:**
- `Coordinator` (`coordinator/`): Main entry point, manages sync lifecycle
- `GossipEngine` (`sync/application/`): Gossip round scheduling, digest/delta exchange
- `FailureDetector` (`membership/application/`): SWIM protocol for peer health
- `Channel` (aggregate in `sync/domain/aggregates/`, facade in `coordinator/`): Sync group with membership
- `HlcClock` (`sync/domain/services/`): Hybrid logical clock for causal ordering
- `MessagePort` (`shared/domain/interfaces/`): Transport abstraction - app provides implementation

**Design constraints:**
- Single-isolate execution (no locks, accessing from multiple isolates causes corruption)
- 32KB payload limit (Android Nearby Connections compatibility)
- Up to 8 devices per channel recommended

## Nearby Package (gossip_nearby)

Implements `MessagePort` using Android/iOS Nearby Connections.

**Key components:**
- `NearbyTransport` (facade): Lifecycle and component wiring
- `ConnectionService` (application): Handshake orchestration, message routing
- `ConnectionRegistry` (domain aggregate): Enforces NodeId → EndpointId uniqueness
- `NearbyAdapter` (infrastructure): Platform integration via `nearby_connections`
- `HandshakeCodec` (protocol): Binary wire format
- `WireDispatcher` (protocol): Classifies inbound bytes into a `MessageType` — the only place outside `HandshakeCodec` that reads wire byte offsets

**Handshake protocol:**
```
Device A                     Device B
    │── Connection Established ──►│
    │── Handshake(NodeId-A) ─────►│
    │◄── Handshake(NodeId-B) ─────│
    │   [Ready for gossip]        │
```

## Bluey Package (gossip_bluey)

Implements `MessagePort` using BLE via the [bluey](https://github.com/neutrinographics/bluey) library.

**Key components:**
- `BlueyTransport` (facade): Lifecycle, advertising/discovery toggles, peer events
- `ConnectionManager` / `AutoConnectPolicy` (application): connection registry + send/receive paths; discovery-driven auto-connect with per-address backoff and caps
- `ConnectionRegistry` (domain aggregate): One handle per NodeId
- `BlueyPort` (domain interface): Adapter abstraction; `BlueyPortImpl` wraps the real `Bluey` instance
- `FrameEncoder`/`FrameDecoder` (protocol): 4-byte length-prefix framing for chunked BLE writes

**Identity model:** `NodeId.value` is fed directly into bluey's `ServerId` — no handshake required for the initiator's view of the responder. (See spec for the known peripheral-side limitation when running on real hardware.)

**Topologies supported via composable primitives:**
- **Mesh:** every device calls both `startAdvertising()` and `startDiscovery()`. A mutual connect briefly holds two links; the post-connect tie-break (smaller `NodeId.value` stays central; the loser closes its own central link) converges every pair to one physical link.
- **Star:** hub calls `startAdvertising()` only; spokes call `startDiscovery()` only — spokes can only ever find the hub because nothing else advertises.

## Key Design Decisions (ADRs)

| ADR | Decision |
|-----|----------|
| 001 | Single-isolate execution - no thread synchronization |
| 002 | Entry storage separate from aggregates (via `EntryRepository`) |
| 003 | Payload-agnostic - library syncs opaque bytes |
| 004 | SWIM protocol for failure detection |
| 005 | Hybrid Logical Clocks for ordering |
| 006 | Transport and discovery external to library |
| 008 | Anti-entropy gossip with digest/delta exchange |
| 011 | ErrorCallback pattern for recoverable errors |

Full ADRs in `packages/gossip/docs/adr/`.
