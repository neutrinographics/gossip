# ADR-010: DDD Layered Architecture

## Status

Accepted

## Context

The gossip sync library has multiple concerns:

1. **Domain concepts**: Peers, channels, streams, entries, membership
2. **Protocol logic**: Gossip rounds, failure detection, message encoding
3. **Persistence**: Storing entries and aggregates
4. **Public API**: Simple facade for applications

These concerns need clear separation to enable:
- Testability (unit test each layer independently)
- Flexibility (swap implementations)
- Maintainability (changes isolated to relevant layers)

## Decision

**Organize the codebase into five distinct layers following Domain-Driven Design principles:**

```
┌─────────────────────────────────────────────────────────────┐
│                       FACADE LAYER                          │
│  Coordinator, ChannelFacade, EventStreamFacade              │
│  (Public API - entry point for applications)                │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    APPLICATION LAYER                        │
│  ChannelService, PeerService, CoordinatorSyncService        │
│  (Orchestration - coordinates domain and protocol)          │
└─────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
┌───────────────────┐ ┌───────────────┐ ┌─────────────────────┐
│   DOMAIN LAYER    │ │ PROTOCOL LAYER│ │ INFRASTRUCTURE LAYER│
│  Aggregates       │ │ GossipEngine  │ │ Repositories        │
│  Value Objects    │ │ FailureDetect │ │ Entry Stores        │
│  Domain Events    │ │ ProtocolCodec │ │ Port Adapters       │
│  Interfaces       │ │ Messages      │ │ (Implementations)   │
└───────────────────┘ └───────────────┘ └─────────────────────┘
```

### Layer Responsibilities

**Domain Layer** (`lib/src/domain/`):
- Pure business logic with no external dependencies
- Aggregates: `PeerRegistry`, `ChannelAggregate`
- Value Objects: `NodeId`, `ChannelId`, `StreamId`, `LogEntry`, `VersionVector`, `HLC`
- Domain Events: `EntryAppended`, `PeerJoined`, `SyncErrorOccurred`
- Interfaces: `EntryRepository`, `ChannelRepository`, `PeerRepository`

**Protocol Layer** (`lib/src/protocol/`):
- Gossip protocol implementation
- `GossipEngine`: Anti-entropy sync (ADR-008)
- `FailureDetector`: SWIM protocol (ADR-004)
- `ProtocolCodec`: Message serialization
- Protocol messages: `DigestRequest`, `DeltaResponse`, `Ping`, `Ack`

**Infrastructure Layer** (`lib/src/infrastructure/`):
- Concrete implementations of domain interfaces
- `InMemoryEntryRepository`, `InMemoryChannelRepository`
- Port implementations: `MessagePort`, `TimePort`
- Future: Persistent storage implementations

**Application Layer** (`lib/src/application/`):
- Orchestrates domain operations and protocol
- `ChannelService`: Channel lifecycle and operations
- `PeerService`: Peer management
- `CoordinatorSyncService`: Coordinates sync lifecycle

**Facade Layer** (`lib/src/facade/`):
- Public API for application developers
- `Coordinator`: Main entry point
- `ChannelFacade`: Channel operations
- `EventStreamFacade`: Stream operations
- Hides internal complexity

## Rationale

1. **Separation of concerns**: Each layer has a single responsibility. Domain knows nothing about protocol; protocol knows nothing about persistence.

2. **Dependency direction**: Dependencies flow inward. Infrastructure depends on domain interfaces; domain depends on nothing.

3. **Testability**: Each layer can be unit tested in isolation:
   - Domain: Pure functions, no mocks needed
   - Protocol: Mock MessagePort and TimePort
   - Infrastructure: Test against interfaces
   - Facade: Integration tests

4. **Flexibility**: Implementations can be swapped:
   - Different storage backends
   - Different transport mechanisms
   - Different serialization formats

5. **Domain protection**: Business rules are protected in the domain layer, not scattered across the codebase.

## Consequences

### Positive

- **Clear boundaries**: Easy to understand where code belongs
- **Independent evolution**: Change one layer without affecting others
- **Reusable domain**: Domain logic can be used in different contexts
- **Testable**: Unit test each layer independently
- **Maintainable**: New developers can learn one layer at a time

### Negative

- **More files**: Separation creates more directories and files
- **Indirection**: Calls may pass through multiple layers
- **Mapping**: May need to map between layer-specific representations

### Directory Structure

```
lib/src/
├── domain/
│   ├── aggregates/      # PeerRegistry, ChannelAggregate
│   ├── entities/        # Peer, StreamConfig, PeerMetrics
│   ├── value_objects/   # NodeId, ChannelId, LogEntry, HLC, VersionVector
│   ├── events/          # DomainEvent hierarchy
│   ├── errors/          # DomainException, SyncError
│   ├── interfaces/      # Repository interfaces
│   ├── services/        # HlcClock, TimeSource
│   └── results/         # Digest, MergeResult, CompactionResult
│
├── protocol/
│   ├── messages/        # DigestRequest/Response, DeltaRequest/Response, Ping, Ack
│   ├── values/          # ChannelDigest, StreamDigest
│   ├── gossip_engine.dart
│   ├── failure_detector.dart
│   └── protocol_codec.dart
│
├── application/
│   ├── services/        # ChannelService, PeerService
│   ├── interfaces/      # SyncCoordinatorService
│   └── coordinator_sync_service.dart
│
├── infrastructure/
│   ├── repositories/    # InMemoryChannelRepository, InMemoryPeerRepository
│   ├── stores/          # InMemoryEntryRepository
│   └── ports/           # MessagePort, TimePort implementations
│
└── facade/
    ├── coordinator.dart
    ├── channel.dart
    ├── event_stream.dart
    ├── coordinator_config.dart
    ├── health_status.dart
    ├── resource_usage.dart
    └── sync_state.dart
```

### Dependency Rules

1. **Domain layer**: No dependencies on other layers
2. **Protocol layer**: Depends on domain (uses value objects, interfaces)
3. **Infrastructure layer**: Depends on domain (implements interfaces)
4. **Application layer**: Depends on domain, protocol, infrastructure
5. **Facade layer**: Depends on all layers (orchestrates everything)

### Interface Segregation

Domain defines interfaces; infrastructure implements:

```dart
// Domain layer defines interface
abstract class EntryRepository {
  void append(ChannelId channel, StreamId stream, LogEntry entry);
  List<LogEntry> entriesSince(ChannelId channel, StreamId stream, VersionVector since);
  VersionVector getVersionVector(ChannelId channel, StreamId stream);
}

// Infrastructure layer implements
class InMemoryEntryRepository implements EntryRepository {
  // Implementation details hidden from domain
}
```

## Alternatives Considered

### Flat Structure

All code in one directory:
- Simple for small projects
- But becomes unmaintainable as codebase grows
- Hard to enforce boundaries

### Hexagonal Architecture

Ports and adapters at the center:
- More explicit about external integrations
- But adds complexity for this use case
- DDD layers are more natural for domain-heavy library

### Clean Architecture

Strict concentric circles:
- Very explicit dependency rules
- But more rigid than needed
- DDD provides similar benefits with more flexibility

### Feature-Based Organization

Organize by feature (peers, channels, sync):
- Good for large applications
- But harder to enforce layer boundaries
- Domain concepts span features
