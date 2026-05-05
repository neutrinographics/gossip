# gossip_bluey: scan + upgrade discovery — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `Bluey.discoverPeers` (untested probe-and-disconnect cycle) with the bluey example app's scanner + `connectAsPeer` pattern, so we can isolate whether `discoverPeers` is the source of connection issues observed after the gossip_chat migration.

**Architecture:** Domain gains `BleAddress` and `ScanCandidate` value objects plus a first-write-wins `ConnectionRegistry.tryRegister`. `BlueyPort` exposes a streaming scan + post-connect identify API. `ConnectionService` replaces its timer-driven discovery round with a long-lived scan subscription that races to connect and dedup-by-address. `BlueyPortImpl` keeps its bluey-typed handles infrastructure-private via an address-to-Device map.

**Tech Stack:** Dart 3, Flutter (gossip_bluey), bluey BLE library, melos, `dart test`/`flutter test`.

**Spec:** `docs/superpowers/specs/2026-05-05-bluey-scan-upgrade-discovery-design.md`

---

## File Structure

**New files:**
- `packages/gossip_bluey/lib/src/domain/value_objects/ble_address.dart` — `BleAddress` value object.
- `packages/gossip_bluey/lib/src/domain/value_objects/scan_candidate.dart` — `ScanCandidate` value object.
- `packages/gossip_bluey/test/domain/value_objects/ble_address_test.dart`
- `packages/gossip_bluey/test/domain/value_objects/scan_candidate_test.dart`

**Modified files:**
- `packages/gossip_bluey/lib/src/domain/aggregates/connection_registry.dart` — add `tryRegister` and `RegistrationResult`.
- `packages/gossip_bluey/lib/src/domain/interfaces/bluey_port.dart` — add `scanForCandidates`, `stopScan`, `connectAndIdentify`, `disconnectRole`; deprecate `discoverPeers`.
- `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart` — implement the four new methods; extract `_registerCentralConnection` private helper.
- `packages/gossip_bluey/lib/src/application/services/connection_service.dart` — replace `_runDiscoveryRound` with `_onCandidate`; switch `_onPortEvent` to `tryRegister`; replace timer with stream subscription; remove `runDiscoveryRoundForTest`.
- `packages/gossip_bluey/lib/src/facade/bluey_transport.dart` — deprecate `discoveryInterval`.
- `packages/gossip_bluey/test/fakes/fake_bluey_port.dart` — implement the four new interface methods so production code can be tested via the fake.
- `packages/gossip_bluey/test/domain/aggregates/connection_registry_test.dart` — extend with `tryRegister` cases.
- `packages/gossip_bluey/test/application/services/connection_service_test.dart` — migrate existing `runDiscoveryRoundForTest` callers to drive the scan stream; add new `_onCandidate` and race-loser tests.

---

## Task 1: `BleAddress` value object

**Files:**
- Create: `packages/gossip_bluey/lib/src/domain/value_objects/ble_address.dart`
- Test: `packages/gossip_bluey/test/domain/value_objects/ble_address_test.dart`

- [ ] **Step 1: Write failing test**

`packages/gossip_bluey/test/domain/value_objects/ble_address_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/src/domain/value_objects/ble_address.dart';

void main() {
  group('BleAddress', () {
    test('equality is value-based', () {
      expect(const BleAddress('AA:BB:CC:DD:EE:FF'),
          equals(const BleAddress('AA:BB:CC:DD:EE:FF')));
      expect(const BleAddress('AA:BB:CC:DD:EE:FF'),
          isNot(equals(const BleAddress('11:22:33:44:55:66'))));
    });

    test('hashCode matches equality', () {
      expect(const BleAddress('AA:BB:CC:DD:EE:FF').hashCode,
          equals(const BleAddress('AA:BB:CC:DD:EE:FF').hashCode));
    });

    test('toString includes value', () {
      expect(const BleAddress('AA:BB:CC:DD:EE:FF').toString(),
          contains('AA:BB:CC:DD:EE:FF'));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd packages/gossip_bluey && flutter test test/domain/value_objects/ble_address_test.dart
```
Expected: FAIL — `ble_address.dart` not found.

- [ ] **Step 3: Implement `BleAddress`**

`packages/gossip_bluey/lib/src/domain/value_objects/ble_address.dart`:
```dart
class BleAddress {
  final String value;
  const BleAddress(this.value);

  @override
  bool operator ==(Object other) =>
      other is BleAddress && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'BleAddress($value)';
}
```

- [ ] **Step 4: Verify test passes**

```bash
cd packages/gossip_bluey && flutter test test/domain/value_objects/ble_address_test.dart
```
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/gossip_bluey/lib/src/domain/value_objects/ble_address.dart \
        packages/gossip_bluey/test/domain/value_objects/ble_address_test.dart
git commit -m "feat(gossip_bluey): add BleAddress value object"
```

---

## Task 2: `ScanCandidate` value object

**Files:**
- Create: `packages/gossip_bluey/lib/src/domain/value_objects/scan_candidate.dart`
- Test: `packages/gossip_bluey/test/domain/value_objects/scan_candidate_test.dart`

- [ ] **Step 1: Write failing test**

`packages/gossip_bluey/test/domain/value_objects/scan_candidate_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/src/domain/value_objects/ble_address.dart';
import 'package:gossip_bluey/src/domain/value_objects/scan_candidate.dart';

