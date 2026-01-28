# ADR-005: Dependency Inversion via NearbyPort Interface

## Status

Accepted

## Context

The gossip_nearby package needs to interact with the Nearby Connections platform API (via the `nearby_connections` Flutter plugin). This creates a dependency challenge:

- The domain layer should not depend on infrastructure details
- The application service needs to send/receive data via Nearby Connections
- Unit tests should run without the actual Nearby Connections plugin
- Future changes to the plugin should not ripple through the codebase

Following Domain-Driven Design and Clean Architecture principles, we need to decide where to place the Nearby Connections dependency and how to abstract it.

## Decision

**The domain layer defines a `NearbyPort` interface as an outbound port. The infrastructure layer provides `NearbyAdapter` as the concrete implementation.**

```dart
// Domain layer - defines what it needs
abstract class NearbyPort {
  Future<void> startAdvertising(ServiceId serviceId, String displayName);
  Future<void> stopAdvertising();
  Future<void> startDiscovery(ServiceId serviceId);
  Future<void> stopDiscovery();
  Future<void> requestConnection(EndpointId endpointId);
  Future<void> disconnect(EndpointId endpointId);
  Future<void> sendPayload(EndpointId endpointId, Uint8List bytes);
  Stream<NearbyEvent> get events;
}

// Infrastructure layer - implements using plugin
class NearbyAdapter implements NearbyPort {
  final Nearby _nearby;
  // ... implementation using nearby_connections plugin
}

// Application layer - depends only on interface
class ConnectionService {
  final NearbyPort _nearbyPort;  // Injected, not created
  // ...
}
```

This follows the Dependency Inversion Principle: high-level modules (domain, application) don't depend on low-level modules (infrastructure). Both depend on abstractions (NearbyPort interface).

## Rationale

1. **Testability**: ConnectionService can be tested with a mock NearbyPort
2. **Domain purity**: Domain layer has no `nearby_connections` import
3. **Single change point**: Plugin API changes only affect NearbyAdapter
4. **Clear contract**: Interface documents exactly what the application needs
5. **Swappable implementations**: Could add WebRTC, Bluetooth, or other transports

## Consequences

### Positive

- Complete test coverage without platform dependencies
- Domain/application layers are plugin-agnostic
- Easy to mock for various test scenarios
- Clear architectural boundaries
- Future transport implementations share the same interface

### Negative

- Additional abstraction layer to maintain
- Must keep interface in sync with actual capabilities
- Slightly more indirection in code navigation

### Mitigations

- Interface is small and stable (7 methods + 1 stream)
- Test coverage ensures interface matches usage
- Factory constructors hide wiring complexity from users

## Alternatives Considered

### Direct Plugin Dependency

```dart
class ConnectionService {
  final Nearby _nearby;  // Direct dependency on plugin
}
```

Rejected because:
- Cannot unit test without platform
- Domain/application coupled to infrastructure
- Plugin changes ripple through codebase

### Abstract Factory Pattern

```dart
abstract class NearbyFactory {
  NearbyPort create();
}
```

Rejected because:
- Unnecessary complexity for single implementation
- Port interface is sufficient abstraction
- Factory adds indirection without benefit

### Service Locator

```dart
class ConnectionService {
  final _nearby = ServiceLocator.get<NearbyPort>();
}
```

Rejected because:
- Hides dependencies (not explicit in constructor)
- Harder to trace and test
- Dependency injection is more explicit

## Related Patterns

This ADR implements:
- **Dependency Inversion Principle** (SOLID)
- **Ports and Adapters** (Hexagonal Architecture)
- **Repository Pattern** (for external system access)

The NearbyPort is conceptually similar to how gossip's `MessagePort` abstracts message delivery, and how `EntryRepository` abstracts storage.
