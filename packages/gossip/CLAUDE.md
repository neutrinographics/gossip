# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Dart library (`gossip`) for synchronizing event streams across devices using gossip protocols. It's designed for mobile-first, offline-capable applications with sub-second convergence.

## Build & Development Commands

```bash
# Get dependencies
dart pub get

# Run all tests (262 tests currently)
dart test

# Run a single test file
dart test test/protocol/gossip_engine_test.dart

# Run tests with name filter
dart test --name "test name pattern"

# Analyze code (linting)
dart analyze

# Format code
dart format lib test
```

## Development Practices

- **Strict TDD**: All changes must follow Test-Driven Development:
  1. Write failing tests first (Red)
  2. Implement minimum code to pass tests (Green)
  3. Refactor while keeping tests passing (Refactor)
- **No silent errors**: All errors must be logged or emitted via `ErrorCallback`. Never silently catch and ignore exceptions.
- **Run tests after every change**: Use `dart test` to verify all tests pass before committing.

## Architecture

The library follows strict DDD (Domain-Driven Design) with four layers:

### 1. Domain Layer (`lib/src/domain/`)
Pure business logic with no external dependencies:
- **Aggregates**: `PeerRegistry`, `Channel` - event-sourced domain entities
- **Value Objects**: `NodeId`, `ChannelId`, `StreamId`, `LogEntry`, `HLC`, `VersionVector`
- **Entities**: `Peer`, `PeerMetrics`, `StreamConfig`
- **Events**: `DomainEvent` and subclasses (e.g., `PeerOperationSkipped`)
- **Errors**: `SyncError` sealed class with `ErrorCallback` pattern
- **Interfaces**: `ChannelRepository`, `PeerRepository`, `EntryRepository`, `RetentionPolicy`
- **Services**: `HlcClock`, `TimeSource`

### 2. Application Services Layer (`lib/src/application/`)
Orchestrates domain logic:
- `ChannelService` - Channel lifecycle and entry management
- `PeerService` - Peer lifecycle and persistence

### 3. Protocol Layer (`lib/src/protocol/`)
Gossip protocol implementation:
- `GossipEngine` - Gossip round scheduling and anti-entropy sync
- `FailureDetector` - SWIM protocol for peer liveness detection
- `ProtocolCodec` - Binary message encoding/decoding
- **Messages**: `Ping`, `Ack`, `PingReq`, `DigestRequest`, `DigestResponse`, `DeltaRequest`, `DeltaResponse`
- **Values**: `ChannelDigest`, `StreamDigest`

### 4. Infrastructure Layer (`lib/src/infrastructure/`)
Concrete implementations:
- **Repositories**: `InMemoryChannelRepository`, `InMemoryPeerRepository`, `InMemoryEntryRepository`
- **Ports**: `MessagePort`, `TimePort` (interfaces and in-memory implementations)

## Key Design Principles

- **Single-isolate execution**: All operations must run in the same Dart isolate. No locks or synchronization primitives.
- **Payload-agnostic**: Library syncs opaque bytes; application defines semantics.
- **Transport-external**: Library defines `MessagePort` interface; application provides implementation.
- **Discovery-external**: Library doesn't find peers; application tells library about peers.
- **Entry storage separation**: Entries stored via `EntryRepository` interface, not in-memory with aggregates.
- **Error emission**: Use `ErrorCallback` pattern for non-fatal errors instead of throwing.

## Code Structure

```
lib/
  gossip.dart                    # Public exports
  src/
    domain/
      aggregates/                # PeerRegistry, Channel
      entities/                  # Peer, PeerMetrics, StreamConfig
      errors/                    # SyncError, DomainException
      events/                    # DomainEvent classes
      interfaces/                # Repository and store interfaces
      results/                   # Digest, MergeResult, etc.
      services/                  # HlcClock, TimeSource
      value_objects/             # NodeId, ChannelId, LogEntry, etc.
    application/
      services/                  # ChannelService, PeerService
    protocol/
      messages/                  # Protocol message types
      values/                    # ChannelDigest, StreamDigest
      gossip_engine.dart
      failure_detector.dart
      protocol_codec.dart
    infrastructure/
      repositories/              # In-memory repository implementations
      stores/                    # InMemoryEntryRepository
      ports/                     # MessagePort, TimePort implementations
test/
  domain/                        # Domain layer tests
  application/                   # Service tests
  protocol/                      # Protocol tests
  infrastructure/                # Infrastructure tests
  integration/                   # Two-node sync/failure detection tests
```

## Target Constraints

- Up to 8 devices per channel (configurable)
- 32KB payload limit (Android Nearby Connections compatibility)
- Sub-second convergence (~150ms typical)
