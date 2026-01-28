# ADR-003: Error Streaming Pattern

## Status

Accepted

## Context

The gossip_nearby package encounters various recoverable errors during operation:

- Connection not found when sending a message
- Handshake timeout waiting for peer's NodeId
- Invalid handshake data received
- Send failures due to network issues
- Unexpected disconnections

These errors are expected during normal operation - networks are unreliable, peers come and go, and connections drop. The question is how to surface these errors to applications:

1. **Throw exceptions**: Interrupt the current operation
2. **Return Result types**: Force caller to handle success/failure
3. **Callback-based**: Register error handlers
4. **Stream-based**: Emit errors as events on a stream

The gossip library uses a stream-based pattern for its `Coordinator.errors`, exposing `SyncError` events.

## Decision

**Connection errors are emitted as events on a stream (`NearbyTransport.errors`) rather than thrown as exceptions.** This matches the gossip library's `Coordinator.errors` pattern for API consistency.

```dart
// In ConnectionService
_errorController.add(
  ConnectionNotFoundError(
    destination,
    'No active connection for peer',
    occurredAt: DateTime.now(),
  ),
);

// In NearbyTransport (facade)
Stream<ConnectionError> get errors => _connectionService.errors;

// Application usage
transport.errors.listen((error) {
  switch (error) {
    case ConnectionNotFoundError(:final nodeId):
      logger.warn('No connection to $nodeId');
    case SendFailedError(:final nodeId, :final cause):
      logger.error('Send failed to $nodeId', cause);
    // ...
  }
});
```

## Rationale

1. **Consistency with gossip**: Applications using both libraries have a uniform error handling pattern
2. **Non-blocking**: Errors don't interrupt the happy path - send() returns normally, error is reported separately
3. **Recoverable by design**: These errors are expected, not exceptional - treating them as events reflects this
4. **Observability-friendly**: Easy to log all errors, aggregate metrics, or implement retry policies
5. **Composable**: Streams can be filtered, transformed, combined with other streams
6. **Decoupled**: Error producers don't need to know about error consumers

## Consequences

### Positive

- Consistent API with gossip library
- Clean separation between operation and error handling
- Easy to implement cross-cutting concerns (logging, metrics)
- Callers don't need try/catch for expected failures
- Multiple listeners can observe the same error stream

### Negative

- Errors can be silently ignored if stream isn't listened to
- Harder to associate errors with specific operations
- No stack trace at call site (error originates from stream emission)
- Requires understanding stream semantics

### Mitigations

- Document that applications should listen to the error stream
- Include `occurredAt` timestamp for correlation with operations
- Include `cause` field for original exceptions when available
- Error types include context (nodeId, endpointId) for identification

## Alternatives Considered

### Throw Exceptions

```dart
Future<void> send(NodeId destination, Uint8List bytes) async {
  if (!isConnected(destination)) {
    throw ConnectionNotFoundError(destination);
  }
  // ...
}
```

Rejected because:
- Exceptions are for unexpected conditions, not expected failures
- Interrupts async flows unnecessarily
- Inconsistent with gossip library's pattern
- Harder to implement retry policies

### Return Result Types

```dart
Future<Result<void, ConnectionError>> send(...) async {
  // ...
}
```

Rejected because:
- Dart doesn't have built-in Result type
- Forces every caller to handle errors inline
- Doesn't support multiple error observers
- Verbose at call sites

### Callback-Based

```dart
NearbyTransport({
  required void Function(ConnectionError) onError,
});
```

Rejected because:
- Only one error handler at a time
- Less composable than streams
- Inconsistent with stream-based event pattern already in use
