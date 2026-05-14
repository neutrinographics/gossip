# gossip_bluey: react to `Bluey.stateStream` + defensive lifecycle errors

**Status:** Design (revised 2026-05-06)
**Date:** 2026-05-06
**Type:** Bug fix
**Bluey upstream:** I333 (`Live Server/Connection/Scanner not invalidated when adapter cycles off`) — partial overlap; see "Relationship to I333" below.

## Problem

The user reproduced a Bluetooth-toggle failure in dogfooding:

1. Bluetooth on, peers connected, traffic flowing.
2. User toggles Bluetooth off → peers disconnect.
3. App's UI still shows "scanning" / "connected to N peers" — the underlying scanner and server are dead.
4. User toggles Bluetooth back on, taps "restart scanning".
5. `BlueyTransport.startAdvertising` calls into a stale `bluey.Server` whose Android `BluetoothGattServer` Binder is dead. `addService` throws `DeadObjectException`, bluey wraps it as `PlatformException(bluey-unknown, …)`, the exception is **not caught** anywhere in gossip_bluey, surfaces as an unhandled async exception.

Two failure modes compound:

- **The adapter going off was never observed by gossip_bluey.** `BlueyPortImpl` continues to think `_centralConnections`, `_peripheralClients`, etc. are live. The application registry still has every peer marked connected. `BlueyMetrics.connectedPeerCount` lies. The UI lies.
- **A subsequent operation against the stale state is unhandled** rather than failing with a typed, actionable error.

What's already in place upstream (verified 2026-05-06 by the I333 maintainer):

- `Bluey.stateStream` — broadcast `Stream<BluetoothState>` of every adapter transition.
- `Bluey.currentState`, `Bluey.state`, `Bluey.ensureReady()`.
- Typed exceptions: `BluetoothUnavailableException`, `BluetoothDisabledException` (in `bluey_platform_interface`).
- Platform-side observation: Android `BluetoothAdapter.ACTION_STATE_CHANGED` `BroadcastReceiver`; iOS `centralManagerDidUpdateState` / `peripheralManagerDidUpdateState`.

What's **missing** upstream and what I333 will add:

- Internal invalidation of live `Server`/`Connection`/`Scanner` instances on `state != on`.
- Translating `DeadObjectException` (and the iOS analog) to `BluetoothUnavailableException` so consumers don't see opaque `bluey-unknown` errors.

## Relationship to I333

Until I333 ships, bluey's `Server`/`Connection` instances are *not* internally invalidated when the adapter cycles. So even though `Bluey.stateStream` correctly says "the adapter went off," a stale `Server` reference happily lets you call `addService` on a dead Binder. **The mitigation here is on the consumer side**: gossip_bluey subscribes to `stateStream`, drops its own state, and refuses to use the stale references until the consumer-visible state is healthy.

Once I333 ships:
- Our subscription is still useful — we still need to fire `PortPeerDisconnected` for every peer so the gossip layer cleans up properly. Bluey can't do that cleanup on our behalf because peer-tracking is our domain concept, not bluey's.
- The `DeadObjectException → BluetoothUnavailableException` translation lets us narrow our `catch (e)` to `on BluetoothUnavailableException catch (e)`. Strictly an improvement; not a rewrite.

## Goals

1. When `Bluey.stateStream` emits any state other than `on`, gossip_bluey **proactively**:
   - Drops every entry in `_centralConnections`, `_peripheralClients`, `_clientIdToNodeId`, `_chunkSizeByNode`, `_devicesByAddress`.
   - Cancels every entry in `_centralNotifSubs`, `_centralStateSubs`, `_serverSubs`, `_scanSubscription`; closes `_scanController`.
   - Fires `PortPeerDisconnected` for every previously-active peer (for both roles, where applicable) so `ConnectionService` removes registry entries, drops `FrameDecoder`s, and emits `PeerClosed` to the application.
   - Marks the port as **disabled**: subsequent calls to `startAdvertising`, `connect`, `connectAndIdentify`, `sendData`, etc. throw `BluetoothUnavailableException` immediately without touching bluey.
