# ADR-001: Single-Isolate Execution Model

## Status

Accepted

## Context

Dart supports concurrent execution through isolates, which are independent workers with their own memory heap. When designing the gossip sync library, we needed to decide how to handle concurrency:

1. **Multi-isolate with message passing**: Allow Coordinator to be accessed from multiple isolates, using ports for communication
2. **Multi-isolate with shared memory**: Use experimental shared memory features (not stable in Dart)
3. **Single-isolate execution**: Require all Coordinator operations to run in one isolate

The library targets mobile-first applications (Flutter) where:
- UI runs on the main isolate
- Background work can use additional isolates
- Network I/O is typically async but single-threaded

## Decision

**All Coordinator operations must run in the same Dart isolate.** The library does not use locks, mutexes, or synchronization primitives.

## Rationale

1. **Simplicity**: No synchronization complexity, no race conditions, no deadlocks
2. **Performance**: No lock contention overhead
3. **Dart idioms**: Follows Dart's async/await model rather than fighting it
4. **Mobile fit**: Flutter apps typically coordinate state on the main isolate anyway
5. **Predictability**: Easier to reason about state changes and event ordering

## Consequences

### Positive

- Simpler codebase with no concurrency bugs
- Easier testing (no need to test race conditions)
- Better performance for typical use cases
- Clear mental model for library users

### Negative

- Applications needing multi-isolate access must implement their own coordination
- Heavy computation (e.g., large payload processing) blocks the isolate
- Cannot leverage multiple CPU cores for library operations

### Mitigations

- Applications can use separate isolates for heavy payload transformation before/after calling the library
- The library's operations are designed to be fast (sub-millisecond for typical operations)
- EntryRepository implementations can use isolates internally if needed for I/O

## Alternatives Considered

### Multi-isolate with SendPort/ReceivePort

Would allow calling Coordinator from any isolate, but:
- Adds significant complexity
- All calls become async message passing
- Debugging becomes harder
- Not needed for target use cases

### Actor model

Could model Coordinator as an actor with a message queue, but:
- Overengineered for the problem
- Dart doesn't have native actor support
- Adds latency to every operation
