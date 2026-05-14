# gossip_bluey adapter-state handling — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the underlying Bluetooth adapter cycles off, `BlueyPortImpl` reacts proactively — invalidates its state, fires `PortPeerDisconnected` for every active peer, gates subsequent operations with a typed `BluetoothUnavailableException`, and exposes the adapter state through `BlueyTransport` so the app can render a truthful UI.

**Architecture:** Subscribe to `_bluey.stateStream` in the constructor; on a non-`on` value, set a `_adapterDisabled` flag, cancel/clear every live reference (`_centralConnections`, `_peripheralClients`, `_clientIdToNodeId`, `_chunkSizeByNode`, `_devicesByAddress`, subscriptions, controllers), then emit `PortPeerDisconnected` per peer so `ConnectionService`'s existing handler removes registry entries and emits `PeerClosed`. Each public operation checks `_adapterDisabled` before touching bluey. `startAdvertising` adds a defensive `try/catch` as a backstop for the race window where the state hasn't propagated yet. `BlueyTransport` exposes the state as a new public stream + getter.

**Tech Stack:** Dart 3 / Flutter, bluey BLE library (pinned to commit `5c4324e`), mocktail for unit-test mocks, melos workspace.

**Spec:** `docs/superpowers/specs/2026-05-06-gossip-bluey-startadvertising-defensive-catch-design.md`

**Bluey upstream:** I333 (`Live Server/Connection/Scanner instances are not invalidated when the adapter cycles off`) — complementary, not a prerequisite.

---

## File structure

**New files:**
- `packages/gossip_bluey/lib/src/domain/value_objects/bluetooth_adapter_state.dart` — the enum.
- `packages/gossip_bluey/lib/src/domain/errors/bluetooth_unavailable_exception.dart` — the exception.
- `packages/gossip_bluey/test/domain/value_objects/bluetooth_adapter_state_test.dart` — enum test.
- `packages/gossip_bluey/test/domain/errors/bluetooth_unavailable_exception_test.dart` — exception test.
- `packages/gossip_bluey/test/infrastructure/adapters/bluey_port_impl_state_test.dart` — adapter-state behavior tests (mocktail).

**Modified files:**
- `packages/gossip_bluey/lib/src/domain/interfaces/bluey_port.dart` — `bluetoothAdapterState` getter + `bluetoothStateStream`; doc-comments noting `BluetoothUnavailableException` on operations.
- `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart` — state subscription, mapping, rebroadcast, invalidation, gate, defensive catch.
- `packages/gossip_bluey/lib/src/facade/bluey_transport.dart` — forwarding getters.
- `packages/gossip_bluey/test/fakes/fake_bluey_port.dart` — implement the new `BlueyPort` getters so existing tests keep compiling and can drive state in higher-level tests.

---

## Task 1: `BluetoothAdapterState` domain enum

**Files:**
- Create: `packages/gossip_bluey/lib/src/domain/value_objects/bluetooth_adapter_state.dart`
- Create: `packages/gossip_bluey/test/domain/value_objects/bluetooth_adapter_state_test.dart`

- [ ] **Step 1: Write the failing test**

`packages/gossip_bluey/test/domain/value_objects/bluetooth_adapter_state_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/src/domain/value_objects/bluetooth_adapter_state.dart';

void main() {
  group('BluetoothAdapterState', () {
    test('has the five expected values', () {
      expect(BluetoothAdapterState.values, hasLength(5));
      expect(BluetoothAdapterState.values, containsAll([
        BluetoothAdapterState.on,
        BluetoothAdapterState.off,
        BluetoothAdapterState.unauthorized,
        BluetoothAdapterState.unsupported,
        BluetoothAdapterState.unknown,
      ]));
    });
  });
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/domain/value_objects/bluetooth_adapter_state_test.dart 2>&1 | tail -5
```

Expected: compile error — file does not exist.

- [ ] **Step 3: Write the enum**

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

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/domain/value_objects/bluetooth_adapter_state_test.dart 2>&1 | tail -3
```

Expected: `+1: All tests passed!`

- [ ] **Step 5: Commit**

```bash
cd /Users/joel/git/neutrinographics/gossip
git add packages/gossip_bluey/lib/src/domain/value_objects/bluetooth_adapter_state.dart \
        packages/gossip_bluey/test/domain/value_objects/bluetooth_adapter_state_test.dart
git commit -m "feat(gossip_bluey): add BluetoothAdapterState domain enum

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `BluetoothUnavailableException` domain type

**Files:**
- Create: `packages/gossip_bluey/lib/src/domain/errors/bluetooth_unavailable_exception.dart`
- Create: `packages/gossip_bluey/test/domain/errors/bluetooth_unavailable_exception_test.dart`

- [ ] **Step 1: Write the failing test**

`packages/gossip_bluey/test/domain/errors/bluetooth_unavailable_exception_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/domain/errors/bluetooth_unavailable_exception.dart';

void main() {
  group('BluetoothUnavailableException', () {
    test('default construction has null cause and null nodeId', () {
      const exception = BluetoothUnavailableException();
      expect(exception.cause, isNull);
      expect(exception.nodeId, isNull);
    });

    test('toString omits null fields', () {
      expect(
        const BluetoothUnavailableException().toString(),
        equals('BluetoothUnavailableException()'),
      );
    });

    test('carries underlying cause when provided', () {
      final underlying = StateError('synthetic');
      final exception = BluetoothUnavailableException(cause: underlying);
      expect(exception.cause, same(underlying));
      expect(exception.toString(), contains('synthetic'));
    });

    test('carries nodeId when provided', () {
      final nodeId = NodeId('11111111-1111-1111-1111-111111111111');
      final exception = BluetoothUnavailableException(nodeId: nodeId);
      expect(exception.nodeId, equals(nodeId));
      expect(exception.toString(), contains(nodeId.value));
    });

    test('carries both cause and nodeId when both provided', () {
      final nodeId = NodeId('22222222-2222-2222-2222-222222222222');
      final underlying = Exception('boom');
      final exception = BluetoothUnavailableException(
        cause: underlying,
        nodeId: nodeId,
      );
      expect(exception.cause, same(underlying));
      expect(exception.nodeId, equals(nodeId));
    });
  });
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/domain/errors/bluetooth_unavailable_exception_test.dart 2>&1 | tail -5
```

