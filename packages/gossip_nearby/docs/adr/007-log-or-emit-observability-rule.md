# ADR-007: Log-or-Emit Observability Rule

## Status

Accepted

## Context

During the hardening audit (Phase 2), we found many places where an error was both logged at the source and emitted as an event on a stream. Since the stream consumer (the application) also logs when it receives the event, this produced duplicate log entries for the same error — one from the library internals and one from the application's listener.

For example, in `ConnectionService`, a send failure would:
1. `_log(LogLevel.error, 'Send failed to $destination', e, stack)` — logged at the source
2. `_errorController.add(SendFailedError(...))` — emitted on the error stream
3. The application's `errors.listen((error) { logger.error(error); })` — logged again by the consumer

Similarly, in `NearbyAdapter`, event callbacks would log a message and then emit a `NearbyEvent`. Since `ConnectionService` logs when it processes each event, the same occurrence appeared in logs twice.

This made logs noisy and harder to read — the same failure appeared at multiple layers with different formatting, making it unclear whether one or two things went wrong.

## Decision

**At any given point in the code, either log the occurrence or emit it as an event/error, never both.**

The rule is:

1. **If an event or error is emitted on a stream**, do not log at the emission site. The stream consumer is responsible for logging.
2. **If no event or error is emitted** (internal concerns, cleanup failures, scheduling errors), log at the source — this is the only place the information will be captured.

### Where to log (no event exists)

- Adapter: platform call failures in `stopAdvertising`/`stopDiscovery` (teardown, no consumer action)
- ConnectionService: retry timer failures, event handler safety net, disconnect of replaced endpoints
- Facade: `disconnectAll` per-iteration failures

### Where to emit (no log)

- ConnectionService: `HandshakeTimeoutError`, `SendFailedError`, `ConnectionNotFoundError`, `HandshakeInvalidError`, `ConnectionLostError`
- NearbyAdapter: `ConnectionEstablished`, `ConnectionFailed`, `EndpointDiscovered`, `EndpointLost`, `Disconnected`

### Special case: adapter start failures

The adapter logs platform errors from `startAdvertising`/`startDiscovery` with full detail (exception, stack trace) and then rethrows. The facade catches the rethrown error but does not add its own log — the adapter's log is the single source of truth. This is not "log and emit" because the rethrow is control flow, not an event emission.

## Rationale

1. **No duplicate log entries**: Each occurrence appears exactly once in logs
2. **Clear ownership**: The component closest to the source of truth is responsible for observability
3. **Layered correctly**: Infrastructure logs platform-specific details; application-layer events carry domain-meaningful information
4. **Consistent**: A single rule governs all error handling decisions across the package

## Consequences

### Positive

- Logs are concise and non-repetitive
- Easier to count occurrences of specific errors (no double-counting)
- Clear guidance for future contributors on where to add observability
- Stream consumers have full control over how errors are presented

### Negative

- If the application forgets to listen to the error stream, emitted errors are silently lost (mitigated by ADR-003's documentation requirement)
- Log-only errors (internal concerns) are invisible to the application — they can only be seen in raw logs
- Requires discipline: every new error handling site must decide "log or emit" explicitly

## Alternatives Considered

### Always Log and Emit

Log at the source for developer diagnostics, emit for application consumption:
- Rejected because it produces duplicate entries in practice — the application listener almost always logs the event too
- Makes it hard to tell from logs whether one or two things happened

### Log at Source, Emit Silently

Log at the source, emit events without any expectation of logging by the consumer:
- Rejected because it defeats the purpose of the error stream — if the library already logged everything, why would the application listen?
- Couples internal log formatting to external observability requirements
