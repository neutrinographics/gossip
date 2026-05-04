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
dart test test/protocol/gossip_engine_test.dart

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

Both packages follow **DDD Layered Architecture** (see ADR-010):

```
Facade Layer         → Public API (Coordinator, NearbyTransport)
Application Layer    → Use case orchestration (services)
Domain Layer         → Pure business logic (aggregates, entities, value objects)
Protocol Layer       → Wire protocols (gossip only: GossipEngine, FailureDetector)
Infrastructure Layer → External adapters (repositories, ports)
```

**Dependency rule**: Dependencies point inward. Domain has no external dependencies. Infrastructure implements domain interfaces (ports).

## Core Package (gossip)

Synchronizes event streams across devices using anti-entropy gossip protocol.

**Key components:**
- `Coordinator` (facade): Main entry point, manages sync lifecycle
- `GossipEngine` (protocol): Gossip round scheduling, digest/delta exchange
- `FailureDetector` (protocol): SWIM protocol for peer health
- `Channel` (domain aggregate): Sync group with membership
- `HlcClock` (domain service): Hybrid logical clock for causal ordering
- `MessagePort` (interface): Transport abstraction - app provides implementation

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
- `HandshakeCodec` (infrastructure): Binary wire format

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
- `ConnectionService` (application): Discovery + tie-break, soft/hard caps, adaptive scan, per-NodeId backoff, send/receive paths
- `ConnectionRegistry` (domain aggregate): One handle per NodeId
- `BlueyPort` (domain interface): Adapter abstraction; `BlueyPortImpl` wraps the real `Bluey` instance
- `FrameEncoder`/`FrameDecoder` (infrastructure): 4-byte length-prefix framing for chunked BLE writes

**Identity model:** `NodeId.value` is fed directly into bluey's `ServerId` — no handshake required for the initiator's view of the responder. (See spec for the known peripheral-side limitation when running on real hardware.)

**Topologies supported via composable primitives:**
- **Mesh:** every device calls both `startAdvertising()` and `startDiscovery()`. Tie-break by `NodeId.value` ensures one initiator per pair.
- **Star:** hub calls `startAdvertising()` only; spokes call `startDiscovery(filter: hubId)` only.

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