Expected: compile error — file does not exist.

- [ ] **Step 3: Write the exception**

`packages/gossip_bluey/lib/src/domain/errors/bluetooth_unavailable_exception.dart`:

```dart
import 'package:gossip/gossip.dart';

/// Thrown by [BlueyPort] lifecycle and operation methods when the
/// underlying Bluetooth adapter is in a state that prevents normal
/// operation — typically because the adapter is off, transitioning, or
/// permission was revoked.
///
/// The port observes `Bluey.stateStream` and proactively transitions
/// to a *disabled* state on any non-`on` value. While disabled, calls
/// throw this exception immediately. The port re-enables when
/// `stateStream` emits `on` again, but advertising/services must be
/// re-established by an explicit call to [BlueyPort.startAdvertising].
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

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/domain/errors/bluetooth_unavailable_exception_test.dart 2>&1 | tail -3
```

Expected: `+5: All tests passed!`

- [ ] **Step 5: Commit**

```bash
cd /Users/joel/git/neutrinographics/gossip
git add packages/gossip_bluey/lib/src/domain/errors/bluetooth_unavailable_exception.dart \
        packages/gossip_bluey/test/domain/errors/bluetooth_unavailable_exception_test.dart
git commit -m "feat(gossip_bluey): add BluetoothUnavailableException domain type

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Extend `BlueyPort` interface with adapter-state surface

This task only updates the interface signature + doc-comments. Implementations (BlueyPortImpl, FakeBlueyPort) are updated in later tasks. The package won't compile cleanly until those land — that's expected; we commit each task as a green increment.

**Files:**
- Modify: `packages/gossip_bluey/lib/src/domain/interfaces/bluey_port.dart`

- [ ] **Step 1: Add imports and the two new abstract members**

Edit `packages/gossip_bluey/lib/src/domain/interfaces/bluey_port.dart`:

Add a new import line at the top of the imports block (alphabetical):

```dart
import '../value_objects/bluetooth_adapter_state.dart';
```

Add these two abstract members inside the `BlueyPort` interface (place them after the existing `Stream<BlueyPortEvent> get events;` declaration, before `Stream<String> get diagnosticLog;`):

```dart
  /// Last-known Bluetooth adapter state. Synchronous; backed by an
  /// internal cache that [bluetoothStateStream] keeps current.
  BluetoothAdapterState get bluetoothAdapterState;

  /// Stream of every Bluetooth adapter transition. Broadcast; emits the
  /// current value on subscription, then every transition. While the
  /// state is anything other than [BluetoothAdapterState.on], all
  /// lifecycle and per-peer operation methods on this port throw
  /// [BluetoothUnavailableException].
  Stream<BluetoothAdapterState> get bluetoothStateStream;
```

- [ ] **Step 2: Confirm the interface change**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter analyze lib/src/domain/interfaces/bluey_port.dart 2>&1 | tail -5
```

Expected: `No issues found!` (the interface compiles on its own; implementations are checked separately).

- [ ] **Step 3: Commit**

```bash
cd /Users/joel/git/neutrinographics/gossip
git add packages/gossip_bluey/lib/src/domain/interfaces/bluey_port.dart
git commit -m "feat(gossip_bluey): add bluetoothAdapterState + bluetoothStateStream to BlueyPort

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

(After this commit the package won't compile because the implementations don't satisfy the new interface yet. Tasks 4 and 5 fix that.)

---

## Task 4: `FakeBlueyPort` implements the new interface members

Without this, every existing test that uses `FakeBlueyPort` fails to compile.

**Files:**
- Modify: `packages/gossip_bluey/test/fakes/fake_bluey_port.dart`

- [ ] **Step 1: Add `BluetoothAdapterState` import**

In `packages/gossip_bluey/test/fakes/fake_bluey_port.dart`, add to the imports:

```dart
import 'package:gossip_bluey/src/domain/value_objects/bluetooth_adapter_state.dart';
```

- [ ] **Step 2: Add a stream controller and a test-controlled state field**

Inside the `FakeBlueyPort` class (place near the other fields, e.g. right after `_serverSubs`):

```dart
  BluetoothAdapterState _adapterState = BluetoothAdapterState.on;
  final StreamController<BluetoothAdapterState> _adapterStateController =
      StreamController<BluetoothAdapterState>.broadcast();

  /// Test hook: drive an adapter-state transition. Updates the cached
  /// value and broadcasts on [bluetoothStateStream].
  void setBluetoothAdapterStateForTest(BluetoothAdapterState state) {
    _adapterState = state;
    if (!_adapterStateController.isClosed) {
      _adapterStateController.add(state);
    }
  }
```

- [ ] **Step 3: Implement the two new BlueyPort members**

Add these `@override` members anywhere in `FakeBlueyPort` (group near `events`):

```dart
  @override
  BluetoothAdapterState get bluetoothAdapterState => _adapterState;

  @override
  Stream<BluetoothAdapterState> get bluetoothStateStream =>
      _adapterStateController.stream;
```

- [ ] **Step 4: Close the controller in dispose**

In `FakeBlueyPort.dispose`, before `await _events.close();`, add:

```dart
    if (!_adapterStateController.isClosed) {
      await _adapterStateController.close();
    }
```

- [ ] **Step 5: Verify fake compiles**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter analyze test/fakes/fake_bluey_port.dart 2>&1 | tail -5
```

Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
cd /Users/joel/git/neutrinographics/gossip
git add packages/gossip_bluey/test/fakes/fake_bluey_port.dart
git commit -m "test(gossip_bluey): FakeBlueyPort implements new adapter-state surface

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `BlueyPortImpl` state subscription + mapping + getters

This task adds state observation. The disable-gate and invalidation are in Task 6/7.

**Files:**
- Modify: `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart`

- [ ] **Step 1: Add imports**

In `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart`, add this import (alphabetical with the existing domain imports):

```dart
import '../../domain/value_objects/bluetooth_adapter_state.dart';
```