2. When `Bluey.stateStream` returns to `on`, the port re-enables. Consumers must explicitly call `startAdvertising` again to set up advertising/services from scratch — no auto-reinit.
3. As a backstop for any operation that slips through before `stateStream` updates: catch errors thrown by bluey lifecycle calls and translate to `BluetoothUnavailableException`.
4. `BlueyPort.startAdvertising` either succeeds or throws a typed exception. No unhandled async exceptions reach the application's zone error handler.

## Non-goals

- **Auto-reinitializing advertising/services on `state == on`.** The consumer must opt in. Auto-reinit is a footgun (consumer might not realize state was lost; might not want to re-advertise immediately).
- **Defensive catches in every operation method.** This iteration covers `startAdvertising` (the demonstrated failure point) and adds the proactive `stateStream` subscription that handles the broader class of failures regardless of which method would have been called next. Per-method catches are recorded as follow-up but not all rolled in here.
- **Application-layer UI affordance.** Gossip_chat decides how to render the state (banner, dialog, etc.). The library exposes the signal; the UI is the consumer's call.

## Design

### New domain value object: `BluetoothAdapterState`

`packages/gossip_bluey/lib/src/domain/value_objects/bluetooth_adapter_state.dart`:

```dart
/// Coarse-grained state of the underlying Bluetooth adapter. Maps from
/// the bluey platform-interface `BluetoothState` so the domain layer
/// doesn't import bluey types directly.
enum BluetoothAdapterState {
  /// Adapter is on and usable. The only state in which transport
  /// operations succeed.
  on,

  /// User or OS turned the adapter off.
  off,

  /// App is not permitted to use Bluetooth (permission denied or
  /// missing usage-description on iOS).
  unauthorized,

  /// Device has no BLE support, or the platform doesn't expose it.
  unsupported,

  /// Mid-transition (turning on, turning off, iOS resetting) or not
  /// yet determined at startup. Treat as "not on" for gating purposes.
  unknown,
}
```

### New domain exception

`packages/gossip_bluey/lib/src/domain/errors/bluetooth_unavailable_exception.dart`:

```dart
import 'package:gossip/gossip.dart';

/// Thrown by [BlueyPort] lifecycle and operation methods when the
/// underlying Bluetooth adapter is in a state that prevents normal
/// operation — typically because the adapter is off, transitioning, or
/// permission was revoked.
///
/// The port observes [Bluey.stateStream] and proactively transitions
/// to a *disabled* state on any non-`on` value. While disabled, calls
/// throw this exception immediately. The port re-enables when
/// `stateStream` emits `on` again, but advertising/services must be
/// re-established by an explicit call to [startAdvertising].
class BluetoothUnavailableException implements Exception {
  /// Underlying error from bluey or the platform plugin, when this
  /// exception was caused by a thrown lifecycle call. Null when the
  /// exception was thrown proactively because the port was already
  /// disabled.
  final Object? cause;

  /// Optional NodeId context — set when this exception surfaces from
  /// a per-peer call (e.g. `connect`, `sendData`). Null for global
  /// lifecycle calls like `startAdvertising`.
  final NodeId? nodeId;

  const BluetoothUnavailableException({this.cause, this.nodeId});

  @override
  String toString() {
    final parts = <String>[];
    if (cause != null) parts.add('cause: $cause');
    if (nodeId != null) parts.add('nodeId: $nodeId');
    return 'BluetoothUnavailableException(${parts.join(', ')})';
  }
}
```

### `BlueyPort` interface additions

```dart
abstract interface class BlueyPort {
  // ... existing methods ...

  /// Last-known Bluetooth adapter state. Synchronous; backed by a
  /// cache that the [bluetoothStateStream] keeps current.
  BluetoothAdapterState get bluetoothAdapterState;

  /// Stream of every Bluetooth adapter transition. Multi-listener;
  /// emits the current value on subscription.
  Stream<BluetoothAdapterState> get bluetoothStateStream;
}
```

