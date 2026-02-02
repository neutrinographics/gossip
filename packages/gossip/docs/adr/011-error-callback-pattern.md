# ADR-011: Error Callback Pattern for Recoverable Errors

## Status

Accepted

## Context

The library encounters various error conditions during operation:

1. **Fatal errors**: Invalid configuration, lifecycle violations (e.g., starting when already running)
2. **Recoverable errors**: Network timeouts, malformed messages, temporary storage failures

How should these errors be surfaced to applications?

**Option A: Throw exceptions**
- Simple and familiar
- But async operations make catching difficult
- Background tasks can't throw to caller

**Option B: Return Result types**
- Explicit error handling
- But verbose for Dart idioms
- Doesn't work for background operations

**Option C: Error callbacks/streams**
- Async-friendly
- Works for background operations
- Application decides handling strategy

## Decision

**Use a two-tier error handling strategy:**

1. **Fatal errors**: Throw `StateError` synchronously for lifecycle/configuration violations
2. **Recoverable errors**: Emit via `ErrorCallback` and surface through `Coordinator.events` stream

```dart
// Fatal: throws immediately
coordinator.start(); // Already running
// Throws: StateError('Coordinator is already running')

// Recoverable: emitted through callback/stream
// Network failure during gossip round
// Emits: PeerSyncError(peer, SyncErrorType.peerUnreachable, ...)
coordinator.events.listen((event) {
  if (event is SyncErrorOccurred) {
    // Handle or log the error
  }
});
```

### Error Hierarchy

```dart
// Base class for recoverable sync errors
sealed class SyncError {
  final String message;
  final DateTime occurredAt;
}

// Specific error types
final class PeerSyncError extends SyncError {
  final NodeId peer;
  final SyncErrorType type;
  final Object? cause;
}

final class ChannelSyncError extends SyncError {
  final ChannelId channel;
  final SyncErrorType type;
}

final class StorageSyncError extends SyncError {
  final SyncErrorType type;
}

final class BufferOverflowError extends SyncError {
  final ChannelId channel;
  final StreamId stream;
  final NodeId author;
  final int bufferSize;
}
```

### Error Callback Pattern

Internal components accept an optional `ErrorCallback`:

```dart
typedef ErrorCallback = void Function(SyncError error);

class GossipEngine {
  final ErrorCallback? onError;
  
  GossipEngine({this.onError, ...});
  
  void _handleMalformedMessage(Object error) {
    onError?.call(
      PeerSyncError(
        sender,
        SyncErrorType.messageCorrupted,
        'Malformed message: $error',
        occurredAt: DateTime.now(),
        cause: error,
      ),
    );
  }
}
```

## Rationale

1. **Async compatibility**: Background gossip rounds can't throw to the caller. Callbacks propagate errors without blocking.

2. **Non-fatal by default**: Most sync errors are transient. The library continues operating; apps decide if action is needed.

3. **Observability**: All errors are surfaced via the events stream. Applications can log, alert, or implement retry policies.

4. **DoS prevention**: Malformed messages from malicious peers emit errors but don't crash the application.

5. **Clear contracts**: Fatal errors are documented as throwing. Recoverable errors are documented as events.

## Consequences

### Positive

- **Resilient**: Library continues operating despite errors
- **Observable**: All errors visible through events stream
- **Flexible**: Applications decide handling strategy
- **Testable**: Can verify error emission in tests
- **Async-safe**: Works with background operations

### Negative

- **Easy to ignore**: Applications might not subscribe to errors
- **Delayed visibility**: Errors may not be noticed immediately
- **More complex API**: Two error paths to understand

### Error Type Classification

| Error Type | Handling | Example |
|------------|----------|---------|
| `peerUnreachable` | Retry on next round | Network timeout |
| `peerTimeout` | Retry on next round | Slow peer |
| `messageCorrupted` | Log and ignore | Invalid bytes |
| `messageTooLarge` | Log and ignore | >32KB message |
| `storageFailure` | May need intervention | Disk I/O error |
| `storageFull` | Needs intervention | Out of space |
| `bufferOverflow` | Log, may rate-limit | Too many OOO entries |
| `protocolError` | Log and continue | Version mismatch |

### When to Throw vs Emit

**Throw `StateError`:**
- `start()` when already running
- `stop()` when not running
- Operations on disposed coordinator
- Invalid configuration at construction

**Emit `SyncError`:**
- Network failures
- Malformed messages
- Storage errors during sync
- Buffer overflows
- Protocol violations

### Integration Example

```dart
final coordinator = Coordinator(...);

// Subscribe to all events including errors
coordinator.events.listen((event) {
  switch (event) {
    case SyncErrorOccurred(error: var error):
      _logger.warning('Sync error: ${error.message}');
      if (error is StorageSyncError && error.type == SyncErrorType.storageFull) {
        _alertOperator('Storage full - sync paused');
      }
    case EntryAppended(entry: var entry):
      _handleNewEntry(entry);
    // ... handle other events
  }
});

// Start syncing - throws if already running
try {
  coordinator.start();
} on StateError catch (e) {
  _logger.error('Failed to start: $e');
}
```

### Error Propagation Chain

```
GossipEngine                    ChannelService               Coordinator
     │                               │                           │
     │ onError callback              │ onError callback          │ _eventController
     │ ────────────────────────────> │ ─────────────────────────>│ ──────> events stream
     │                               │                           │           │
     │ PeerSyncError                 │ ChannelSyncError          │           ▼
     │                               │                           │    Application
```

## Alternatives Considered

### Result Types

Return `Result<T, SyncError>` from all operations:
- Explicit error handling
- But verbose in Dart
- Doesn't work for void operations
- Doesn't work for background tasks

### Zone-Based Error Handling

Use Dart zones to catch all errors:
- Automatic propagation
- But too magical
- Hard to test
- Loses error context

### Log-Only Errors

Log errors internally, don't expose:
- Simplest API
- But applications can't react
- No observability
- Bad for production debugging

### Crash on Error

Treat all errors as fatal:
- Simple and obvious
- But too brittle for distributed systems
- One bad message shouldn't crash the app