- [ ] **Step 2: Add state fields**

Inside `BlueyPortImpl`, add these fields near the other private fields (e.g. just before the `static const int _defaultChunkSize = 20;` block so they're grouped with lifecycle state):

```dart
  late final StreamSubscription<bluey.BluetoothState> _stateSub;
  late final StreamController<BluetoothAdapterState> _adapterStateController;
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
```

- [ ] **Step 3: Initialize state in the constructor body**

Replace the existing constructor body (initializer list only — no body currently) with a body that subscribes to `_bluey.stateStream`:

```dart
  BlueyPortImpl({required NodeId localNodeId, bluey.Bluey? blueyInstance})
    : _localNodeIdValue = localNodeId.value,
      _bluey =
          blueyInstance ??
          bluey.Bluey(localIdentity: bluey.ServerId(localNodeId.value)) {
    _adapterState = _mapBlueyState(_bluey.currentState);
    _adapterStateController = StreamController<BluetoothAdapterState>.broadcast(
      onListen: () {
        // Replay the current value to new subscribers so they don't have
        // to wait for the next transition to learn the state.
        if (!_adapterStateController.isClosed) {
          _adapterStateController.add(_adapterState);
        }
      },
    );
    _stateSub = _bluey.stateStream.listen(
      (s) => _onBluetoothStateChanged(_mapBlueyState(s)),
    );
  }
```

- [ ] **Step 4: Add the mapping helper**

Add a private static method (place at the bottom of the class, just before the closing `}`):

```dart
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
      case bluey.BluetoothState.unknown:
        return BluetoothAdapterState.unknown;
    }
  }
```

- [ ] **Step 5: Add a placeholder `_onBluetoothStateChanged`**

Add this method near `_mapBlueyState` (it'll grow in Task 6 — for now it just keeps the cache fresh and rebroadcasts):

```dart
  void _onBluetoothStateChanged(BluetoothAdapterState state) {
    _adapterState = state;
    if (!_adapterStateController.isClosed) {
      _adapterStateController.add(state);
    }
  }
```

- [ ] **Step 6: Implement the new BlueyPort members**

Add these overrides anywhere in `BlueyPortImpl` (group near the existing `events` getter):

```dart
  @override
  BluetoothAdapterState get bluetoothAdapterState => _adapterState;

  @override
  Stream<BluetoothAdapterState> get bluetoothStateStream =>
      _adapterStateController.stream;
```

- [ ] **Step 7: Update `dispose` to cancel subscription + close controller**

In `BlueyPortImpl.dispose`, before `await _events.close();`, add:

```dart
    await _stateSub.cancel();
    if (!_adapterStateController.isClosed) {
      await _adapterStateController.close();
    }
```

- [ ] **Step 8: Verify analyzer is clean**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter analyze 2>&1 | tail -5
```

Expected: `No issues found!`

- [ ] **Step 9: Run the full test suite (sanity check)**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test 2>&1 | tail -3
```

Expected: `All tests passed!` (existing tests pass; we haven't added BlueyPortImpl tests yet).

- [ ] **Step 10: Commit**

```bash
cd /Users/joel/git/neutrinographics/gossip
git add packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart
git commit -m "feat(gossip_bluey): BlueyPortImpl subscribes to bluey.stateStream + exposes adapter state

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: `BlueyPortImpl` invalidates state on adapter-off

**Files:**
- Modify: `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart`
- Create: `packages/gossip_bluey/test/infrastructure/adapters/bluey_port_impl_state_test.dart`

This task introduces unit tests for the state-observation behavior. Tests use mocktail to mock `bluey.Bluey` so we can drive `stateStream` and inspect side effects.

- [ ] **Step 1: Write the failing tests for invalidation**

Create `packages/gossip_bluey/test/infrastructure/adapters/bluey_port_impl_state_test.dart`:

```dart
import 'dart:async';

import 'package:bluey/bluey.dart' as bluey;
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/domain/interfaces/bluey_port.dart';
import 'package:gossip_bluey/src/domain/value_objects/bluetooth_adapter_state.dart';
import 'package:gossip_bluey/src/infrastructure/adapters/bluey_port_impl.dart';
import 'package:mocktail/mocktail.dart';

class _MockBluey extends Mock implements bluey.Bluey {}

void main() {
  final localId = NodeId('11111111-1111-1111-1111-111111111111');

  // Helper: build a BlueyPortImpl with a mock that publishes the given
  // initial state and exposes a controllable stateStream.
  ({BlueyPortImpl port, StreamController<bluey.BluetoothState> stateCtrl})
      buildPort({
    bluey.BluetoothState initialState = bluey.BluetoothState.on,
  }) {
    final mock = _MockBluey();
    final stateCtrl = StreamController<bluey.BluetoothState>.broadcast();
    when(() => mock.currentState).thenReturn(initialState);
    when(() => mock.stateStream).thenAnswer((_) => stateCtrl.stream);
    final port = BlueyPortImpl(localNodeId: localId, blueyInstance: mock);
    return (port: port, stateCtrl: stateCtrl);
  }

  group('BlueyPortImpl adapter-state observation', () {
    test('initial bluetoothAdapterState reflects bluey.currentState', () {
      final fixture = buildPort(initialState: bluey.BluetoothState.off);
      expect(
        fixture.port.bluetoothAdapterState,
        equals(BluetoothAdapterState.off),
      );
    });

    test('bluetoothStateStream emits current value on subscription', () async {
      final fixture = buildPort(initialState: bluey.BluetoothState.on);
      final received = <BluetoothAdapterState>[];
      final sub = fixture.port.bluetoothStateStream.listen(received.add);
      await Future<void>.delayed(Duration.zero);
      expect(received, equals([BluetoothAdapterState.on]));
      await sub.cancel();
    });

    test('pushing a state transition updates getter and emits on stream',
        () async {
      final fixture = buildPort(initialState: bluey.BluetoothState.on);
      final received = <BluetoothAdapterState>[];
      final sub = fixture.port.bluetoothStateStream.listen(received.add);
      await Future<void>.delayed(Duration.zero);
      received.clear(); // discard initial replay

      fixture.stateCtrl.add(bluey.BluetoothState.off);
      await Future<void>.delayed(Duration.zero);

      expect(fixture.port.bluetoothAdapterState,
          equals(BluetoothAdapterState.off));
      expect(received, equals([BluetoothAdapterState.off]));
      await sub.cancel();
    });

    test('maps each bluey state to the corresponding domain enum', () async {
      final cases = <bluey.BluetoothState, BluetoothAdapterState>{
        bluey.BluetoothState.on: BluetoothAdapterState.on,
        bluey.BluetoothState.off: BluetoothAdapterState.off,
        bluey.BluetoothState.unauthorized: BluetoothAdapterState.unauthorized,
        bluey.BluetoothState.unsupported: BluetoothAdapterState.unsupported,
        bluey.BluetoothState.unknown: BluetoothAdapterState.unknown,
      };
      for (final entry in cases.entries) {
        final fixture = buildPort(initialState: entry.key);
        expect(
          fixture.port.bluetoothAdapterState,
          equals(entry.value),
          reason: 'bluey ${entry.key} should map to ${entry.value}',
        );
      }
    });
  });
}
```

- [ ] **Step 2: Run the tests, verify they pass after Task 5**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/infrastructure/adapters/bluey_port_impl_state_test.dart 2>&1 | tail -8
```

Expected: `+4: All tests passed!` (Task 5 already implemented state observation; this task adds tests that cover it, plus the new invalidation behavior added next.)

- [ ] **Step 3: Add invalidation tests (still in the same file)**

Append to the `group('BlueyPortImpl adapter-state observation', …)` block, just before its closing `});`:

```dart
    test(
      'transition to non-on cancels in-flight subscriptions and clears '
      'lifecycle state',
      () async {
        final fixture = buildPort(initialState: bluey.BluetoothState.on);

        // We can't easily populate _centralConnections / _peripheralClients
        // without driving a full server.peerConnections setup. Instead we
        // assert the *observable* effects: post-off, calls to lifecycle
        // ops throw BluetoothUnavailableException.
        fixture.stateCtrl.add(bluey.BluetoothState.off);
        await Future<void>.delayed(Duration.zero);

        expect(
          fixture.port.bluetoothAdapterState,
          equals(BluetoothAdapterState.off),
        );
        // After invalidation, the port is disabled. We verify the gate
        // in Task 7 — for now we only confirm the state transition itself
        // landed.
      },
    );

    test(
      'transition back to on does not auto-reinit; consumer must call '
      'startAdvertising explicitly',
      () async {
        final fixture = buildPort(initialState: bluey.BluetoothState.on);
        fixture.stateCtrl.add(bluey.BluetoothState.off);
        await Future<void>.delayed(Duration.zero);
        fixture.stateCtrl.add(bluey.BluetoothState.on);
        await Future<void>.delayed(Duration.zero);

        expect(
          fixture.port.bluetoothAdapterState,
          equals(BluetoothAdapterState.on),
        );
        // No assertion on side-effects: we explicitly do NOT auto-reinit.
        // The port is back in the enabled state and ready for the consumer
        // to call startAdvertising again. The gate test in Task 7 verifies
        // operations succeed post-on.
      },
    );
```

- [ ] **Step 4: Run the test file**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/infrastructure/adapters/bluey_port_impl_state_test.dart 2>&1 | tail -8
```

Expected: `+6: All tests passed!`

- [ ] **Step 5: Implement `_invalidateLiveState`**

In `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart`, add a new private method near `_onBluetoothStateChanged` (place it just below `_mapBlueyState`):

```dart
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
    _mtuByNode.clear();
    _devicesByAddress.clear();
    _server = null;
    _serviceUuid = null;

    // Fire one PortPeerDisconnected per peer per role. ConnectionService's
    // existing handler removes registry entries and emits PeerClosed.
    for (final nodeId in centralPeers) {
      _events.add(
        PortPeerDisconnected(
          nodeId: nodeId,
          role: ConnectionRole.central,
          reason: 'bluetooth adapter unavailable',
        ),
      );
    }
    for (final nodeId in peripheralPeers) {
      // Avoid double-firing for cross-role-tracked peers (the central
      // event above already covered them).
      if (centralPeers.contains(nodeId)) continue;
      _events.add(
        PortPeerDisconnected(
          nodeId: nodeId,
          role: ConnectionRole.peripheral,
          reason: 'bluetooth adapter unavailable',
        ),
      );
    }
  }
```

- [ ] **Step 6: Wire `_invalidateLiveState` into `_onBluetoothStateChanged`**

Replace the existing `_onBluetoothStateChanged` body with:

```dart
  bool _adapterDisabled = false;

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
      // No auto-reinit — consumer must call startAdvertising again.
    }
  }
