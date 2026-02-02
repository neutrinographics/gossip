# ADR-003: Payload-Agnostic Design

## Status

Accepted

## Context

The library synchronizes event streams across devices. Each entry in a stream has a payload - the actual data being synchronized. We needed to decide how much the library should know about payload contents:

1. **Typed payloads**: Library defines payload types (JSON, protobuf, specific schemas)
2. **Payload-aware**: Library parses payloads for conflict resolution
3. **Payload-agnostic**: Library treats payloads as opaque bytes

Applications using the library might sync:
- Chat messages (text, JSON)
- Document operations (OT, CRDT)
- Game state (binary)
- Sensor data (custom formats)

## Decision

**The library treats payloads as opaque `Uint8List` bytes.** It does not parse, validate, or transform payload contents. The application defines payload semantics.

```dart
// Library sees this:
class LogEntry {
  final Uint8List payload;  // Opaque bytes
  // ...
}

// Application interprets as:
final message = ChatMessage.fromBytes(entry.payload);
```

## Rationale

1. **Flexibility**: Any serialization format works (JSON, protobuf, msgpack, custom)
2. **Separation of concerns**: Sync mechanics vs data semantics
3. **Performance**: No parsing overhead in the library
4. **Simplicity**: Library doesn't need schema management
5. **Future-proof**: New formats don't require library changes

## Consequences

### Positive

- Works with any data format
- No serialization dependencies in library
- Applications control their own schema evolution
- Smaller library footprint
- Easier to test (no schema validation)

### Negative

- Applications must handle serialization themselves
- No built-in conflict resolution for payload contents
- Payload size limits not enforced (application responsibility)
- No type safety across the wire

### Design Principle

> The library provides sync mechanics. The application provides sync policy.

This applies to:
- **Payload format**: Application chooses (JSON, protobuf, etc.)
- **Conflict resolution**: Application implements (last-write-wins, merge, etc.)
- **Validation**: Application validates payload contents
- **Encryption**: Application encrypts before passing to library

### Payload Size Limit

The library does enforce a 32KB payload limit for protocol compatibility with Android Nearby Connections. This is a transport constraint, not a semantic one.

## Alternatives Considered

### JSON-Only

Require all payloads to be JSON:
- Simpler debugging
- But excludes binary formats
- Performance overhead for parsing

### Schema Registry

Library manages payload schemas:
- Type safety
- But complex to implement
- Version compatibility issues
- Tight coupling with applications

### CRDT-Aware

Library understands CRDT types for automatic merge:
- Automatic conflict resolution
- But limits flexibility
- Complex implementation
- Not all data fits CRDT model
