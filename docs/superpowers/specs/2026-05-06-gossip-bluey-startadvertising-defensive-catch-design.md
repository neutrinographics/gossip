# gossip_bluey: defensive catch in `startAdvertising`

**Status:** Design
**Date:** 2026-05-06
**Type:** Bug fix (small, scoped)
**Bluey upstream:** I333 (`Bluetooth adapter state not observed`)

## Problem

When the underlying Bluetooth adapter has been turned off and back on, bluey's internal `Server` reference holds a dead Binder proxy on Android (and equivalently a stale `CBPeripheralManager` on iOS). Calling `BlueyPort.startAdvertising` on a `BlueyPortImpl` in this state propagates an `android.os.DeadObjectException`, which bluey wraps as `PlatformException(bluey-unknown, "Failed to add service: …")`, which is **not caught** anywhere in `gossip_bluey` and surfaces as an unhandled async exception.

Two user-visible problems result:

1. **The app sees an unhandled exception** rather than a typed, actionable error. There's no way to differentiate "Bluetooth is off; ask the user to enable it" from "this service is malformed" or "out of memory" — they all look the same.
2. **`BlueyPortImpl`'s internal state ends up half-initialized.** `_serviceUuid` is set, `_server` may or may not be set depending on which line threw — and a subsequent retry call will skip parts of the setup it expected to be fresh.

The right fix is a bluey-side state-observation system (tracked as bluey backlog **I333**). That will emit typed `BluetoothUnavailableException`/`StaleHandleException`, plus events on `Bluey.events` so consumers can react proactively. Until I333 lands, this spec proposes a **scoped backstop in gossip_bluey** that:

- Catches whatever bluey currently throws from `startAdvertising`,
- Surfaces it as a typed gossip_bluey domain exception,
- Resets `BlueyPortImpl`'s internal state so a retry can succeed once the underlying adapter is healthy again.

## Goals

- `BlueyPort.startAdvertising` either succeeds *or* throws a typed exception. No unhandled async exceptions reach the application's zone error handler.
- The application layer (`BlueyTransport`, ultimately `gossip_chat`) can pattern-match on `BluetoothUnavailableException` and surface a "Bluetooth is unavailable; please enable Bluetooth and try again" UI affordance.
- A retry of `startAdvertising` after Bluetooth is restored succeeds, without requiring the `BlueyPortImpl` to be reconstructed.

## Non-goals