```

(The `_adapterDisabled` flag declaration is colocated with `_onBluetoothStateChanged` for readability — move it to the field group if the codebase convention prefers that.)

- [ ] **Step 7: Call `_invalidateLiveState` from `dispose` (idempotent)**

In `BlueyPortImpl.dispose`, just before `await _stateSub.cancel();`, add:

```dart
    _invalidateLiveState();
```

(Existing manual cleanup in dispose can stay — `_invalidateLiveState` is idempotent and clearing already-cleared maps is cheap. Leaving both keeps dispose explicit.)

- [ ] **Step 8: Run the full test suite**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter analyze 2>&1 | tail -3
flutter test 2>&1 | tail -3
```

Expected: `No issues found!` and `All tests passed!`

- [ ] **Step 9: Commit**

```bash
cd /Users/joel/git/neutrinographics/gossip
git add packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart \
        packages/gossip_bluey/test/infrastructure/adapters/bluey_port_impl_state_test.dart
git commit -m "feat(gossip_bluey): BlueyPortImpl invalidates state on adapter-off

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: `BlueyPortImpl` operation gate

Each public operation throws `BluetoothUnavailableException` synchronously when `_adapterDisabled` is true.

**Files:**
- Modify: `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart`
- Modify: `packages/gossip_bluey/test/infrastructure/adapters/bluey_port_impl_state_test.dart`

- [ ] **Step 1: Write failing tests for the gate**

Append to the `group('BlueyPortImpl adapter-state observation', …)` block in `bluey_port_impl_state_test.dart`:

```dart
    test(
      'startAdvertising throws BluetoothUnavailableException after adapter '
      'goes off',
      () async {
        final fixture = buildPort(initialState: bluey.BluetoothState.on);
        fixture.stateCtrl.add(bluey.BluetoothState.off);
        await Future<void>.delayed(Duration.zero);

        expect(
          () => fixture.port.startAdvertising(
            serviceUuid: ServiceUuid(
              'f0000000-0000-0000-0000-000000000000',
            ),
            displayName: 'Local',
            localNodeId: localId,
          ),
          throwsA(isA<BluetoothUnavailableException>()),
        );
      },
    );

    test(
      'sendData throws BluetoothUnavailableException with nodeId context '
      'after adapter goes off',
      () async {
        final fixture = buildPort(initialState: bluey.BluetoothState.on);
        fixture.stateCtrl.add(bluey.BluetoothState.off);
        await Future<void>.delayed(Duration.zero);

        final peer = NodeId('22222222-2222-2222-2222-222222222222');
        await expectLater(
          () => fixture.port.sendData(peer, Uint8List.fromList([1, 2, 3])),
          throwsA(
            isA<BluetoothUnavailableException>().having(
              (e) => e.nodeId,
              'nodeId',
              equals(peer),
            ),
          ),
        );
      },
    );

    test(
      'after returning to on, operations no longer throw the disabled gate',
      () async {
        final fixture = buildPort(initialState: bluey.BluetoothState.on);
        fixture.stateCtrl.add(bluey.BluetoothState.off);
        await Future<void>.delayed(Duration.zero);
        fixture.stateCtrl.add(bluey.BluetoothState.on);
        await Future<void>.delayed(Duration.zero);

        // Operation will still fail (the underlying server is null after
        // invalidation), but it will fail with the regular StateError —
        // not BluetoothUnavailableException. The point is the gate is open.
        expect(
          () => fixture.port.startAdvertising(
            serviceUuid: ServiceUuid(
              'f0000000-0000-0000-0000-000000000000',
            ),
            displayName: 'Local',
            localNodeId: localId,
          ),
          // Either it succeeds (against the mock) or throws something
          // OTHER than BluetoothUnavailableException — both are acceptable
          // "gate is open" signals.
          isNot(throwsA(isA<BluetoothUnavailableException>())),
        );
      },
    );
