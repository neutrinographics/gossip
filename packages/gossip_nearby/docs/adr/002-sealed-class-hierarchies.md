# ADR-002: Sealed Class Hierarchies for Exhaustive Pattern Matching

## Status

Accepted

## Context

The gossip_nearby package has several type hierarchies representing different kinds of errors and events:

- `ConnectionError`: Errors during connection lifecycle
- `ConnectionEvent`: Domain events from connection state changes
- `NearbyEvent`: Low-level events from Nearby Connections
- `PeerEvent`: High-level peer state changes for applications

When processing these types, code typically uses pattern matching to handle each variant. In Dart, there are several ways to model such hierarchies:

1. Abstract base class with open inheritance
2. Enum with associated values (limited in Dart)
3. Sealed class with final subclasses

## Decision

**Use Dart's `sealed` class modifier for all error and event hierarchies, with `final` concrete subclasses.**

```dart
sealed class ConnectionError {
  final String message;
  final DateTime occurredAt;
  final ConnectionErrorType type;
  final Object? cause;
  // ...
}

final class ConnectionNotFoundError extends ConnectionError { ... }
final class HandshakeTimeoutError extends ConnectionError { ... }
final class HandshakeInvalidError extends ConnectionError { ... }
final class SendFailedError extends ConnectionError { ... }
final class ConnectionLostError extends ConnectionError { ... }
```

## Rationale

1. **Exhaustiveness checking**: The compiler verifies all cases are handled in switch statements
2. **Closed hierarchy**: Third-party code cannot add new variants, ensuring library control
3. **Type safety**: Each error/event type can have different properties while sharing a common interface
4. **Self-documenting**: The sealed modifier explicitly communicates design intent
5. **Refactoring safety**: Adding a new variant causes compile errors at all switch sites

Example of exhaustive pattern matching:
```dart
switch (error) {
  case ConnectionNotFoundError(:final nodeId):
    // Handle missing connection
  case HandshakeTimeoutError(:final endpointId):
    // Handle timeout
  case HandshakeInvalidError(:final endpointId):
    // Handle invalid data
  case SendFailedError(:final nodeId):
    // Handle send failure
  case ConnectionLostError(:final nodeId):
    // Handle disconnection
}
// No default case needed - compiler ensures exhaustiveness
```

## Consequences

### Positive

- Impossible to forget handling a new error/event type
- Clear contract about what variants exist
- Better IDE support with exhaustiveness warnings
- Self-documenting code intent
- Safe to add new variants (compiler guides updates)

### Negative

- Cannot be extended by consuming applications
- Slightly more verbose than open hierarchies
- Requires Dart 3.0+ (sealed classes feature)

### Mitigations

- Applications needing custom error types can wrap ConnectionError
- The closed hierarchy is intentional - prevents unexpected variants
- Dart 3.0 is widely adopted

## Alternatives Considered

### Abstract Base Class with Open Inheritance

```dart
abstract class ConnectionError { ... }
class ConnectionNotFoundError extends ConnectionError { ... }
// Third-party could add: class CustomError extends ConnectionError { ... }
```

Rejected because:
- No exhaustiveness checking - switch requires default case
- Third-party extensions could break library assumptions
- Harder to reason about all possible error types

### Enum with Associated Values

Dart enums have limited support for associated values compared to languages like Swift or Rust.

Rejected because:
- Each error type needs different properties (nodeId vs endpointId)
- Would require awkward nullable fields or separate data classes
- Less idiomatic in Dart

### Union Types (Not Available)

Dart doesn't have first-class union types like TypeScript.

Not applicable - sealed classes are Dart's solution for this pattern.