### `BlueyPortImpl` — `stateStream` subscription + adapter-state surface

Subscribe in the constructor, retain the subscription, react in a private handler, expose to consumers via a re-broadcast controller (so we can map bluey's type to our domain type once and serve multiple listeners):

```dart
class BlueyPortImpl implements BlueyPort {
  BlueyPortImpl({required NodeId localNodeId, bluey.Bluey? blueyInstance})
      : _localNodeIdValue = localNodeId.value,
        _bluey = blueyInstance ??
            bluey.Bluey(localIdentity: bluey.ServerId(localNodeId.value)) {
    _adapterState = _mapBlueyState(_bluey.currentState);
    _adapterStateController = StreamController<BluetoothAdapterState>.broadcast(
      onListen: () => _adapterStateController.add(_adapterState),
    );
    _stateSub = _bluey.stateStream.listen((s) {
      _onBluetoothStateChanged(_mapBlueyState(s));
    });
  }

  late final StreamSubscription<bluey.BluetoothState> _stateSub;
  late final StreamController<BluetoothAdapterState> _adapterStateController;
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  bool _adapterDisabled = true;  // start disabled; flip on first 'on' event

  @override
  BluetoothAdapterState get bluetoothAdapterState => _adapterState;

  @override
  Stream<BluetoothAdapterState> get bluetoothStateStream =>
      _adapterStateController.stream;

  void _onBluetoothStateChanged(BluetoothAdapterState state) {
    _adapterState = state;
    if (!_adapterStateController.isClosed) {
      _adapterStateController.add(state);
    }
    final isOn = state == BluetoothAdapterState.on;
    if (!isOn && !_adapterDisabled) {
      _adapterDisabled = true;
      _invalidateLiveState();
    } else if (isOn && _adapterDisabled) {
      _adapterDisabled = false;
      // No auto-reinit. Consumer must call startAdvertising again.
    }
  }

  static BluetoothAdapterState _mapBlueyState(bluey.BluetoothState s) {
    switch (s) {
      case bluey.BluetoothState.on:
        return BluetoothAdapterState.on;
      case bluey.BluetoothState.off:
        return BluetoothAdapterState.off;
      case bluey.BluetoothState.unauthorized:
        return BluetoothAdapterState.unauthorized;
      case bluey.BluetoothState.unsupported:
        return BluetoothAdapterState.unsupported;
      // Any other bluey value (turningOn, turningOff, resetting, unknown,
      // future additions) is treated as "not on" — collapse to unknown.
      default:
        return BluetoothAdapterState.unknown;
    }
  }

  /// Drop every live reference to platform objects, cancel every
  /// subscription, fire PortPeerDisconnected for every active peer.
  /// Idempotent. Called on adapter-off and on dispose.
  void _invalidateLiveState() {
    final centralPeers = _centralConnections.keys.toList();
    final peripheralPeers = _peripheralClients.keys.toList();

    for (final sub in _centralNotifSubs.values) {
      unawaited(sub.cancel());
    }
    _centralNotifSubs.clear();
    for (final sub in _centralStateSubs.values) {
      unawaited(sub.cancel());
    }
    _centralStateSubs.clear();
    for (final sub in _serverSubs) {
      unawaited(sub.cancel());
    }
    _serverSubs.clear();
    unawaited(_scanSubscription?.cancel());
    _scanSubscription = null;
    if (_scanController != null && !_scanController!.isClosed) {
      unawaited(_scanController!.close());
    }
    _scanController = null;

    _centralConnections.clear();
    _peripheralClients.clear();
    _clientIdToNodeId.clear();
    _chunkSizeByNode.clear();
    _devicesByAddress.clear();
    _server = null;
    _serviceUuid = null;

    // Fire one PortPeerDisconnected per peer per role. ConnectionService's
    // existing handler removes registry entries and emits PeerClosed.
    for (final nodeId in centralPeers) {
      _events.add(PortPeerDisconnected(
        nodeId: nodeId,
        role: ConnectionRole.central,
        reason: 'bluetooth adapter unavailable',
      ));
    }
    for (final nodeId in peripheralPeers) {
      // Skip duplicates: a peer might be tracked in both maps simultaneously
      // due to the cross-role race; the central event above already covered
      // it.
      if (centralPeers.contains(nodeId)) continue;
      _events.add(PortPeerDisconnected(
        nodeId: nodeId,
        role: ConnectionRole.peripheral,
        reason: 'bluetooth adapter unavailable',
      ));
    }
  }
}
```

### `BlueyPortImpl` — disable-gate on operations

Each public method that touches platform state checks `_adapterDisabled` first:

```dart
@override
Future<void> startAdvertising({...}) async {
  if (_adapterDisabled) {
    throw const BluetoothUnavailableException();
  }
  // ... existing logic, plus the defensive try/catch below ...
}
```

The same gate applies to `stopAdvertising`, `connect`, `connectAndIdentify`, `disconnect`, `disconnectRole`, `sendData`, `scanForCandidates`, `stopScan`, `discoverPeers`. A small helper avoids repetition:

```dart
void _requireAdapterEnabled([NodeId? nodeId]) {
  if (_adapterDisabled) {
    throw BluetoothUnavailableException(nodeId: nodeId);
  }
}
```

### `BlueyPortImpl.startAdvertising` — defensive catch (backstop)

A race window exists where `stateStream` hasn't propagated `state != on` yet but the underlying Binder is already dead. In that case the operation slips past the disable-gate and dies inside bluey's call. Catch it:

```dart
@override
Future<void> startAdvertising({
  required ServiceUuid serviceUuid,
  required String displayName,
  required NodeId localNodeId,
}) async {
  _requireAdapterEnabled();
  if (localNodeId.value != _localNodeIdValue) {
    throw ArgumentError.value(...);  // unchanged — caller bug
  }
  _serviceUuid = serviceUuid;
  final server = _bluey.server();
  if (server == null) {
    _serviceUuid = null;
    throw StateError(
      'peripheral role not supported on this platform — '
      'gossip_bluey requires both central and peripheral roles',
    );
  }
  _server = server;

  try {
    await server.addService(GossipGattService.build(serviceUuid));
    // ... existing _serverSubs.add(server.peerConnections.listen(...)) etc ...
    await server.startAdvertising(
      name: displayName,
      services: [bluey.UUID(serviceUuid.value)],
      peerDiscoverable: true,
    );
  } catch (e) {
    // Roll back the partial setup so a retry starts clean.
    for (final sub in _serverSubs) {
      unawaited(sub.cancel());
    }
    _serverSubs.clear();
    _server = null;
    _serviceUuid = null;
    throw BluetoothUnavailableException(cause: e);
  }
}
```

The catch is **broad on purpose** — bluey doesn't yet differentiate state-related failures from other lifecycle errors. Once I333 ships its `DeadObjectException → BluetoothUnavailableException` translation upstream, we narrow to `on bluey.BluetoothUnavailableException catch (e)`. Documented inline.

### `BlueyTransport` (facade) — public surface

Add to `BlueyTransport`:

```dart
/// Last-known Bluetooth adapter state.
BluetoothAdapterState get bluetoothAdapterState =>
    _port.bluetoothAdapterState;

/// Stream of Bluetooth adapter transitions. Emits the current value
/// on subscription; emits again on every transition. Multi-listener.
///
/// When the value is anything other than [BluetoothAdapterState.on],
/// `BlueyTransport` is in a disabled state: lifecycle calls
/// ([startAdvertising], [stopAdvertising]) and per-peer operations
/// throw [BluetoothUnavailableException]. Disabled-state transitions
/// also fire [PeerDisconnected] events on [peerEvents] for every
/// previously-active peer.
Stream<BluetoothAdapterState> get bluetoothStateStream =>
    _port.bluetoothStateStream;
```

The application layer (gossip_chat) consumes this to render UI affordances ("Bluetooth is off — please enable it") and to gate user actions (greying out the "start networking" button when state is not `on`).

### `dispose`

`_stateSub.cancel()` and `_adapterStateController.close()` added to the existing dispose flow. `_invalidateLiveState` is also called (idempotent).

### `BlueyPort` interface contract update

Doc-comment on every public method gains: "Throws `BluetoothUnavailableException` if the underlying Bluetooth adapter is unavailable." No interface signature changes (the exception is a Dart `Exception`, not a typed result).

## DDD layering

| Concern | Layer | Component |
|---|---|---|
| Domain enum (adapter state) | Domain | `BluetoothAdapterState` (new) |
| Domain exception type | Domain | `BluetoothUnavailableException` (new) |
| Domain interface — adapter state surface | Domain | `BlueyPort` (new getter + stream) |
| Subscribing to `bluey.stateStream`; mapping bluey→domain | Infrastructure | `BlueyPortImpl` constructor + `_mapBlueyState` |
| Internal invalidation on adapter-off | Infrastructure | `BlueyPortImpl._invalidateLiveState` |
| Firing per-peer disconnects so the registry cleans up | Infrastructure (emit) → Application (receive) | `BlueyPortImpl` emits `PortPeerDisconnected` on `_events`; `ConnectionService._onPortEvent` already handles it |
| Disable-gate on operations | Infrastructure | `BlueyPortImpl._requireAdapterEnabled` |
| Translating thrown bluey errors into typed domain errors | Infrastructure | `BlueyPortImpl.startAdvertising` (catch block) |
| Public adapter-state surface | Facade | `BlueyTransport.bluetoothAdapterState` + `bluetoothStateStream` (new getters) |

`ConnectionService` does not change in this iteration. Its existing `PortPeerDisconnected` handler already does the right thing — removes from registry, drops decoder, emits `PeerClosed` to the application. By firing those events from `BlueyPortImpl._invalidateLiveState`, we re-use the existing cleanup path instead of duplicating it.

`BlueyTransport` gains two getters but no behavioral logic — it forwards to `_port`. The exception propagates naturally through `startAdvertising`; per-peer cleanup happens via `ConnectionService.events`.

## Test plan

Unit tests in `packages/gossip_bluey/test/infrastructure/adapters/bluey_port_impl_test.dart` (new file). All tests inject a fake `bluey.Bluey` whose `stateStream`, `server()`, and other methods we control. The constructor seam (`bluey.Bluey? blueyInstance`) already supports this.

The fake will need:
- A controllable `StreamController<bluey.BluetoothState>` for `stateStream`.
- A configurable `Server` mock that can be made to throw `addService` / succeed `addService`.

**Adapter state observation:**

1. **Adapter-off invalidates internal state.** Setup: a port with two registered peers (one as central, one as peripheral), advertising started. Push `BluetoothState.off` on `stateStream`. Assert: `_centralConnections.isEmpty`, `_peripheralClients.isEmpty`, `_chunkSizeByNode.isEmpty`, `_serverSubs.isEmpty`. Assert: two `PortPeerDisconnected` events were emitted (one per peer) with reason `'bluetooth adapter unavailable'`.

2. **Adapter-off transitions emit one disconnect per peer regardless of role.** A peer registered in both `_centralConnections` AND `_peripheralClients` (cross-role race) emits exactly one `PortPeerDisconnected` for the central role.

3. **Operations after adapter-off throw `BluetoothUnavailableException`.** After (1), call `startAdvertising`, `connect`, `sendData`, `scanForCandidates`. Assert each throws `BluetoothUnavailableException` synchronously without invoking the underlying bluey instance. (Verified by the fake recording call counts.)

4. **Adapter-on re-enables the port.** After (3), push `BluetoothState.on` on `stateStream`. Call `startAdvertising`. Assert it succeeds (and the fake records the bluey calls).

**Defensive catch:**

5. **`startAdvertising` translates a thrown bluey error into `BluetoothUnavailableException`.** Inject a fake whose `server().addService(...)` throws `Exception('synthetic')`. Call `port.startAdvertising(...)`. Assert it throws `BluetoothUnavailableException` whose `cause` field is the synthetic error.

6. **`startAdvertising` resets internal state on failure so a retry can succeed.** Same fake as (5), then swap to one whose `addService` succeeds. Call `port.startAdvertising(...)` a second time. Assert it succeeds.

7. **`startAdvertising` cancels in-flight subscriptions on failure.** Fake whose `addService` succeeds but whose `startAdvertising` throws. Assert `_serverSubs` is empty after the catch fires.

**Adapter-state surface:**

8. **`bluetoothAdapterState` returns the current mapped state.** Push `BluetoothState.on`, assert getter returns `BluetoothAdapterState.on`. Push `.off`, assert getter returns `.off`. Push `.unauthorized`, assert returns `.unauthorized`. Push any other bluey state, assert returns `.unknown` (catch-all).

9. **`bluetoothStateStream` emits the current value to new subscribers and re-emits on transitions.** New listener subscribes; assert receives the current value immediately. Push a transition; assert listener receives the new value.

10. **`BlueyTransport.bluetoothAdapterState` and `bluetoothStateStream` forward correctly.** Wire a `BlueyTransport` to the fake port, push state transitions, assert the transport's getter and stream reflect them.

**Disposal:**

11. **`dispose` cancels the stateStream subscription and closes the rebroadcast controller.** After dispose, `bluetoothStateStream` is a closed stream (subscribers immediately complete); the fake's underlying stream has zero remaining listeners.

## Files touched

**New:**
- `packages/gossip_bluey/lib/src/domain/value_objects/bluetooth_adapter_state.dart` — the new enum.
- `packages/gossip_bluey/lib/src/domain/errors/bluetooth_unavailable_exception.dart` — the new exception.
- `packages/gossip_bluey/test/infrastructure/adapters/bluey_port_impl_test.dart` — tests above.

**Modified:**
- `packages/gossip_bluey/lib/src/domain/interfaces/bluey_port.dart` — add `bluetoothAdapterState` getter and `bluetoothStateStream` to the interface; doc-comments noting the new exception on each operation method.
- `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart` — `_stateSub`, `_adapterStateController`, `_adapterState`, `_adapterDisabled`, `_onBluetoothStateChanged`, `_mapBlueyState`, `_invalidateLiveState`, `_requireAdapterEnabled`, gate calls in every operation method, defensive catch in `startAdvertising`, dispose update.
- `packages/gossip_bluey/lib/src/facade/bluey_transport.dart` — `bluetoothAdapterState` getter + `bluetoothStateStream` forwarding to `_port`; doc-comments noting the new exception on `startAdvertising`.
- `packages/gossip_bluey/test/fakes/fake_bluey_port.dart` — implement the new `bluetoothAdapterState` + `bluetoothStateStream` getters with a controllable stream so other tests that drive `BlueyPort` keep compiling (and we can drive state transitions in tests that use the fake).

`ConnectionService`, `ConnectionRegistry`, `BlueyMetrics` unchanged in this iteration.

## Out of scope (recorded for follow-up)

- **Per-method defensive catches in `connect`, `connectAndIdentify`, `sendData`, etc.** The adapter-state subscription handles the *common* case (adapter cycled, all subsequent operations should fail clean). Per-method catches address the rarer race where a thrown bluey error doesn't correspond to an adapter-state issue. Add when actual production usage surfaces a failure mode in those paths, or when bluey ships I333's typed exceptions and a uniform translation layer makes the work cheap.
- **Re-narrowing the catch from `catch (e)` to `on BluetoothUnavailableException catch (e)` after I333 ships.** Tracked as follow-up to I333.

## Why this is the right step

- **Real value, not guessing**: directly addresses the Bluetooth-toggle failure you reproduced. Both halves — the UI lying and the unhandled exception — get fixed.
- **No bluey dependency**: uses bluey's existing `stateStream` and existing `BluetoothUnavailableException` types. No upstream blockers.
- **Bounded scope**: one infrastructure file, one new domain type, eight unit tests. No application or facade logic changes.
- **Forward-compatible**: when I333 lands, the catch narrows but the architecture stays. No rewrite.