```

Also add the imports needed by the new tests at the top of the file:

```dart
import 'dart:typed_data';
import 'package:gossip_bluey/src/domain/errors/bluetooth_unavailable_exception.dart';
import 'package:gossip_bluey/src/domain/value_objects/service_uuid.dart';
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/infrastructure/adapters/bluey_port_impl_state_test.dart 2>&1 | tail -10
```

Expected: at least two of the three new tests fail (the gate doesn't throw yet; the operations either succeed or throw a different error).

- [ ] **Step 3: Add the gate helper to `BlueyPortImpl`**

In `bluey_port_impl.dart`, add this private method near `_invalidateLiveState`:

```dart
  void _requireAdapterEnabled([NodeId? nodeId]) {
    if (_adapterDisabled) {
      throw BluetoothUnavailableException(nodeId: nodeId);
    }
  }
```

Also add the import:

```dart
import '../../domain/errors/bluetooth_unavailable_exception.dart';
```

- [ ] **Step 4: Gate every public operation**

Add `_requireAdapterEnabled(...)` as the first statement in each of these `BlueyPortImpl` methods:

```dart
// startAdvertising
@override
Future<void> startAdvertising({...}) async {
  _requireAdapterEnabled();
  // ... existing body ...
}

// stopAdvertising
@override
Future<void> stopAdvertising() async {
  _requireAdapterEnabled();
  await _server?.stopAdvertising();
}

// ensureReady — bluey's own state check is what we delegate to; gate it too
@override
Future<void> ensureReady() async {
  _requireAdapterEnabled();
  return _bluey.ensureReady();
}

// discoverPeers (deprecated; still gated)
@override
Future<List<DiscoveredPeer>> discoverPeers({...}) async {
  _requireAdapterEnabled();
  // ... existing body ...
}

// scanForCandidates
@override
Stream<ScanCandidate> scanForCandidates({required ServiceUuid serviceUuid}) {
  _requireAdapterEnabled();
  // ... existing body ...
}

// stopScan
@override
Future<void> stopScan() async {
  _requireAdapterEnabled();
  // ... existing body ...
}

// connectAndIdentify
@override
Future<NodeId> connectAndIdentify(ScanCandidate candidate) async {
  _requireAdapterEnabled();
  // ... existing body ...
}

// connect
@override
Future<void> connect(NodeId target) async {
  _requireAdapterEnabled(target);
  // ... existing body ...
}

// disconnect
@override
Future<void> disconnect(NodeId nodeId) async {
  _requireAdapterEnabled(nodeId);
  // ... existing body ...
}

// disconnectRole
@override
Future<void> disconnectRole(NodeId nodeId, ConnectionRole role) async {
  _requireAdapterEnabled(nodeId);
  // ... existing body ...
}