- **Full state observation.** Listening to Android `BluetoothAdapter.STATE_*` / iOS `CBManagerState` belongs in bluey (I333). This spec doesn't attempt to subscribe to those — without bluey's help we'd be duplicating platform plumbing the library should own.
- **Reactive cleanup of in-flight peer state.** When Bluetooth goes off, every active `_centralConnections` entry, `_peripheralClients` entry, etc. is also stale. Cleaning those up reactively requires the `Bluey.events` signal that I333 proposes. Until then, those entries linger; consumers will discover them when they hit them and our existing per-method error handling triggers (or doesn't). Deferred until I333 ships.
- **Defensive catches in other `BlueyPortImpl` methods** (`stopAdvertising`, `connect`, `connectAndIdentify`, `sendData`, etc.). They have the same vulnerability shape but aren't currently the user-visible failure point. Add as needed; out of scope here.

## Design

### New domain exception

`packages/gossip_bluey/lib/src/domain/errors/bluetooth_unavailable_exception.dart`:

```dart
import 'package:gossip/gossip.dart';

/// Thrown by [BlueyPort.startAdvertising] (and related lifecycle calls)
/// when the underlying Bluetooth adapter is in a state that prevents
/// normal operation — most commonly "off" or "transitioning off"
/// after a user toggle, but also covers the "stale handle" failure
/// mode where bluey is holding a reference to a now-invalid platform
/// object.
///
/// Pending bluey backlog I333 (state observation), this exception is
/// inferred from any error thrown by the underlying bluey lifecycle
/// call — bluey doesn't yet differentiate state-related failures from
/// other lifecycle errors. Once I333 lands, the inference becomes
/// precise and this exception will be thrown only in genuine adapter-
/// unavailable scenarios.
class BluetoothUnavailableException implements Exception {
  /// Underlying error from bluey or the platform plugin. Useful for
  /// diagnostic logging; consumers should not pattern-match on it.
  final Object cause;

  /// Optional NodeId context — set when this exception surfaces from
  /// a per-peer call (e.g. `connect`, `sendData`). Null for global
  /// lifecycle calls like `startAdvertising`.
  final NodeId? nodeId;

  const BluetoothUnavailableException(this.cause, {this.nodeId});

  @override
  String toString() => 'BluetoothUnavailableException(cause: $cause)';
}
```

### `BlueyPortImpl.startAdvertising` change

Wrap the bluey calls in a try/catch. On any thrown exception, reset the partial state and rethrow as `BluetoothUnavailableException`:

```dart
@override
Future<void> startAdvertising({
  required ServiceUuid serviceUuid,
  required String displayName,
  required NodeId localNodeId,
}) async {
  if (localNodeId.value != _localNodeIdValue) {
    throw ArgumentError.value(...);  // unchanged — caller bug, not adapter state
  }
  _serviceUuid = serviceUuid;
  final server = _bluey.server();
  if (server == null) {
    _serviceUuid = null;  // reset on early failure
    throw StateError(
      'peripheral role not supported on this platform — '
      'gossip_bluey requires both central and peripheral roles',
    );
  }
  _server = server;

  try {
    await server.addService(GossipGattService.build(serviceUuid));
    // ... existing _serverSubs registrations ...
    await server.startAdvertising(
      name: displayName,
      services: [bluey.UUID(serviceUuid.value)],
      peerDiscoverable: true,
    );
  } catch (e) {
    // Cleanup: cancel any subscriptions we managed to register, drop
    // the stale server reference, clear _serviceUuid so a retry starts
    // clean.
    for (final sub in _serverSubs) {
      unawaited(sub.cancel());
    }
    _serverSubs.clear();
    _server = null;
    _serviceUuid = null;
    throw BluetoothUnavailableException(e);
  }
}
```

The catch is **broad on purpose** for this iteration. Until bluey grows typed exceptions (I333), we can't reliably distinguish "adapter is off" from other lifecycle failures, and a misclassification at the gossip_bluey layer is less harmful than an uncaught async exception. Once I333 ships, we narrow the catch to bluey's typed errors.

### `BlueyPort` interface contract update

Add to the doc-comment on `startAdvertising`:

```dart
/// Begin advertising as a gossip-speaking peripheral.
///
/// ...existing wording...
///
/// Throws [BluetoothUnavailableException] if the underlying Bluetooth
/// adapter is not in a usable state (off, transitioning, unauthorized).
/// In that case all internal state is reset; a subsequent call will
/// succeed once the adapter is healthy again.
```

### `BlueyTransport` (facade) propagation

`BlueyTransport.startAdvertising` already returns `Future<void>`. Just let `BluetoothUnavailableException` propagate — no wrapping needed at this layer. Document the same in the facade's doc-comment so app-level callers know to catch it.

## DDD layering

| Concern | Layer | Component |
|---|---|---|
| Domain exception type | Domain | `BluetoothUnavailableException` (new) |
| Translating bluey/platform errors into domain types | Infrastructure | `BlueyPortImpl.startAdvertising` |
| Resetting internal lifecycle state on failure | Infrastructure | `BlueyPortImpl.startAdvertising` (catch block) |
| Propagating to caller | Facade | `BlueyTransport.startAdvertising` (no change; just rethrows) |

No application-layer change. No new aggregates or value objects beyond the exception. Tightly scoped.

## Test plan

Unit tests in `packages/gossip_bluey/test/infrastructure/adapters/bluey_port_impl_test.dart` (creating the file if it doesn't exist; the existing test layout has no direct `BlueyPortImpl` tests because it wraps the real bluey instance). For these tests, **inject a fake `bluey.Bluey` instance** that throws on `server.addService`:

1. **`startAdvertising` translates a thrown bluey error into `BluetoothUnavailableException`.** Inject a fake bluey whose `server().addService(...)` throws `Exception('synthetic')`. Call `port.startAdvertising(...)`. Assert it throws `BluetoothUnavailableException`, and the `cause` field equals the synthetic error.

2. **`startAdvertising` resets internal state on failure so a retry can succeed.** Same injection, then swap the fake to one whose `addService` succeeds. Call `port.startAdvertising(...)` a second time. Assert it succeeds; assert `_serverSubs.isEmpty` is false (subscriptions were re-registered cleanly).

3. **`startAdvertising` cancels in-flight subscriptions on failure.** Inject a fake whose `addService` succeeds but whose `startAdvertising` (the real bluey call inside our wrapper) throws. Assert the subscriptions registered on `server.peerConnections`, `server.disconnections`, `server.writeRequests` are all cancelled before the exception bubbles out. (Verify via the fake recording cancel calls.)

The first two are the load-bearing ones; the third is defense-in-depth for the partial-failure case.

If the test infrastructure for injecting a fake `bluey.Bluey` doesn't exist (it likely doesn't — `BlueyPortImpl` currently constructs its own `bluey.Bluey` instance with `bluey.Bluey(localIdentity: …)`), the constructor already supports `bluey.Bluey? blueyInstance` injection — that's the seam the test uses.

## Files touched

**New:**
- `packages/gossip_bluey/lib/src/domain/errors/bluetooth_unavailable_exception.dart` — the new exception.
- `packages/gossip_bluey/test/infrastructure/adapters/bluey_port_impl_test.dart` — three tests above.

**Modified:**
- `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart` — try/catch + reset around the bluey lifecycle calls.
- `packages/gossip_bluey/lib/src/domain/interfaces/bluey_port.dart` — doc-comment on `startAdvertising` mentioning the new exception.
- `packages/gossip_bluey/lib/src/facade/bluey_transport.dart` — doc-comment on `startAdvertising` mentioning the new exception.

No public API change beyond the doc-comments and the new exception type.

## Out of scope (recorded for follow-up)

- **`stopAdvertising`, `connect`, `connectAndIdentify`, `sendData`, `discoverPeers`, `scanForCandidates`** — same vulnerability class. Address when actual production usage surfaces a failure mode in those paths, or when bluey I333 lands and a uniform translation layer makes the work cheap.
- **In-flight peer state cleanup** when Bluetooth goes off mid-session (the registry still has peers, decoders are still allocated, etc.). Requires `Bluey.events` signal from I333.
- **UI affordance in gossip_chat** to detect `BluetoothUnavailableException` and prompt the user. Application-layer concern; not part of the library.

## Why this is the right small step

- **Bounded scope**: one method, one new domain type, three unit tests.
- **No guessing**: the change directly addresses the unhandled-exception we observed in hardware testing. No speculation about what *might* fail; we're hardening exactly the path that *did* fail.
- **Doesn't conflict with the eventual upstream fix**: when bluey ships I333 with typed errors, the gossip_bluey catch narrows from `catch (e)` to `on BluetoothUnavailableException` (bluey-side type) `catch (e)`, and the rest of this design stays.
