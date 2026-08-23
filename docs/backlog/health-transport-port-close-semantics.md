# Converge the transports' MessagePort close() semantics

**Track:** Code health   **Depends on:** nothing

## What this is

The core `MessagePort` contract says that after `close()`, no more messages
can be sent or received. The two transport packages' Coordinator-facing
ports satisfy that contract today, but by different means:

- `gossip_nearby`'s `NearbyMessagePort.close()` gates only its own view —
  it stops delivering on `incoming` and stops sending, but leaves the rest
  of the connection layer (the `MessageDispatcher`, the underlying Nearby
  Connections adapter) running. Tearing that down is a separate step owned
  by the facade (`NearbyTransport`).
- `gossip_bluey`'s `BlueyMessagePort.close()` delegates straight to the
  dispatcher's `close()`/`dispose()`, which tears down the entire
  connection layer — send queues, the port subscription, BLE
  disconnects, everything — as a side effect of closing the port.

Both satisfy the letter of the `MessagePort` contract, but they draw the
line between "port" and "facade" responsibilities in different places.

## The rule to converge on

A port's `close()` should gate its own view only (stop the streams it
exposes to the Coordinator). Full connection-layer teardown — dispatcher
disposal, BLE disconnects, adapter shutdown — belongs to the facade
(`NearbyTransport` / `BlueyTransport`), not to the port.

## Why it matters

Today both existing transports happen to behave correctly from the
Coordinator's point of view, so this is latent rather than an active bug.
But the split is inconsistent, and undocumented inconsistency is exactly
what trips up the next implementer: the first out-of-repo `MessagePort`
consumer that models its close() on whichever transport it reads first
will either leak a connection layer that never tears down, or tear down
more than a port's contract implies it owns.

## Also in scope

While converging close semantics, make the nearby port's forwarding
subscription pass stream errors through to `incoming` listeners (today it
forwards data only; the dispatcher stream is data-only by design, so this
is latent — but a future dispatcher that emits errors would bypass port
listeners silently).

## Related

- The `MessagePort` contract: `packages/gossip/lib/src/shared/domain/interfaces/message_port.dart`.
- `NearbyMessagePort`: `packages/gossip_nearby/lib/src/infrastructure/ports/nearby_message_port.dart`.
- `BlueyMessagePort`: `packages/gossip_bluey/lib/src/infrastructure/ports/bluey_message_port.dart`.