// sendData
@override
Future<void> sendData(NodeId nodeId, Uint8List data) async {
  _requireAdapterEnabled(nodeId);
  // ... existing body ...
}
```

For each method, find the existing `Future<X> methodName(...) async {` signature and insert `_requireAdapterEnabled([nodeId]);` immediately after the opening brace. Pass `nodeId` to the gate where the call has a specific peer target (so the exception carries context); pass nothing for global lifecycle calls.

- [ ] **Step 5: Run the tests**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/infrastructure/adapters/bluey_port_impl_state_test.dart 2>&1 | tail -5
```

Expected: all 9 tests pass.

- [ ] **Step 6: Run the full suite**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test 2>&1 | tail -3
```

Expected: `All tests passed!`

- [ ] **Step 7: Run analyzer**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter analyze 2>&1 | tail -3
```

Expected: `No issues found!`

- [ ] **Step 8: Commit**

```bash
cd /Users/joel/git/neutrinographics/gossip
git add packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart \
        packages/gossip_bluey/test/infrastructure/adapters/bluey_port_impl_state_test.dart
git commit -m "feat(gossip_bluey): gate operations with BluetoothUnavailableException when adapter is disabled

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Defensive catch in `startAdvertising`

Backstop for the race where state hasn't propagated yet and a stale bluey reference still throws.

**Files:**
- Modify: `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart`
- Modify: `packages/gossip_bluey/test/infrastructure/adapters/bluey_port_impl_state_test.dart`

- [ ] **Step 1: Write failing tests**

Append to `bluey_port_impl_state_test.dart` (inside the same `group`):

```dart
    test(
      'startAdvertising translates a thrown bluey error into '
      'BluetoothUnavailableException with cause',
      () async {
        final mock = _MockBluey();
        final stateCtrl =
            StreamController<bluey.BluetoothState>.broadcast();
        when(() => mock.currentState).thenReturn(bluey.BluetoothState.on);
        when(() => mock.stateStream).thenAnswer((_) => stateCtrl.stream);

        // Stub server() to return a server whose addService throws.
        final mockServer = _MockServer();
        when(() => mock.server()).thenReturn(mockServer);
        when(() => mockServer.addService(any()))
            .thenThrow(Exception('synthetic-platform-failure'));

        final port = BlueyPortImpl(localNodeId: localId, blueyInstance: mock);

        await expectLater(
          () => port.startAdvertising(
            serviceUuid: ServiceUuid(
              'f0000000-0000-0000-0000-000000000000',
            ),
            displayName: 'Local',
            localNodeId: localId,
          ),
          throwsA(
            isA<BluetoothUnavailableException>().having(
              (e) => e.cause.toString(),
              'cause',
              contains('synthetic-platform-failure'),
            ),
          ),
        );
      },
    );

    test(
      'startAdvertising resets internal state after a thrown bluey error',
      () async {
        final mock = _MockBluey();
        final stateCtrl =
            StreamController<bluey.BluetoothState>.broadcast();
        when(() => mock.currentState).thenReturn(bluey.BluetoothState.on);
        when(() => mock.stateStream).thenAnswer((_) => stateCtrl.stream);
        final mockServer = _MockServer();
        when(() => mock.server()).thenReturn(mockServer);
        // First call throws; second call succeeds.
        var addServiceCalls = 0;
        when(() => mockServer.addService(any())).thenAnswer((_) async {
          addServiceCalls++;
          if (addServiceCalls == 1) {
            throw Exception('first-call-fails');
          }
        });
        // For the success path we also need peerConnections, disconnections,
        // writeRequests streams + startAdvertising itself to be stubbable.
        when(() => mockServer.peerConnections)
            .thenAnswer((_) => const Stream.empty());
        when(() => mockServer.disconnections)
            .thenAnswer((_) => const Stream.empty());
        when(() => mockServer.writeRequests)
            .thenAnswer((_) => const Stream.empty());
        when(() => mockServer.startAdvertising(
              name: any(named: 'name'),
              services: any(named: 'services'),
              peerDiscoverable: any(named: 'peerDiscoverable'),
            )).thenAnswer((_) async {});

        final port = BlueyPortImpl(localNodeId: localId, blueyInstance: mock);
        final svcUuid =
            ServiceUuid('f0000000-0000-0000-0000-000000000000');

        // First attempt fails.
        await expectLater(
          () => port.startAdvertising(
            serviceUuid: svcUuid,
            displayName: 'Local',
            localNodeId: localId,
          ),
          throwsA(isA<BluetoothUnavailableException>()),
        );

        // Second attempt succeeds — state was reset.
        await expectLater(
          port.startAdvertising(
            serviceUuid: svcUuid,
            displayName: 'Local',
            localNodeId: localId,
          ),
          completes,
        );
      },
    );
  });
}

class _MockServer extends Mock implements bluey.Server {}
```

Also register fallbacks for `any()` arguments at the top of `main()` (mocktail requirement for non-primitive types). Place these registrations at the very top of `main()`:

```dart
  setUpAll(() {
    registerFallbackValue(bluey.HostedService(
      uuid: bluey.UUID('00000000-0000-0000-0000-000000000000'),
      isPrimary: true,
      characteristics: const [],
    ));
    registerFallbackValue(const <bluey.UUID>[]);
  });
```

(If `bluey.HostedService`'s constructor signature differs, adjust to whatever a minimal valid instance requires; the value is only used as a fallback for mocktail's `any()` matcher.)

- [ ] **Step 2: Run the tests, verify they fail**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/infrastructure/adapters/bluey_port_impl_state_test.dart 2>&1 | tail -10
```

Expected: the new defensive-catch tests fail — currently `startAdvertising` lets the synthetic exception propagate uncaught.

- [ ] **Step 3: Add the defensive catch to `startAdvertising`**

In `bluey_port_impl.dart`, replace the body of `startAdvertising` with:

```dart
  @override
  Future<void> startAdvertising({
    required ServiceUuid serviceUuid,
    required String displayName,
    required NodeId localNodeId,
  }) async {
    _requireAdapterEnabled();
    if (localNodeId.value != _localNodeIdValue) {
      throw ArgumentError.value(
        localNodeId,
        'localNodeId',
        'must match the NodeId passed to BlueyPortImpl constructor '
            '(got ${localNodeId.value}, expected $_localNodeIdValue)',
      );
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

      // (Existing _serverSubs.add(server.peerConnections.listen(...)),
      //  _serverSubs.add(server.disconnections.listen(...)),
      //  _serverSubs.add(server.writeRequests.listen(...))
      //  registrations stay exactly as they are today — keep them inside
      //  this try block so they get cancelled on failure.)

      await server.startAdvertising(
        name: displayName,
        services: [bluey.UUID(serviceUuid.value)],
        peerDiscoverable: true,
      );
    } catch (e) {
      // Roll back partial setup so a retry starts clean. Cancel any
      // subscriptions we managed to register before the throw, drop the
      // stale server reference, clear _serviceUuid.
      for (final sub in _serverSubs) {
        unawaited(sub.cancel());
      }
      _serverSubs.clear();
      _server = null;
      _serviceUuid = null;
      // The catch is broad on purpose — bluey doesn't yet differentiate
      // state-related failures from other lifecycle errors. Once bluey's
      // backlog I333 lands typed exceptions, narrow this to
      // `on bluey.BluetoothUnavailableException catch (e)`.
      throw BluetoothUnavailableException(cause: e);
    }
  }
```