void main() {
  group('ScanCandidate', () {
    const address = BleAddress('AA:BB:CC:DD:EE:FF');

    test('constructs with required address and optional displayName', () {
      const c = ScanCandidate(address: address, displayName: 'phone');
      expect(c.address, equals(address));
      expect(c.displayName, equals('phone'));
    });

    test('displayName is optional', () {
      const c = ScanCandidate(address: address);
      expect(c.displayName, isNull);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd packages/gossip_bluey && flutter test test/domain/value_objects/scan_candidate_test.dart
```
Expected: FAIL — `scan_candidate.dart` not found.

- [ ] **Step 3: Implement `ScanCandidate`**

`packages/gossip_bluey/lib/src/domain/value_objects/scan_candidate.dart`:
```dart
import 'ble_address.dart';

/// A device surfaced by the BLE scanner — pre-connect, NodeId not yet
/// known. Pure domain: only primitive/domain types. The infrastructure
/// adapter resolves [address] to its internal device handle when
/// connect-and-identify is invoked.
class ScanCandidate {
  final BleAddress address;
  final String? displayName;
  const ScanCandidate({required this.address, this.displayName});
}
```

- [ ] **Step 4: Verify test passes**

```bash
cd packages/gossip_bluey && flutter test test/domain/value_objects/scan_candidate_test.dart
```
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/gossip_bluey/lib/src/domain/value_objects/scan_candidate.dart \
        packages/gossip_bluey/test/domain/value_objects/scan_candidate_test.dart
git commit -m "feat(gossip_bluey): add ScanCandidate value object"
```

---

## Task 3: `ConnectionRegistry.tryRegister` + `RegistrationResult`

**Files:**
- Modify: `packages/gossip_bluey/lib/src/domain/aggregates/connection_registry.dart`
- Test: `packages/gossip_bluey/test/domain/aggregates/connection_registry_test.dart`

- [ ] **Step 1: Add failing tests**

Append to `packages/gossip_bluey/test/domain/aggregates/connection_registry_test.dart` (inside the existing `group('ConnectionRegistry', ...)`):
```dart
    group('tryRegister', () {
      final localId = NodeId('11111111-1111-1111-1111-111111111111');
      final remoteId = NodeId('22222222-2222-2222-2222-222222222222');
      final connectedAt = DateTime.utc(2026, 5, 5, 10);

      ConnectionHandle handle(NodeId id, ConnectionRole role) =>
          ConnectionHandle(nodeId: id, role: role, connectedAt: connectedAt);

      test('fresh NodeId returns Registered', () {
        final reg = ConnectionRegistry();
        final h = handle(remoteId, ConnectionRole.central);
        final result = reg.tryRegister(h);
        expect(result, isA<Registered>());
        expect((result as Registered).handle, same(h));
        expect(reg.contains(remoteId), isTrue);
      });

      test('duplicate NodeId returns DuplicateRejected with both handles', () {
        final reg = ConnectionRegistry();
        final first = handle(remoteId, ConnectionRole.central);
        final second = handle(remoteId, ConnectionRole.peripheral);
        reg.tryRegister(first);
        final result = reg.tryRegister(second);
        expect(result, isA<DuplicateRejected>());
        final rejected = result as DuplicateRejected;
        expect(rejected.existing, same(first));
        expect(rejected.attempted, same(second));
      });

      test('duplicate does not overwrite existing handle', () {
        final reg = ConnectionRegistry();
        final first = handle(remoteId, ConnectionRole.central);
        final second = handle(remoteId, ConnectionRole.peripheral);
        reg.tryRegister(first);
        reg.tryRegister(second);
        expect(reg.get(remoteId), same(first));
      });
    });
```

If the existing test file does not import `Registered`, `DuplicateRejected`, or `RegistrationResult`, leave the import line as it is — `tryRegister` returns the sealed base type from the same file.

- [ ] **Step 2: Run test to verify it fails**

```bash
cd packages/gossip_bluey && flutter test test/domain/aggregates/connection_registry_test.dart
```
Expected: FAIL — `tryRegister`, `Registered`, `DuplicateRejected` not defined.

- [ ] **Step 3: Add `RegistrationResult` and `tryRegister`**

In `packages/gossip_bluey/lib/src/domain/aggregates/connection_registry.dart`, append (do not modify the existing `add` method — it stays for backwards compat):
```dart
sealed class RegistrationResult {
  const RegistrationResult();
}

final class Registered extends RegistrationResult {
  final ConnectionHandle handle;
  const Registered(this.handle);
}

final class DuplicateRejected extends RegistrationResult {
  final ConnectionHandle existing;
  final ConnectionHandle attempted;
  const DuplicateRejected({required this.existing, required this.attempted});
}
```

Then add a method on `ConnectionRegistry`:
```dart
  /// First-write-wins registration. Returns [Registered] if [handle] was
  /// stored, or [DuplicateRejected] if a handle for this NodeId already
  /// exists (existing handle is left in place; caller should tear down
  /// the [attempted] handle's underlying connection).
  RegistrationResult tryRegister(ConnectionHandle handle) {
    final existing = _byNodeId[handle.nodeId];
    if (existing != null) {
      return DuplicateRejected(existing: existing, attempted: handle);
    }
    _byNodeId[handle.nodeId] = handle;
    return Registered(handle);
  }
```

- [ ] **Step 4: Verify test passes**

```bash
cd packages/gossip_bluey && flutter test test/domain/aggregates/connection_registry_test.dart
```
Expected: PASS (existing tests + 3 new).

- [ ] **Step 5: Commit**

```bash
git add packages/gossip_bluey/lib/src/domain/aggregates/connection_registry.dart \
        packages/gossip_bluey/test/domain/aggregates/connection_registry_test.dart
git commit -m "feat(gossip_bluey): add ConnectionRegistry.tryRegister with sealed RegistrationResult"
```

---

## Task 4: Extend `BlueyPort` interface; update `FakeBlueyPort` stubs

This task expands the domain interface. The fake must implement the new methods or the existing test suite stops compiling — so we write a minimal in-memory fake implementation here. Real `BlueyPortImpl` is updated in tasks 5–8.

**Files:**
- Modify: `packages/gossip_bluey/lib/src/domain/interfaces/bluey_port.dart`
- Modify: `packages/gossip_bluey/test/fakes/fake_bluey_port.dart`
- Modify: `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart` (stub additions only — real impl in later tasks)

- [ ] **Step 1: Add new methods to `BlueyPort` (interface only)**

In `packages/gossip_bluey/lib/src/domain/interfaces/bluey_port.dart`, add these abstract members **before** `Future<void> dispose();`:
```dart
  /// Long-lived scan filtered by the gossip service UUID. Emits a
  /// [ScanCandidate] per advertisement seen — the same device may be
  /// emitted repeatedly (BLE scans stream continuously). Caller is
  /// responsible for dedup.
  Stream<ScanCandidate> scanForCandidates({required ServiceUuid serviceUuid});

  /// Stop the active scan started by [scanForCandidates], if any.
  /// Idempotent.
  Future<void> stopScan();

  /// Connect to [candidate] and read the remote NodeId from the bluey
  /// control characteristic. Returns the NodeId on success; throws on
  /// connection failure or if the device is not a bluey peer.
  Future<NodeId> connectAndIdentify(ScanCandidate candidate);

  /// Disconnect a specific role's link to [nodeId]. Used by race-loser
  /// cleanup, where [disconnect] (which prefers central) is too coarse.
  Future<void> disconnectRole(NodeId nodeId, ConnectionRole role);
```

Add the matching imports at the top:
```dart
import '../value_objects/scan_candidate.dart';
```

Mark `discoverPeers` deprecated:
```dart
  @Deprecated('Use scanForCandidates + connectAndIdentify instead')
  Future<List<DiscoveredPeer>> discoverPeers({
    required ServiceUuid serviceUuid,
    Duration timeout = const Duration(seconds: 5),
  });
```

- [ ] **Step 2: Add stubs in `BlueyPortImpl` (real implementations follow in tasks 6–8)**

In `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart`, add at the bottom of the class (before `dispose`):
```dart
  @override
  Stream<ScanCandidate> scanForCandidates({required ServiceUuid serviceUuid}) {
    throw UnimplementedError('implemented in task 6');
  }

  @override
  Future<void> stopScan() async {
    throw UnimplementedError('implemented in task 6');
  }

  @override
  Future<NodeId> connectAndIdentify(ScanCandidate candidate) async {
    throw UnimplementedError('implemented in task 7');
  }

  @override
  Future<void> disconnectRole(NodeId nodeId, ConnectionRole role) async {
    throw UnimplementedError('implemented in task 8');
  }
```

Add the import:
```dart
import '../../domain/value_objects/scan_candidate.dart';
```

- [ ] **Step 3: Implement the new methods in `FakeBlueyPort`**

In `packages/gossip_bluey/test/fakes/fake_bluey_port.dart`:

Add imports:
```dart
import 'package:gossip_bluey/src/domain/value_objects/ble_address.dart';
import 'package:gossip_bluey/src/domain/value_objects/scan_candidate.dart';
```

Inside `FakeBlueyNetwork`, add a per-port scan controller registry helper (we route emissions via the network so multiple fakes can simulate seeing each other):
```dart
  /// Yield ScanCandidates for every advertising peer except [self].
  Iterable<ScanCandidate> scanCandidatesFor(
    ServiceUuid serviceUuid,
    NodeId self,
  ) sync* {
    for (final p in _ports.values) {
      if (p.localNodeId == self) continue;
      if (!p._isAdvertising) continue;
      if (p._advertisedServiceUuid != serviceUuid) continue;
      yield ScanCandidate(
        address: BleAddress(p.localNodeId.value),
        displayName: p._advertisedDisplayName,
      );
    }
  }
```

Inside `FakeBlueyPort`, add fields and the four method implementations:
```dart
  StreamController<ScanCandidate>? _scanController;
  bool Function(BleAddress address)? connectAndIdentifyFailureInjector;

  /// Drive a scan emission for the open scan stream (test-only). Used
  /// to deliver candidates synchronously in tests without depending on
  /// network advertise state.
  void emitScanCandidate(ScanCandidate candidate) {
    _scanController?.add(candidate);
  }

  @override
  Stream<ScanCandidate> scanForCandidates({required ServiceUuid serviceUuid}) {
    _scanController ??= StreamController<ScanCandidate>.broadcast();
    // Seed the stream with currently-advertising peers, microtask-deferred
    // so listeners attach first.
    Future<void>.microtask(() {
      for (final c in network.scanCandidatesFor(serviceUuid, localNodeId)) {
        _scanController?.add(c);
      }
    });
    return _scanController!.stream;
  }

  @override
  Future<void> stopScan() async {
    final c = _scanController;
    _scanController = null;
    await c?.close();
  }

  @override
  Future<NodeId> connectAndIdentify(ScanCandidate candidate) async {
    if (connectAndIdentifyFailureInjector?.call(candidate.address) ?? false) {
      throw StateError('test injected connectAndIdentify failure');
    }
    final target = NodeId(candidate.address.value);
    await connect(target);
    return target;
  }

  @override
  Future<void> disconnectRole(NodeId nodeId, ConnectionRole role) async {
    // The fake's connection state is role-symmetric; route through the
    // existing disconnect for simplicity.
    await disconnect(nodeId);
  }
```

Update `dispose()` to close the scan controller if open:
```dart
  @override
  Future<void> dispose() async {
    network.unregister(localNodeId);
    final c = _scanController;
    _scanController = null;
    if (c != null && !c.isClosed) await c.close();
    if (!_events.isClosed) {
      await _events.close();
    }
  }
```

- [ ] **Step 4: Verify the package still compiles and existing tests pass**

```bash
cd packages/gossip_bluey && flutter analyze
cd packages/gossip_bluey && flutter test
```
Expected: analyze clean (deprecations on `discoverPeers` callers in `ConnectionService` are OK — we'll remove those calls in task 12; for now suppress with `// ignore: deprecated_member_use_from_same_package` if they trip the analyzer); tests pass.

If the analyzer flags `BlueyPortImpl`'s `UnimplementedError`s in any test that exercises them, leave it — those paths aren't exercised yet.

- [ ] **Step 5: Commit**

```bash
git add packages/gossip_bluey/lib/src/domain/interfaces/bluey_port.dart \
        packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart \
        packages/gossip_bluey/test/fakes/fake_bluey_port.dart
git commit -m "feat(gossip_bluey): extend BlueyPort with scan/identify/disconnectRole; deprecate discoverPeers"
```

---

## Task 5: Extract `_registerCentralConnection` in `BlueyPortImpl`

Pure refactor — no behavioral change. Moves the post-connect bookkeeping (MTU negotiation, gossip data char subscription, state-change subscription, `PortPeerConnected` emission) from inside `connect(NodeId)` into a private helper that the new `connectAndIdentify` will also call.

**Files:**
- Modify: `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart`

- [ ] **Step 1: Read the existing `connect(NodeId)` body**

Re-read `bluey_port_impl.dart` lines 195–253. The block from "MTU negotiation" through `_events.add(PortPeerConnected(...))` is what we extract. The only thing that *can't* be extracted is the `_bluey.peer(...).connect()` call itself, since `connectAndIdentify` will obtain its `peerConnection` differently.

- [ ] **Step 2: Add the private helper**

Insert near the bottom of `BlueyPortImpl` (before `_cleanupCentral`):
```dart
  /// Wire the central-role bookkeeping for [target] given an already-
  /// connected [peerConnection]. Negotiates MTU, subscribes to the
  /// gossip data characteristic for incoming notifications, watches for
  /// state-change disconnects, and emits PortPeerConnected.
  Future<void> _registerCentralConnection(
    NodeId target,
    bluey.PeerConnection peerConnection,
  ) async {
    final serviceUuid = _serviceUuid;
    if (serviceUuid == null) {
      throw StateError(
        '_registerCentralConnection requires startAdvertising first',
      );
    }
    _centralConnections[target] = peerConnection;

    final caps = _bluey.capabilities;
    try {
      final desired = bluey.Mtu(caps.maxMtu, capabilities: caps);
      final negotiated = await peerConnection.connection.requestMtu(desired);
      _mtuByNode[target] = negotiated.value;
    } catch (_) {
      _mtuByNode[target] = peerConnection.connection.mtu.value;
    }

    final charUuid = GossipCharacteristicUuids.derive(
      serviceUuid,
    ).dataCharacteristic;
    final services = await peerConnection.services();
    final gossipService = services.firstWhere(
      (s) => s.uuid.toString().toLowerCase() == serviceUuid.value,
      orElse: () => throw StateError(
        'connected peer $target does not host the gossip service',
      ),
    );
    final dataCharCandidates = gossipService.characteristics().where(
      (c) => c.uuid.toString().toLowerCase() == charUuid.toLowerCase(),
    );
    if (dataCharCandidates.isEmpty) {
      throw StateError(
        'connected peer $target does not host the gossip data characteristic',
      );
    }
    final dataChar = dataCharCandidates.first;
    _centralNotifSubs[target] = dataChar.notifications.listen((bytes) {
      _events.add(PortPeerData(nodeId: target, data: bytes));
    });

    final raw = peerConnection.connection;
    _centralStateSubs[target] = raw.stateChanges.listen((state) {
      if (state == bluey.ConnectionState.disconnected &&
          _centralConnections.containsKey(target)) {
        _cleanupCentral(target, reason: 'connection dropped');
      }
    });

    _events.add(
      PortPeerConnected(nodeId: target, role: ConnectionRole.central),
    );
  }
```

- [ ] **Step 3: Refactor `connect(NodeId)` to call the helper**

Replace the body of `connect` from `final peerConnection = await blueyPeer.connect();` onward with:
```dart
  @override
  Future<void> connect(NodeId target) async {
    final serviceUuid = _serviceUuid;
    if (serviceUuid == null) {
      throw StateError(
        'connect requires startAdvertising to have been called first',
      );
    }
    final blueyPeer = _bluey.peer(bluey.ServerId(target.value));
    final peerConnection = await blueyPeer.connect();
    await _registerCentralConnection(target, peerConnection);
  }
```

- [ ] **Step 4: Run the existing test suite**

```bash
cd packages/gossip_bluey && flutter test
```
Expected: PASS (no new tests; the refactor is behavior-preserving).

- [ ] **Step 5: Commit**

```bash
git add packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart
git commit -m "refactor(gossip_bluey): extract _registerCentralConnection helper in BlueyPortImpl"
```

---

## Task 6: Implement `BlueyPortImpl.scanForCandidates` and `stopScan`

The bluey scanner emits `Stream<bluey.ScanResult>`. We map each into a `ScanCandidate` and cache the underlying `bluey.Device` in `_devicesByAddress`.

**Files:**
- Modify: `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart`

This adapter wraps the real bluey library, so it cannot be unit-tested without a live BLE host. Verification is via integration in tasks 10–13 (using the fake) plus a manual hardware run.

- [ ] **Step 1: Add scan state fields**

Inside `BlueyPortImpl`, with the other fields:
```dart
  /// Cached bluey.Device handles for scan emissions, keyed by address.
  /// Looked up by [connectAndIdentify].
  final Map<BleAddress, bluey.Device> _devicesByAddress = {};

  StreamSubscription<bluey.ScanResult>? _scanSubscription;
  StreamController<ScanCandidate>? _scanController;
```

Add the import:
```dart
import '../../domain/value_objects/ble_address.dart';
```

- [ ] **Step 2: Replace the `scanForCandidates` stub**

```dart
  @override
  Stream<ScanCandidate> scanForCandidates({required ServiceUuid serviceUuid}) {
    _scanController?.close();
    final controller = StreamController<ScanCandidate>.broadcast(
      onCancel: () => unawaited(stopScan()),
    );
    _scanController = controller;
    final scanner = _bluey.scanner();
    _scanSubscription = scanner
        .scan(services: [bluey.UUID(serviceUuid.value)])
        .listen(
      (result) {
        final address = BleAddress(result.device.address);
        _devicesByAddress[address] = result.device;
        if (!controller.isClosed) {
          controller.add(ScanCandidate(
            address: address,
            displayName: result.device.name,
          ));
        }
      },
      onError: controller.addError,
      onDone: () => unawaited(stopScan()),
    );
    return controller.stream;
  }
```

- [ ] **Step 3: Replace the `stopScan` stub**

```dart
  @override
  Future<void> stopScan() async {
    final sub = _scanSubscription;
    _scanSubscription = null;
    final controller = _scanController;
    _scanController = null;
    await sub?.cancel();
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
  }
```

- [ ] **Step 4: Update `dispose` to also stop scanning**

In `BlueyPortImpl.dispose`, before `await _events.close();`:
```dart
    await stopScan();
    _devicesByAddress.clear();
```

- [ ] **Step 5: Verify analyzer is clean**

```bash
cd packages/gossip_bluey && flutter analyze
cd packages/gossip_bluey && flutter test
```
Expected: clean; no new tests yet (real bluey not unit-testable).

- [ ] **Step 6: Commit**

```bash
git add packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart
git commit -m "feat(gossip_bluey): implement BlueyPortImpl.scanForCandidates and stopScan"
```

---

## Task 7: Implement `BlueyPortImpl.connectAndIdentify`

Looks up the `bluey.Device` by address, calls `_bluey.connectAsPeer`, derives the `NodeId` from `peer.serverId`, and registers via the shared `_registerCentralConnection` helper.

**Files:**
- Modify: `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart`

- [ ] **Step 1: Replace the `connectAndIdentify` stub**

```dart
  @override
  Future<NodeId> connectAndIdentify(ScanCandidate candidate) async {
    final device = _devicesByAddress[candidate.address];
    if (device == null) {
      throw StateError(
        'no scan-emitted device for ${candidate.address} — '
        'did the candidate come from this port\'s scanForCandidates stream?',
      );
    }
    final peerConn = await _bluey.connectAsPeer(device);
    final nodeId = NodeId(peerConn.peer.serverId.value);
    await _registerCentralConnection(nodeId, peerConn);
    return nodeId;
  }
```

- [ ] **Step 2: Verify analyzer is clean**

```bash
cd packages/gossip_bluey && flutter analyze
cd packages/gossip_bluey && flutter test
```
Expected: clean; existing tests pass.

- [ ] **Step 3: Commit**

```bash
git add packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart
git commit -m "feat(gossip_bluey): implement BlueyPortImpl.connectAndIdentify via connectAsPeer"
```

---

## Task 8: Implement `BlueyPortImpl.disconnectRole`

Role-aware disconnect. `disconnect(NodeId)` prefers central; this variant tears down whichever side the caller specifies.

**Files:**
- Modify: `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart`

- [ ] **Step 1: Replace the `disconnectRole` stub**

```dart
  @override
  Future<void> disconnectRole(NodeId nodeId, ConnectionRole role) async {
    switch (role) {
      case ConnectionRole.central:
        final central = _centralConnections[nodeId];
        if (central == null) return;
        try {
          await central.disconnect();
        } finally {
          _cleanupCentral(nodeId, reason: 'local request (role)');
        }
      case ConnectionRole.peripheral:
        final peripheral = _peripheralClients.remove(nodeId);
        if (peripheral == null) return;
        _clientIdToNodeId.remove(peripheral.client.id.toString());
        _mtuByNode.remove(nodeId);
        _events.add(
          PortPeerDisconnected(nodeId: nodeId, reason: 'local request (role)'),
        );
    }
  }
```

- [ ] **Step 2: Verify analyzer is clean**

```bash
cd packages/gossip_bluey && flutter analyze
cd packages/gossip_bluey && flutter test
```
Expected: clean; tests pass.

- [ ] **Step 3: Commit**

```bash
git add packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart
git commit -m "feat(gossip_bluey): implement BlueyPortImpl.disconnectRole"
```

---

## Task 9: `ConnectionService._onPortEvent` uses `tryRegister` (race-loser path)

Switch the central registration in `_onPortEvent` from the legacy `add(handle)` to first-write-wins `tryRegister`, and route duplicates to `port.disconnectRole`.

**Files:**
- Modify: `packages/gossip_bluey/lib/src/application/services/connection_service.dart`
- Test: `packages/gossip_bluey/test/application/services/connection_service_test.dart`

- [ ] **Step 1: Add a failing test for the race-loser scenario**

Append a new test inside the existing `group('ConnectionService', ...)`:
```dart
    test('PortPeerConnected for already-registered NodeId triggers '
        'disconnectRole on the just-arrived role; existing handle untouched',
        () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);
      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );

      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Local',
        localNodeId: localId,
      );

      // First connection: peripheral arrives via remote.connect(local).
      await remotePort.connect(localId);
      await Future<void>.delayed(Duration.zero);

      // Synthesize a duplicate central PortPeerConnected for the same
      // NodeId by directly publishing on the port event stream — this is
      // exactly what would happen if both sides race-connected.
      // For the fake, easiest path: have the local port also connect
      // back to remote, which fires PortPeerConnected(remote, central)
      // on local — duplicate.
      final disconnectsObserved = <NodeId>[];
      remotePort.disconnectAndIdentifyHook = (nid) {  // optional helper, see below
        disconnectsObserved.add(nid);
      };
      await localPort.connect(remoteId);
      await Future<void>.delayed(Duration.zero);

      // The first registration (peripheral) should still be in place.
      // The second (central) should have been disconnected by us.
      expect(localPort.connectedAsCentral, isNot(contains(remoteId)));

      await svc.dispose();
      await remotePort.dispose();
    });
```

If `connectedAsCentral` isn't already exposed on `FakeBlueyPort`, expose it as a public getter:
```dart
  Set<NodeId> get connectedAsCentral => UnmodifiableSetView(_connectedAsCentral);
```
(import `package:collection/collection.dart` and add `UnmodifiableSetView`).

If `disconnectAndIdentifyHook` doesn't exist, drop that block — it was illustrative; the assertion on `connectedAsCentral` is what actually matters.

- [ ] **Step 2: Run test to verify it fails**

```bash
cd packages/gossip_bluey && flutter test test/application/services/connection_service_test.dart -p chrome
```
(Or just `flutter test test/application/services/connection_service_test.dart`.)
Expected: FAIL — currently the second `add(handle)` overwrites silently and we'd still see the central in `connectedAsCentral`.

- [ ] **Step 3: Switch `_onPortEvent` to `tryRegister`**

In `connection_service.dart`, replace the `PortPeerConnected` case body:
```dart
      case PortPeerConnected(:final nodeId, :final role, :final displayName):
        if (maxConnections != null &&
            registry.connectionCount >= maxConnections!) {
          _errors.add(ConnectionLimitReachedError(
            message: 'rejected $nodeId: at maxConnections',
            occurredAt: _clock.now(),
            nodeId: nodeId,
          ));
          unawaited(port.disconnect(nodeId));
          return;
        }
        final handle = ConnectionHandle(
          nodeId: nodeId,
          role: role,
          displayName: displayName,
          connectedAt: _clock.now(),
        );
        switch (registry.tryRegister(handle)) {
          case DuplicateRejected():
            onLog?.call(
              LogLevel.info,
              'duplicate connection for $nodeId arrived as $role; dropping',
            );
            unawaited(port.disconnectRole(nodeId, role));
            return;
          case Registered():
            _decoders[nodeId] = FrameDecoder();
            _backoff.remove(nodeId);
            metrics.recordConnectionEstablished();
            metrics.setConnectedPeerCount(registry.connectionCount);
            _events.add(PeerOpened(nodeId: nodeId, displayName: displayName));
        }
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd packages/gossip_bluey && flutter test test/application/services/connection_service_test.dart
```
Expected: PASS (the new test plus all existing).

- [ ] **Step 5: Commit**

```bash
git add packages/gossip_bluey/lib/src/application/services/connection_service.dart \
        packages/gossip_bluey/test/application/services/connection_service_test.dart \
        packages/gossip_bluey/test/fakes/fake_bluey_port.dart
git commit -m "feat(gossip_bluey): ConnectionService uses tryRegister for first-write-wins race-loser handling"
```

---

## Task 10: `ConnectionService._onCandidate` — happy path

Introduce the candidate handler. This task only covers the simple successful flow: a scan emission triggers `connectAndIdentify`, registry receives the `NodeId`, peer is registered.

**Files:**
- Modify: `packages/gossip_bluey/lib/src/application/services/connection_service.dart`
- Modify: `packages/gossip_bluey/test/application/services/connection_service_test.dart`

- [ ] **Step 1: Add failing test**

```dart
    test('scan emission → connectAndIdentify → peer registered (happy path)',
        () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);
      final registry = ConnectionRegistry();
      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: registry,
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );

      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Local',
        localNodeId: localId,
      );
      await remotePort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Remote',
        localNodeId: remoteId,
      );

      await svc.startDiscovery();
      // Let the scan stream's microtask deliver candidates and let
      // connectAndIdentify resolve.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(registry.contains(remoteId), isTrue);

      await svc.dispose();
      await remotePort.dispose();
    });
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `startDiscovery` still uses the old timer model and never invokes the new fake's `scanForCandidates`.

- [ ] **Step 3: Add candidate-handler state and `_onCandidate` to `ConnectionService`**

Add fields near the existing discovery-related fields (`_backoff`, `_discoveryTimer`):
```dart
  StreamSubscription<ScanCandidate>? _scanSub;
  final Set<BleAddress> _connectingAddresses = {};
  final Map<BleAddress, NodeId> _addressToNodeId = {};
  final Map<BleAddress, ({Duration delay, DateTime nextAttempt})>
      _addressBackoff = {};

  static const _addressLongBackoff = Duration(minutes: 5);
```

Add imports:
```dart
import '../../domain/value_objects/ble_address.dart';
import '../../domain/value_objects/scan_candidate.dart';
```

Add the handler at the bottom of the class:
```dart
  Future<void> _onCandidate(ScanCandidate c) async {
    if (_connectingAddresses.contains(c.address)) return;
    final knownNode = _addressToNodeId[c.address];
    if (knownNode != null && registry.contains(knownNode)) return;
    final backoffEntry = _addressBackoff[c.address];
    if (backoffEntry != null && _clock.now().isBefore(backoffEntry.nextAttempt)) {
      return;
    }
    if (targetConnections != null &&
        registry.connectionCount >= targetConnections!) {
      return;
    }

    _connectingAddresses.add(c.address);
    try {
      final nodeId = await port.connectAndIdentify(c);
      _addressToNodeId[c.address] = nodeId;
      _addressBackoff.remove(c.address);

      if (_discoveryFilter != null && !_discoveryFilter!(nodeId)) {
        onLog?.call(LogLevel.debug, 'candidate $nodeId filtered; disconnecting');
        unawaited(port.disconnect(nodeId));
      }
    } finally {
      _connectingAddresses.remove(c.address);
    }
  }
```

- [ ] **Step 4: Wire `startDiscovery` to subscribe**

Replace the existing `startDiscovery` body with:
```dart
  Future<void> startDiscovery({bool Function(NodeId)? filter}) async {
    if (filter != null) {
      _discoveryFilter = filter;
    }
    if (_scanSub != null) return;
    _discoveryEnabled = true;
    _scanSub = port
        .scanForCandidates(serviceUuid: serviceUuid)
        .listen(_onCandidate);
  }
```

Replace `stopDiscovery`:
```dart
  Future<void> stopDiscovery() async {
    _discoveryEnabled = false;
    final sub = _scanSub;
    _scanSub = null;
    await sub?.cancel();
    await port.stopScan();
  }
```

Delete the now-unused `_scheduleDiscovery`, `_runDiscoveryRound`, `runDiscoveryRoundForTest`, `_discoveryTimer`, `_discoveryInterval`, and the per-NodeId `_backoff` (replaced by `_addressBackoff`). Leave `_discoveryEnabled` as a flag callers may inspect.

If the constructor still takes `discoveryInterval`, keep the parameter for source compatibility but stop using it (mark `// ignore: unused_field` on the field if needed and add a `@Deprecated` note in the docstring).

- [ ] **Step 5: Run the new test**

```bash
cd packages/gossip_bluey && flutter test test/application/services/connection_service_test.dart -P "happy path"
```
(Or `--name 'happy path'`.)
Expected: PASS.

Existing tests that called `runDiscoveryRoundForTest()` now fail to compile — this is expected, they're migrated in task 13.

- [ ] **Step 6: Commit**

```bash
git add packages/gossip_bluey/lib/src/application/services/connection_service.dart \
        packages/gossip_bluey/test/application/services/connection_service_test.dart
git commit -m "feat(gossip_bluey): ConnectionService consumes scanForCandidates stream (happy path)"
```

---

## Task 11: `_onCandidate` — in-flight guard, address cache, target cap

Three branches that should each silently ignore the emission. We add a single combined test exercising all three.

**Files:**
- Modify: `packages/gossip_bluey/test/application/services/connection_service_test.dart`

The implementation in task 10 already covered these branches; this task only adds the tests confirming behavior.

- [ ] **Step 1: Add tests**

```dart
    test('in-flight guard: same address emitted twice → connectAndIdentify '
        'invoked once', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);
      final registry = ConnectionRegistry();
      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: registry,
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );

      // Slow the fake's connectAndIdentify so the second emission arrives
      // while the first is in-flight.
      var calls = 0;
      localPort.connectAndIdentifyDelay = const Duration(milliseconds: 50);
      localPort.onConnectAndIdentify = (_) => calls++;

      await localPort.startAdvertising(
          serviceUuid: serviceUuid, displayName: 'L', localNodeId: localId);
      await remotePort.startAdvertising(
          serviceUuid: serviceUuid, displayName: 'R', localNodeId: remoteId);

      await svc.startDiscovery();
      // Emit two scan candidates for the same address back-to-back.
      final candidate = ScanCandidate(
        address: BleAddress(remoteId.value),
        displayName: 'R',
      );
      localPort.emitScanCandidate(candidate);
      localPort.emitScanCandidate(candidate);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(calls, equals(1));

      await svc.dispose();
      await remotePort.dispose();
    });

    test('address cache silences re-emission while peer remains connected',
        () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);
      final registry = ConnectionRegistry();
      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: registry,
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );
      var calls = 0;
      localPort.onConnectAndIdentify = (_) => calls++;

      await localPort.startAdvertising(
          serviceUuid: serviceUuid, displayName: 'L', localNodeId: localId);
      await remotePort.startAdvertising(
          serviceUuid: serviceUuid, displayName: 'R', localNodeId: remoteId);

      await svc.startDiscovery();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(registry.contains(remoteId), isTrue);

      // Emit again; should be silenced by the address cache.
      localPort.emitScanCandidate(ScanCandidate(
        address: BleAddress(remoteId.value),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(calls, equals(1));

      await svc.dispose();
      await remotePort.dispose();
    });

    test('targetConnections respected: candidate ignored when at cap',
        () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);
      final registry = ConnectionRegistry();
      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: registry,
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
        targetConnections: 0,
      );
      var calls = 0;
      localPort.onConnectAndIdentify = (_) => calls++;

      await localPort.startAdvertising(
          serviceUuid: serviceUuid, displayName: 'L', localNodeId: localId);
      await remotePort.startAdvertising(
          serviceUuid: serviceUuid, displayName: 'R', localNodeId: remoteId);

      await svc.startDiscovery();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls, equals(0));
      expect(registry.contains(remoteId), isFalse);

      await svc.dispose();
      await remotePort.dispose();
    });
```

These tests reference `connectAndIdentifyDelay`, `onConnectAndIdentify`, and `emitScanCandidate` on `FakeBlueyPort`.

- [ ] **Step 2: Add the test hooks to `FakeBlueyPort`**

Add fields near the existing test hooks:
```dart
  Duration connectAndIdentifyDelay = Duration.zero;
  void Function(ScanCandidate candidate)? onConnectAndIdentify;
```

Update `connectAndIdentify`:
```dart
  @override
  Future<NodeId> connectAndIdentify(ScanCandidate candidate) async {
    onConnectAndIdentify?.call(candidate);
    if (connectAndIdentifyDelay > Duration.zero) {
      await Future<void>.delayed(connectAndIdentifyDelay);
    }
    if (connectAndIdentifyFailureInjector?.call(candidate.address) ?? false) {
      throw StateError('test injected connectAndIdentify failure');
    }
    final target = NodeId(candidate.address.value);
    await connect(target);
    return target;
  }
```

`emitScanCandidate` already exists from task 4.

- [ ] **Step 3: Run tests**

```bash
cd packages/gossip_bluey && flutter test test/application/services/connection_service_test.dart
```
Expected: the three new tests pass; pre-existing tests that use `runDiscoveryRoundForTest` are still failing (handled in task 13).

- [ ] **Step 4: Commit**

```bash
git add packages/gossip_bluey/test/application/services/connection_service_test.dart \
        packages/gossip_bluey/test/fakes/fake_bluey_port.dart
git commit -m "test(gossip_bluey): in-flight, address-cache, and target-cap behavior of _onCandidate"
```

---

## Task 12: `_onCandidate` — backoff on failure (transient + NotABlueyPeerException)

**Files:**
- Modify: `packages/gossip_bluey/lib/src/application/services/connection_service.dart`
- Modify: `packages/gossip_bluey/test/application/services/connection_service_test.dart`
- Modify: `packages/gossip_bluey/test/fakes/fake_bluey_port.dart`

- [ ] **Step 1: Add failing tests**

```dart
    test('transient connectAndIdentify failure → exponential backoff',
        () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);
      final registry = ConnectionRegistry();
      final clock = _ManualClock(DateTime.utc(2026, 5, 5, 12));
      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: registry,
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
        clock: clock,
      );

      var failCount = 0;
      localPort.connectAndIdentifyFailureInjector = (_) {
        failCount++;
        return true;
      };

      await localPort.startAdvertising(
          serviceUuid: serviceUuid, displayName: 'L', localNodeId: localId);
      await remotePort.startAdvertising(
          serviceUuid: serviceUuid, displayName: 'R', localNodeId: remoteId);

      await svc.startDiscovery();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(failCount, equals(1));

      // Re-emit immediately; should be silenced by backoff.
      final candidate = ScanCandidate(address: BleAddress(remoteId.value));
      localPort.emitScanCandidate(candidate);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(failCount, equals(1));

      // Advance clock past initial 1s backoff; emission should retry.
      clock.advance(const Duration(seconds: 2));
      localPort.emitScanCandidate(candidate);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(failCount, equals(2));

      await svc.dispose();
      await remotePort.dispose();
    });

    test('NotABlueyPeerException → long backoff', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final registry = ConnectionRegistry();
      final clock = _ManualClock(DateTime.utc(2026, 5, 5, 12));
      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: registry,
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
        clock: clock,
      );

      var calls = 0;
      localPort.notABlueyPeerInjector = (_) {
        calls++;
        return true;
      };

      await localPort.startAdvertising(
          serviceUuid: serviceUuid, displayName: 'L', localNodeId: localId);
      await svc.startDiscovery();

      final candidate = ScanCandidate(address: BleAddress(remoteId.value));
      localPort.emitScanCandidate(candidate);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls, equals(1));

      // Even an hour later, still backed off (long backoff is 5 minutes,
      // but exponential bumps may extend it; just verify <= 1 attempt
      // within 30 s).
      clock.advance(const Duration(seconds: 30));
      localPort.emitScanCandidate(candidate);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls, equals(1));

      await svc.dispose();
    });
```

- [ ] **Step 2: Add fake hooks**

In `FakeBlueyPort`:
```dart
  bool Function(BleAddress address)? notABlueyPeerInjector;
```

Update `connectAndIdentify` to honor it (above the existing failure injector):
```dart
    if (notABlueyPeerInjector?.call(candidate.address) ?? false) {
      throw NotABlueyPeerException(candidate.address);
    }
```

If `NotABlueyPeerException` is in `package:bluey/bluey.dart`, import it in the fake. If the codebase doesn't already have a domain alias, define one in the fake's file:
```dart
class NotABlueyPeerException implements Exception {
  final BleAddress address;
  NotABlueyPeerException(this.address);
}
```

(For the diagnostic test — we only need an exception type ConnectionService can pattern-match on. Real production code in BlueyPortImpl will surface bluey's actual exception; the fake mirrors the type for testing.)

- [ ] **Step 3: Catch exceptions in `_onCandidate` with backoff**

Update `_onCandidate` to add the `try/catch`:
```dart
    _connectingAddresses.add(c.address);
    try {
      final nodeId = await port.connectAndIdentify(c);
      _addressToNodeId[c.address] = nodeId;
      _addressBackoff.remove(c.address);

      if (_discoveryFilter != null && !_discoveryFilter!(nodeId)) {
        onLog?.call(LogLevel.debug,
            'candidate $nodeId filtered; disconnecting');
        unawaited(port.disconnect(nodeId));
      }
    } on NotABlueyPeerException catch (e) {
      onLog?.call(LogLevel.debug,
          'candidate ${c.address} not a bluey peer; long backoff');
      _addressBackoff[c.address] = (
        delay: _addressLongBackoff,
        nextAttempt: _clock.now().add(_addressLongBackoff),
      );
    } catch (e, st) {
      onLog?.call(LogLevel.warning,
          'connectAndIdentify failed for ${c.address}', e, st);
      final prev = _addressBackoff[c.address]?.delay ?? Duration.zero;
      final next = prev == Duration.zero
          ? _initialBackoff
          : Duration(
              milliseconds: (prev.inMilliseconds * 2).clamp(
                _initialBackoff.inMilliseconds,
                _maxBackoff.inMilliseconds,
              ),
            );
      _addressBackoff[c.address] = (
        delay: next,
        nextAttempt: _clock.now().add(next),
      );
    } finally {
      _connectingAddresses.remove(c.address);
    }
```

`_initialBackoff` and `_maxBackoff` are existing static constants — keep them. Import `NotABlueyPeerException` from the fake's path for tests OR define it in domain (preferable). For now, define an alias in `connection_service.dart`:
```dart
import '../../../test/fakes/fake_bluey_port.dart' show NotABlueyPeerException;
// ❌ Production code cannot import test files. See step 4.
```

Production code can't import from `test/`. Move the exception class definition into the domain layer.

- [ ] **Step 4: Add `NotABlueyPeerException` to the domain**

Create `packages/gossip_bluey/lib/src/domain/errors/not_a_bluey_peer_exception.dart`:
```dart
import '../value_objects/ble_address.dart';

/// Thrown by [BlueyPort.connectAndIdentify] when the device successfully
/// connected at the BLE layer but does not host the bluey lifecycle
/// control service. The underlying connection has already been torn
/// down by bluey by the time this is thrown.
class NotABlueyPeerException implements Exception {
  final BleAddress address;
  const NotABlueyPeerException(this.address);

  @override
  String toString() => 'NotABlueyPeerException($address)';
}
```

Update the import in `connection_service.dart`:
```dart
import '../../domain/errors/not_a_bluey_peer_exception.dart';
```

Update `BlueyPortImpl.connectAndIdentify` to translate bluey's native exception into our domain exception:
```dart
  @override
  Future<NodeId> connectAndIdentify(ScanCandidate candidate) async {
    final device = _devicesByAddress[candidate.address];
    if (device == null) {
      throw StateError('no scan-emitted device for ${candidate.address}');
    }
    final bluey.PeerConnection peerConn;
    try {
      peerConn = await _bluey.connectAsPeer(device);
    } on bluey.NotABlueyPeerException {
      throw NotABlueyPeerException(candidate.address);
    }
    final nodeId = NodeId(peerConn.peer.serverId.value);
    await _registerCentralConnection(nodeId, peerConn);
    return nodeId;
  }
```

(If bluey's exact exception name differs, `grep` `bluey/bluey/lib/src/` for the type and adjust. The class exists per the bluey design doc — see `2026-04-28-pigeon-gatt-handle-rewrite-design.md` line 651.)

Update `FakeBlueyPort` to import the domain exception and remove the local class:
```dart
import 'package:gossip_bluey/src/domain/errors/not_a_bluey_peer_exception.dart';
```

- [ ] **Step 5: Run tests**

```bash
cd packages/gossip_bluey && flutter test test/application/services/connection_service_test.dart
```
Expected: the two new backoff tests pass.

- [ ] **Step 6: Commit**

```bash
git add packages/gossip_bluey/lib/src/domain/errors/not_a_bluey_peer_exception.dart \
        packages/gossip_bluey/lib/src/application/services/connection_service.dart \
        packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart \
        packages/gossip_bluey/test/application/services/connection_service_test.dart \
        packages/gossip_bluey/test/fakes/fake_bluey_port.dart
git commit -m "feat(gossip_bluey): _onCandidate backoff on transient failure and NotABlueyPeerException"
```

---

## Task 13: Migrate existing `runDiscoveryRoundForTest` callers

The pre-existing tests in `connection_service_test.dart` lines ~207–521 call `runDiscoveryRoundForTest()`. Now that the method is gone, each test must drive the new scan path instead.

**Files:**
- Modify: `packages/gossip_bluey/test/application/services/connection_service_test.dart`

- [ ] **Step 1: Identify the broken tests**

```bash
cd packages/gossip_bluey && flutter test test/application/services/connection_service_test.dart 2>&1 | grep -E 'COMPILE|error.*runDiscoveryRoundForTest|onDiscoverPeers'
```

Expected output: compilation errors at the line numbers identified earlier (207, 247, 290, 370, 371, 377, 378, 417, 418, 463, 464, 498, 499, 504, 513, 521).

- [ ] **Step 2: Migrate each call**

For each test that currently looks like:
```dart
await svc.startDiscovery();
await svc.runDiscoveryRoundForTest();
```

Replace with:
```dart
await svc.startDiscovery();
await Future<void>.delayed(const Duration(milliseconds: 10));
```

The microtask-deferred seed in `FakeBlueyPort.scanForCandidates` delivers existing advertising peers automatically when the scan starts; a 10ms delay is enough for the connect+register to resolve in tests.

For tests that count `discoverPeers` invocations via `localPort.onDiscoverPeers = (_) => calls++`, replace with:
```dart
localPort.onConnectAndIdentify = (_) => calls++;
```

These tests are intent-equivalent — they're checking "did we attempt another discovery round" — and `connectAndIdentify` is now the moral analog under the new model.

For the test at lines ~497–521 (transient failure backoff via NodeId-keyed `_backoff`), it's now redundant with task 12's address-keyed backoff test. Either delete it or convert it into an address-backoff test that mirrors task 12's structure. Recommended: delete and let task 12's test cover the behavior.

- [ ] **Step 3: Run the full file**

```bash
cd packages/gossip_bluey && flutter test test/application/services/connection_service_test.dart
```
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add packages/gossip_bluey/test/application/services/connection_service_test.dart
git commit -m "test(gossip_bluey): migrate ConnectionService tests from runDiscoveryRoundForTest to scan stream"
```

---

## Task 14: Deprecate `discoveryInterval` on `BlueyTransport.create`

The new model has no fixed-interval discovery rounds — scan is long-lived. Keep the parameter for source compatibility (gossip_chat passes it) but mark as deprecated.

**Files:**
- Modify: `packages/gossip_bluey/lib/src/facade/bluey_transport.dart`

- [ ] **Step 1: Mark `discoveryInterval` deprecated and stop forwarding it**

In `BlueyTransport.create`, change the parameter declaration:
```dart
    @Deprecated('No-op since the scan-upgrade migration; scan is now long-lived.')
    Duration discoveryInterval = const Duration(seconds: 30),
```

In the `ConnectionService(...)` constructor call, drop the `discoveryInterval:` argument (or pass it through if `ConnectionService` still has the parameter for backwards compat — see task 10 step 4).

- [ ] **Step 2: Verify gossip_chat still compiles**

```bash
cd /Users/joel/git/neutrinographics/gossip && melos run analyze
```
Expected: clean (or `discoveryInterval` deprecation warnings on gossip_chat callers, which are acceptable).

- [ ] **Step 3: Commit**

```bash
git add packages/gossip_bluey/lib/src/facade/bluey_transport.dart
git commit -m "chore(gossip_bluey): deprecate BlueyTransport.create discoveryInterval (now no-op)"
```

---

## Task 15: Final verification

- [ ] **Step 1: Run the full test suite**

```bash
cd /Users/joel/git/neutrinographics/gossip && melos run test
```
Expected: PASS across all packages.

- [ ] **Step 2: Run analyzer**

```bash
cd /Users/joel/git/neutrinographics/gossip && melos run analyze
```
Expected: clean.

- [ ] **Step 3: Run formatter**

```bash
cd /Users/joel/git/neutrinographics/gossip && melos run format
```

- [ ] **Step 4: Smoke-build gossip_chat**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_chat && flutter analyze
```
Expected: clean (deprecation warnings on `discoveryInterval` from task 14 are acceptable).

- [ ] **Step 5: Hardware test (manual)**

This is the actual diagnostic. With two physical Android devices:

1. Install the gossip_chat build on both.
2. On each device, observe `BlueyTransport.diagnosticEvents` and the connected-peer count.
3. Within ~10s both devices should appear in each other's `connectedPeers`.
4. Watch for connect/disconnect storms in the diagnostic event log.

**If both devices connect cleanly and stay connected:** hypothesis confirmed — `Bluey.discoverPeers` is the source of the connection issues. File an upstream bluey issue and plan to delete the deprecated `BlueyPort.discoverPeers` and `BlueyPortImpl.discoverPeers`.

**If issues persist:** hypothesis falsified. Look at handshake codec, framing, MTU, ConnectionService event handling, or gossip_chat wiring.

- [ ] **Step 6: Commit any formatting changes**

```bash
git status
# If any files changed during melos run format:
git add -A
git commit -m "chore: melos format"
```

---

## Self-Review

**Spec coverage:**
- BleAddress VO → Task 1 ✓
- ScanCandidate VO → Task 2 ✓
- ConnectionRegistry.tryRegister + RegistrationResult → Task 3 ✓
- BlueyPort interface diff (4 new methods + deprecation) → Task 4 ✓
- BlueyPortImpl: scanForCandidates/stopScan → Task 6, connectAndIdentify → Task 7, disconnectRole → Task 8, _registerCentralConnection refactor → Task 5 ✓
- ConnectionService _onCandidate (in-flight, address cache, backoff, filter, targetConnections) → Tasks 10–12 ✓
- ConnectionService _onPortEvent race-loser via tryRegister → Task 9 ✓
- BlueyTransport.create discoveryInterval deprecation → Task 14 ✓
- Test plan items (in-flight, filter, backoffs, address cache, stopDiscovery, targetConnections, tryRegister, race-loser) → Tasks 9–13 ✓
- Hardware verification → Task 15 step 5 ✓

**Placeholder scan:** No "TBD" / "implement later" / vague-error-handling phrasing. Each step has concrete code.

**Type consistency:** `BleAddress`, `ScanCandidate`, `RegistrationResult { Registered, DuplicateRejected }`, `NotABlueyPeerException` consistent across all tasks. `connectAndIdentify` returns `Future<NodeId>` everywhere. `disconnectRole(NodeId, ConnectionRole)` consistent.

One open verify-on-implementation item: **Task 12 step 4** assumes bluey throws `NotABlueyPeerException`. The exact symbol must be `grep`-confirmed in `/Users/joel/git/neutrinographics/bluey/bluey/lib/src/` before catching it. Adjust the catch type at implementation time if the name differs.