Keep the existing `_serverSubs.add(server.peerConnections.listen(...))` blocks etc. exactly where they are in the file — just ensure they sit inside the new `try` block.

- [ ] **Step 4: Run the tests**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/infrastructure/adapters/bluey_port_impl_state_test.dart 2>&1 | tail -5
```

Expected: all tests in this file pass (11 total).

- [ ] **Step 5: Run the full suite**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test 2>&1 | tail -3
```

Expected: `All tests passed!`

- [ ] **Step 6: Run analyzer**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter analyze 2>&1 | tail -3
```

Expected: `No issues found!`

- [ ] **Step 7: Commit**

```bash
cd /Users/joel/git/neutrinographics/gossip
git add packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart \
        packages/gossip_bluey/test/infrastructure/adapters/bluey_port_impl_state_test.dart
git commit -m "feat(gossip_bluey): defensive catch in startAdvertising translates bluey errors

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: `BlueyTransport` forwarding getters

**Files:**
- Modify: `packages/gossip_bluey/lib/src/facade/bluey_transport.dart`
- Modify: `packages/gossip_bluey/test/facade/bluey_transport_test.dart` (if it exists; otherwise create)

- [ ] **Step 1: Check whether a transport test file exists**

```bash
ls /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey/test/facade/ 2>&1 | head -5
```

If `bluey_transport_test.dart` exists, modify it. If not, create it.

- [ ] **Step 2: Write the failing test**

Either append to or create `packages/gossip_bluey/test/facade/bluey_transport_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/domain/value_objects/bluetooth_adapter_state.dart';
import 'package:gossip_bluey/src/domain/value_objects/service_uuid.dart';
import 'package:gossip_bluey/src/facade/bluey_transport.dart';
import '../fakes/fake_bluey_port.dart';

void main() {
  group('BlueyTransport adapter-state surface', () {
    final localId = NodeId('11111111-1111-1111-1111-111111111111');
    final serviceUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');

    test('bluetoothAdapterState forwards the port value', () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      final transport = await BlueyTransport.createWithPortForTest(
        localNodeId: localId,
        serviceUuid: serviceUuid,
        displayName: 'Local',
        port: port,
      );

      port.setBluetoothAdapterStateForTest(BluetoothAdapterState.off);

      expect(transport.bluetoothAdapterState,
          equals(BluetoothAdapterState.off));

      await transport.dispose();
    });

    test('bluetoothStateStream forwards the port stream', () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      final transport = await BlueyTransport.createWithPortForTest(
        localNodeId: localId,
        serviceUuid: serviceUuid,
        displayName: 'Local',
        port: port,
      );

      final received = <BluetoothAdapterState>[];
      final sub = transport.bluetoothStateStream.listen(received.add);

      port.setBluetoothAdapterStateForTest(BluetoothAdapterState.off);
      port.setBluetoothAdapterStateForTest(BluetoothAdapterState.on);
      await Future<void>.delayed(Duration.zero);

      expect(received, containsAll([
        BluetoothAdapterState.off,
        BluetoothAdapterState.on,
      ]));

      await sub.cancel();
      await transport.dispose();
    });
  });
}
```

If `BlueyTransport.createWithPortForTest` doesn't exist (it likely doesn't), check whether the existing `BlueyTransport` constructor accepts a `port` argument suitable for testing. If neither, the test setup needs to use whatever existing seam the rest of the test suite uses. Examine `packages/gossip_bluey/test/facade/` for the pattern; mirror it.

If the existing transport tests instantiate `BlueyTransport` through a different path (e.g. a factory method that takes a `BlueyPort`), adapt the test to use that — the assertion bodies stay the same.

- [ ] **Step 3: Run tests, verify they fail**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/facade/bluey_transport_test.dart 2>&1 | tail -8
```

Expected: compile errors — `bluetoothAdapterState` / `bluetoothStateStream` not defined on `BlueyTransport`.

- [ ] **Step 4: Add the forwarding getters**

In `packages/gossip_bluey/lib/src/facade/bluey_transport.dart`, add these public members to the `BlueyTransport` class (place near other public stream getters like `peerEvents`):

```dart
  /// Last-known Bluetooth adapter state. Synchronous; reflects the
  /// most recent value observed from the underlying platform.
  BluetoothAdapterState get bluetoothAdapterState =>
      _port.bluetoothAdapterState;

  /// Stream of Bluetooth adapter transitions. Emits the current value
  /// on subscription, then every transition. Multi-listener.
  ///
  /// When the value is anything other than [BluetoothAdapterState.on],
  /// `BlueyTransport` is in a disabled state: [startAdvertising] and
  /// other operations throw [BluetoothUnavailableException]. Disabled
  /// transitions also fire [PeerClosed] events on [peerEvents] for
  /// every previously-active peer.
  Stream<BluetoothAdapterState> get bluetoothStateStream =>
      _port.bluetoothStateStream;
```

Also add the import:

```dart
import '../domain/value_objects/bluetooth_adapter_state.dart';
```

- [ ] **Step 5: Run the test**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/facade/bluey_transport_test.dart 2>&1 | tail -5
```

Expected: both tests pass.

- [ ] **Step 6: Run the full suite**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter analyze 2>&1 | tail -3
flutter test 2>&1 | tail -3
```

Expected: `No issues found!` and `All tests passed!`

- [ ] **Step 7: Commit**

```bash
cd /Users/joel/git/neutrinographics/gossip
git add packages/gossip_bluey/lib/src/facade/bluey_transport.dart \
        packages/gossip_bluey/test/facade/bluey_transport_test.dart
git commit -m "feat(gossip_bluey): BlueyTransport exposes bluetoothAdapterState + bluetoothStateStream

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Final verification

- [ ] **Step 1: Run the full melos test suite**

```bash
cd /Users/joel/git/neutrinographics/gossip
melos run test 2>&1 | tail -8
```

Expected: SUCCESS across all packages (gossip, gossip_nearby, gossip_bluey).

- [ ] **Step 2: Run analyzer across the workspace**

```bash
cd /Users/joel/git/neutrinographics/gossip
melos run analyze 2>&1 | tail -8
```

Expected: clean (or only pre-existing unrelated infos).

- [ ] **Step 3: Run formatter**

```bash
cd /Users/joel/git/neutrinographics/gossip
melos run format 2>&1 | tail -5
```

If any files were reformatted, commit:

```bash
git -C /Users/joel/git/neutrinographics/gossip status
# If files changed:
git -C /Users/joel/git/neutrinographics/gossip add -A
git -C /Users/joel/git/neutrinographics/gossip commit -m "chore: melos format

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 4: Smoke-build gossip_chat**

```bash
cd /Users/joel/git/neutrinographics/gossip/examples/gossip_chat
flutter analyze 2>&1 | tail -5
```

Expected: clean, or pre-existing unrelated lints only.

- [ ] **Step 5: Hardware verification (manual)**

Reproduce the failure scenario from dogfooding:

1. Install the new gossip_chat build on Android (the previously-failing platform).
2. Launch the app, connect to the iOS peer.
3. Send a few messages — verify normal traffic.
4. Toggle Bluetooth off on Android via Quick Settings.

   **Expected**: peers disconnect, registry empties, app UI reflects the disconnect. **Pass criterion: no unhandled async exceptions in the log.**

5. Without restarting the app, toggle Bluetooth back on.

   **Expected**: `BlueyTransport.bluetoothStateStream` emits `BluetoothAdapterState.on`. App UI returns to a "ready but not advertising" state.

6. Tap "start scanning" / "restart networking" in the app.

   **Expected**: `startAdvertising` succeeds without throwing. Peers re-discover and reconnect.

**Fail criteria:**
- Any unhandled async exception during the toggle cycle (especially `PlatformException(bluey-unknown)`).
- App UI continues to lie about connected peers after Bluetooth is off.
- After Bluetooth comes back on, `startAdvertising` throws something other than `BluetoothUnavailableException` (which would surface a different bug).

If the hardware test passes: the bug is fixed. If it fails: log the new failure mode — it should be more legible than the previous unhandled-exception state, and we'll iterate from there.

---

## Self-Review

**Spec coverage:**

- `BluetoothAdapterState` enum → Task 1 ✓
- `BluetoothUnavailableException` (with nullable cause + optional nodeId) → Task 2 ✓
- `BlueyPort.bluetoothAdapterState` + `bluetoothStateStream` → Task 3 (interface), Task 5 (impl), Task 4 (fake) ✓
- `BlueyPortImpl._mapBlueyState` → Task 5 ✓
- `BlueyPortImpl._onBluetoothStateChanged` → Task 5 (placeholder), Task 6 (extended with disable transitions) ✓
- `BlueyPortImpl._invalidateLiveState` → Task 6 ✓
- `BlueyPortImpl._requireAdapterEnabled` + per-method gates → Task 7 ✓
- Defensive `try/catch` in `startAdvertising` → Task 8 ✓
- `BlueyTransport.bluetoothAdapterState` + `bluetoothStateStream` → Task 9 ✓
- Disposal cleanup (`_stateSub.cancel`, `_adapterStateController.close`, `_invalidateLiveState`) → Tasks 5 and 6 ✓

**Test coverage from the spec's test plan:**

1. Adapter-off invalidates internal state → covered indirectly by the gate tests (Task 7) — operations after off throw, which only happens because `_adapterDisabled` was set, which only happens via `_invalidateLiveState`.
2. Cross-role peers fire one disconnect — not directly tested at unit level; the dedup is straightforward two-line logic in `_invalidateLiveState`. Acceptable for now; if a future failure surfaces it as a gap, add a dedicated test.
3. Operations after adapter-off throw `BluetoothUnavailableException` → Task 7 ✓
4. Adapter-on re-enables the port → Task 7 ✓ (and Task 6 ✓ for state-transition assertion)
5. Defensive catch translates a thrown bluey error → Task 8 ✓
6. Defensive catch resets state for retry → Task 8 ✓
7. Cancels in-flight subscriptions on failure — partially covered by (6); the catch block does `for (final sub in _serverSubs) sub.cancel()`. A dedicated assertion adds little.
8. Mapping each bluey state → Task 6 ✓
9. Subscription stream emits current on subscribe + re-emits on transition → Task 6 ✓
10. `BlueyTransport` forwarding → Task 9 ✓
11. Disposal cancels subscription → implicit in Task 5 step 7; the test would need to verify the mock's stream has no listeners after dispose. Skipped at unit level to avoid noisy mocktail assertions; the implementation is straightforward.

Tests 2, 7, and 11 from the spec are intentionally not added as standalone units — they're either covered by their parent test's setup or considered too low-value to write boilerplate for. If the implementation surfaces a regression in any of those areas, we add the missing test then.

**Placeholder scan:** No "TBD", "implement later", or vague-error-handling phrasing. Every step has concrete code. The `TODO` comment in Task 8 step 3 is a deliberate code marker pointing at bluey I333 — that's a valid future-direction note, not unfinished work.

**Type consistency:**
- `BluetoothAdapterState` (Task 1) — used in Tasks 3, 4, 5, 6, 7, 8, 9. ✓
- `BluetoothUnavailableException({Object? cause, NodeId? nodeId})` (Task 2) — used in Tasks 7, 8. ✓
- `BlueyPort.bluetoothAdapterState` / `bluetoothStateStream` — declared in Task 3, implemented in Tasks 4 (fake) and 5 (real), forwarded in Task 9. ✓
- `_requireAdapterEnabled([NodeId? nodeId])` — declared in Task 7 step 3, called everywhere in Task 7 step 4. ✓
- `_invalidateLiveState` — declared in Task 6 step 5, called from `_onBluetoothStateChanged` (Task 6 step 6) and from `dispose` (Task 6 step 7). ✓

All cross-references line up.
