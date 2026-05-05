# gossip_bluey peripheral-side address dedup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop iOS from triggering CoreBluetooth's peer-merge tear-down by deduping scan candidates against peripheral-side connections — populate the existing `_addressToNodeId` cache from peripheral connection events, so the pre-connect dedup in `_onCandidate` fires for inbound peers too.

**Architecture:** Thread `BleAddress` through `PortPeerConnected` events. On the peripheral side, derive the address from `peerClient.client.id` (which on every platform equals the central-side `Device.address` for the same physical peer). On the central side, propagate the address from the originating `ScanCandidate`. `ConnectionService._onPortEvent` writes the cache on every successful registration.

**Tech Stack:** Dart 3, Flutter (gossip_bluey), bluey BLE library, melos, `flutter test`.

**Spec:** `docs/superpowers/specs/2026-05-05-gossip-bluey-peripheral-address-dedup-design.md`

---

## File Structure

**Modified files only — no new files.**

- `packages/gossip_bluey/lib/src/domain/interfaces/bluey_port.dart` — add `BleAddress address` to `PortPeerConnected`.
- `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart` — populate `address` at both peripheral and central emit sites; thread `BleAddress` through `_registerCentralConnection`.
- `packages/gossip_bluey/lib/src/application/services/connection_service.dart` — write `_addressToNodeId[address] = nodeId` on the `Registered` branch of `_onPortEvent`.
- `packages/gossip_bluey/test/fakes/fake_bluey_port.dart` — populate `address` (using the peer's NodeId-as-string, mirroring real bluey's `clientId`-equals-`address` invariant) on synthesized events.
- `packages/gossip_bluey/test/application/services/connection_service_test.dart` — three new unit tests + minor updates to existing tests that touch `PortPeerConnected` payloads.

---

## Task 1: Add failing test — peripheral connection populates address cache

**Files:**
- Modify: `packages/gossip_bluey/test/application/services/connection_service_test.dart`

The test will fail to compile until Task 2 adds the `address` field. That's expected.

- [ ] **Step 1: Add the test inside the existing `group('ConnectionService', ...)`**

Insert this test after the existing `'PortPeerConnected for already-registered NodeId triggers ...'` test (around line 145):

```dart
    test('inbound peripheral registration writes address cache; '
        'subsequent scan emission for that address is silenced', () async {
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

      var connectAndIdentifyCalls = 0;
      localPort.onConnectAndIdentify = (_) => connectAndIdentifyCalls++;

      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Local',
        localNodeId: localId,
      );

      // Remote connects to us as central — we are peripheral. The fake
      // sets the address to the remote's NodeId-as-string, mirroring
      // the real-bluey invariant that clientId == device.address per
      // platform.
      await remotePort.connect(localId);
      await Future<void>.delayed(Duration.zero);
      expect(registry.contains(remoteId), isTrue);

      // Now the local side starts discovery. The fake's scanForCandidates
      // will emit a ScanCandidate for the remote (since the remote is
      // advertising). Without the dedup fix, _onCandidate would call
      // connectAndIdentify (driving the iOS CoreBluetooth peer-merge bug
      // in production). With the fix, the address cache silences it.
      await remotePort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Remote',
        localNodeId: remoteId,
      );
      await svc.startDiscovery();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(connectAndIdentifyCalls, equals(0),
          reason: 'inbound peripheral should populate address cache so the '
              'subsequent scan emission for the same address is silenced');

      await svc.dispose();
      await remotePort.dispose();
    });
```

- [ ] **Step 2: Verify the test fails**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/application/services/connection_service_test.dart --plain-name "inbound peripheral registration writes address cache" 2>&1 | tail -10
```

Expected: FAIL. The test should run but fail the `expect(connectAndIdentifyCalls, equals(0))` assertion (count will be 1, not 0) — proving the dedup is missing.

- [ ] **Step 3: Commit the failing test**

```bash
cd /Users/joel/git/neutrinographics/gossip
git add packages/gossip_bluey/test/application/services/connection_service_test.dart
git commit -m "test(gossip_bluey): failing test for inbound-peripheral address cache dedup

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

(Yes, commit a failing test on its own — small commits, easy to bisect later if regressions appear.)

---

## Task 2: Thread `BleAddress` through `PortPeerConnected` and populate the cache

This task makes the failing test pass. It touches four files atomically because adding a required field to an event type breaks compilation of every emit site simultaneously.

**Files:**
- Modify: `packages/gossip_bluey/lib/src/domain/interfaces/bluey_port.dart`
- Modify: `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart`
- Modify: `packages/gossip_bluey/lib/src/application/services/connection_service.dart`
- Modify: `packages/gossip_bluey/test/fakes/fake_bluey_port.dart`

- [ ] **Step 1: Add `address` field to `PortPeerConnected`**

In `packages/gossip_bluey/lib/src/domain/interfaces/bluey_port.dart`, replace the existing `PortPeerConnected` class with:

```dart
/// A bluey-confirmed peer is now connected (either we initiated or they
/// did). [role] tells the consumer which API to use for sends — but
/// BlueyPort.sendData hides that detail anyway. [address] is the BLE
/// address (or platform-equivalent stable peer identifier on iOS) for
/// the remote, populated from `peerClient.client.id` on the peripheral
/// side and from the originating `ScanCandidate.address` on the central
/// side. Used by ConnectionService to dedup scan candidates against
/// existing connections.
final class PortPeerConnected extends BlueyPortEvent {
  final NodeId nodeId;
  final ConnectionRole role;
  final BleAddress address;
  final String? displayName;
  const PortPeerConnected({
    required this.nodeId,
    required this.role,
    required this.address,
    this.displayName,
  });
}
```

Add the import at the top of the file (next to the existing `scan_candidate.dart` import):

```dart
import '../value_objects/ble_address.dart';
```

- [ ] **Step 2: Populate `address` at the peripheral emit site in `BlueyPortImpl`**

In `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart`, replace the `server.peerConnections.listen` body (currently around line 126):

```dart
    _serverSubs.add(
      server.peerConnections.listen((peerClient) {
        // bluey now exposes the central's real ServerId via
        // PeerClient.serverId — no synthesis needed.
        final nodeId = NodeId(peerClient.serverId.value);
        final clientIdString = peerClient.client.id.toString();
        final address = BleAddress(clientIdString);
        _peripheralClients[nodeId] = peerClient;
        _clientIdToNodeId[clientIdString] = nodeId;
        _mtuByNode[nodeId] = peerClient.client.mtu;
        _events.add(
          PortPeerConnected(
            nodeId: nodeId,
            role: ConnectionRole.peripheral,
            address: address,
          ),
        );
      }),
    );
```

- [ ] **Step 3: Thread `BleAddress` through `_registerCentralConnection`**

Still in `bluey_port_impl.dart`, change the signature of `_registerCentralConnection` to accept the address, and update both callers (`connect` and `connectAndIdentify`):

Replace `_registerCentralConnection`'s signature and final emit (the body in between is unchanged):

```dart
  Future<void> _registerCentralConnection(
    NodeId target,
    BleAddress address,
    bluey.PeerConnection peerConnection,
  ) async {
    final serviceUuid = _serviceUuid;
    if (serviceUuid == null) {
      throw StateError(
        '_registerCentralConnection requires startAdvertising first',
      );
    }
    _centralConnections[target] = peerConnection;
    // ... [unchanged MTU/services/notification/state-sub wiring] ...
    _events.add(
      PortPeerConnected(
        nodeId: target,
        role: ConnectionRole.central,
        address: address,
      ),
    );
  }
```

(Leave the body between `_centralConnections[target] = peerConnection;` and the final `_events.add(...)` exactly as it was — only the parameters and the final `_events.add` change.)

Update the caller in `connect(NodeId target)`:

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
    // connect(NodeId) is the legacy/test-only path. The platform
    // `Device.address` for a NodeId-initiated connection is not
    // accessible here; fall back to using the NodeId as the address
    // (this is acceptable because production code goes through
    // connectAndIdentify, which always has the real address).
    await _registerCentralConnection(
      target,
      BleAddress(target.value),
      peerConnection,
    );
  }
```

Update the caller in `connectAndIdentify(ScanCandidate candidate)`:

```dart
  @override
  Future<NodeId> connectAndIdentify(ScanCandidate candidate) async {
    final device = _devicesByAddress[candidate.address];
    if (device == null) {
      throw StateError(
        'no scan-emitted device for ${candidate.address} — '
        "did the candidate come from this port's scanForCandidates stream?",
      );
    }
    final bluey.PeerConnection peerConn;
    try {
      peerConn = await _bluey.connectAsPeer(device);
    } on bluey.NotABlueyPeerException {
      throw domain.NotABlueyPeerException(candidate.address);
    }
    final nodeId = NodeId(peerConn.serverId.value);
    await _registerCentralConnection(nodeId, candidate.address, peerConn);
    return nodeId;
  }
```

- [ ] **Step 4: Update `FakeBlueyPort.connect` to populate address on its synthesized events**

In `packages/gossip_bluey/test/fakes/fake_bluey_port.dart`, replace the body of `connect` (currently around line 151):

```dart
  @override
  Future<void> connect(NodeId target) async {
    if (connectFailureInjector?.call(target) ?? false) {
      _events.add(
        PortConnectFailed(nodeId: target, reason: 'test injected failure'),
      );
      throw StateError('connect failed for $target');
    }
    final remote = network.lookup(target);
    if (remote == null) {
      throw StateError('no fake port for $target');
    }
    _connectedAsCentral.add(target);
    remote._connectedAsPeripheral.add(localNodeId);
    // The fake uses each port's NodeId as its BLE address (as a string)
    // since there's no real address space — this matches the
    // FakeBlueyNetwork.scanCandidatesFor convention and lets the fake
    // honour the real-bluey invariant that clientId equals device.address
    // for the same physical peer.
    _events.add(
      PortPeerConnected(
        nodeId: target,
        role: ConnectionRole.central,
        address: BleAddress(target.value),
        displayName: remote._advertisedDisplayName,
      ),
    );
    remote._events.add(
      PortPeerConnected(
        nodeId: localNodeId,
        role: ConnectionRole.peripheral,
        address: BleAddress(localNodeId.value),
        displayName: _advertisedDisplayName,
      ),
    );
  }
```

- [ ] **Step 5: Write to `_addressToNodeId` from `_onPortEvent`**

In `packages/gossip_bluey/lib/src/application/services/connection_service.dart`, update the `PortPeerConnected` case in `_onPortEvent` (currently around line 86–122). Pattern-match on `address` and write to the cache on the `Registered` branch:

```dart
      case PortPeerConnected(
          :final nodeId,
          :final role,
          :final address,
          :final displayName,
        ):
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
            // Populate the address cache so subsequent scan emissions
            // for this peer (in the inverse role) are silenced
            // pre-connect. Critical on iOS where calling connectAsPeer
            // for a device already held in the inverse role triggers
            // CoreBluetooth's peer-merge tear-down (see
            // 2026-05-05-gossip-bluey-peripheral-address-dedup-design).
            _addressToNodeId[address] = nodeId;
            _decoders[nodeId] = FrameDecoder();
            metrics.recordConnectionEstablished();
            metrics.setConnectedPeerCount(registry.connectionCount);
            _events.add(PeerOpened(nodeId: nodeId, displayName: displayName));
        }
```

- [ ] **Step 6: Run the failing test from Task 1**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/application/services/connection_service_test.dart --plain-name "inbound peripheral registration writes address cache" 2>&1 | tail -8
```

Expected: PASS.

- [ ] **Step 7: Run the full gossip_bluey test suite**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test 2>&1 | tail -3
```

Expected: All tests pass. (The existing tests that construct `PortPeerConnected` are inside `FakeBlueyPort.connect` and `BlueyPortImpl`, both updated above. There are no other call sites.)

- [ ] **Step 8: Run analyzer**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter analyze 2>&1 | tail -5
```

Expected: `No issues found!`. If any new info-level warnings appear, fix them before committing.

- [ ] **Step 9: Commit**

```bash
cd /Users/joel/git/neutrinographics/gossip
git add packages/gossip_bluey/lib/src/domain/interfaces/bluey_port.dart \
        packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart \
        packages/gossip_bluey/lib/src/application/services/connection_service.dart \
        packages/gossip_bluey/test/fakes/fake_bluey_port.dart
git commit -m "feat(gossip_bluey): thread BleAddress through PortPeerConnected; dedup inbound peers

Without this, only central-initiated connections populated
ConnectionService._addressToNodeId, so when iOS held a peripheral
handle for a peer it would still call connectAndIdentify on the next
scan emission for that peer's address — triggering CoreBluetooth's
peer-merge tear-down (see backlog I324). Threading the address through
PortPeerConnected and writing the cache on every Registered event
closes that gap so the existing pre-connect dedup in _onCandidate
fires for inbound peripherals too.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Test — registry removal re-enables connect

After a peripheral disconnects, the cache is stale (still maps address → nodeId), but the dedup gate is `registry.contains`, not the cache. So a subsequent scan emission for that address must succeed in calling `connectAndIdentify` and refresh the entry.

**Files:**
- Modify: `packages/gossip_bluey/test/application/services/connection_service_test.dart`

- [ ] **Step 1: Add the test (after the Task 1 test)**

```dart
    test('after peripheral disconnect, scan emission re-enables connect '
        '(cache is stale but registry gate opens)', () async {
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

      var connectAndIdentifyCalls = 0;
      localPort.onConnectAndIdentify = (_) => connectAndIdentifyCalls++;

      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Local',
        localNodeId: localId,
      );

      // Inbound peripheral registration populates the cache.
      await remotePort.connect(localId);
      await Future<void>.delayed(Duration.zero);
      expect(registry.contains(remoteId), isTrue);

      // Remote disconnects — registry empties.
      await remotePort.disconnect(localId);
      await Future<void>.delayed(Duration.zero);
      expect(registry.contains(remoteId), isFalse);

      // Now we initiate discovery. The cache still has remote's address,
      // but registry no longer contains the NodeId — _onCandidate's gate
      // (`knownNode != null && registry.contains(knownNode)`) opens
      // because the registry side is false. connectAndIdentify must fire.
      await remotePort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Remote',
        localNodeId: remoteId,
      );
      await svc.startDiscovery();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(connectAndIdentifyCalls, greaterThanOrEqualTo(1));
      expect(registry.contains(remoteId), isTrue);

      await svc.dispose();
      await remotePort.dispose();
    });
```

- [ ] **Step 2: Run the test**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/application/services/connection_service_test.dart --plain-name "after peripheral disconnect" 2>&1 | tail -8
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
cd /Users/joel/git/neutrinographics/gossip
git add packages/gossip_bluey/test/application/services/connection_service_test.dart
git commit -m "test(gossip_bluey): registry-removal re-enables connect after peripheral disconnect

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Test — bidirectional discovery converges to one connection per pair

Reproduces the original failure scenario: both sides advertise + scan. With the dedup fix, neither side calls `connectAndIdentify` for a peer they already hold in the inverse role — the registry settles at one handle per peer per side, no infinite reconnect loop.

**Files:**
- Modify: `packages/gossip_bluey/test/application/services/connection_service_test.dart`

- [ ] **Step 1: Add the test**

```dart
    test('bidirectional discovery converges to one handle per pair '
        '(no reconnect loop)', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);
      final localRegistry = ConnectionRegistry();
      final remoteRegistry = ConnectionRegistry();

      final localSvc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: localRegistry,
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );
      final remoteSvc = ConnectionService(
        localNodeId: remoteId,
        port: remotePort,
        registry: remoteRegistry,
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );

      var localConnectCalls = 0;
      var remoteConnectCalls = 0;
      localPort.onConnectAndIdentify = (_) => localConnectCalls++;
      remotePort.onConnectAndIdentify = (_) => remoteConnectCalls++;

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

      // Both sides start discovery simultaneously.
      await localSvc.startDiscovery();
      await remoteSvc.startDiscovery();

      // Wait several rebroadcast cycles. With the dedup fix, the system
      // should settle quickly: one side wins the connect race, the other
      // side dedups subsequent scan emissions.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(localRegistry.contains(remoteId), isTrue);
      expect(remoteRegistry.contains(localId), isTrue);
      expect(localRegistry.connectionCount, equals(1));
      expect(remoteRegistry.connectionCount, equals(1));

      // Total connectAndIdentify calls across both sides should be small.
      // Without dedup, we'd see double-digit counts as both sides racy-
      // reconnect. With dedup, expect at most a handful (one per side
      // worst case if both attempt simultaneously before either has
      // registered).
      expect(localConnectCalls + remoteConnectCalls, lessThan(5),
          reason: 'no infinite reconnect loop');

      await localSvc.dispose();
      await remoteSvc.dispose();
    });
```

- [ ] **Step 2: Run the test**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/application/services/connection_service_test.dart --plain-name "bidirectional discovery converges" 2>&1 | tail -8
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
cd /Users/joel/git/neutrinographics/gossip
git add packages/gossip_bluey/test/application/services/connection_service_test.dart
git commit -m "test(gossip_bluey): bidirectional discovery converges to one handle per pair

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Final verification

- [ ] **Step 1: Run the full melos test suite**

```bash
cd /Users/joel/git/neutrinographics/gossip
melos run test 2>&1 | tail -8
```

Expected: SUCCESS across all packages.

- [ ] **Step 2: Run melos analyze (gossip_bluey portion)**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter analyze 2>&1 | tail -3
```

Expected: `No issues found!`. (Pre-existing warnings in `gossip_nearby` from prior work remain; this plan only owns gossip_bluey.)

- [ ] **Step 3: Run melos format**

```bash
cd /Users/joel/git/neutrinographics/gossip
melos run format 2>&1 | tail -5
```

If any files were reformatted, commit:

```bash
git status
git add -A
git commit -m "chore: melos format

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 4: Smoke-build gossip_chat**

```bash
cd /Users/joel/git/neutrinographics/gossip/examples/gossip_chat
flutter analyze 2>&1 | tail -5
```

Expected: clean (or pre-existing warnings only).

- [ ] **Step 5: Hardware verification (manual)**

Reproduce the original failure scenario:

1. Install the new gossip_chat build on both Android and iOS devices.
2. Both devices launch gossip_chat and join the same group.
3. Send a message from Android → iOS. Expect delivery.
4. Send a message from iOS → Android. Expect delivery.
5. Wait 60 s. Watch the diagnostic logs on both sides for connect/disconnect storms. Expect: lifecycle heartbeats steady, no `respondToWriteRequest failed with status 10` floods, registry stable at one peer on each side.

**Pass criterion:** Both directions deliver messages, connections persist for the full observation window.

**Fail criterion:** Reconnect loop, status-10 errors, peer-drops on either side. If this happens, capture the diagnostic logs on both sides and re-investigate — the cache may not be populated as expected, or there's a different platform interaction at play.

---

## Self-Review

**Spec coverage:**
- "Don't call `connectAndIdentify` for a device we already hold a peer relationship with in the inverse role" → Task 1 (failing test) + Task 2 (impl) ✓
- "`address: BleAddress` field on `PortPeerConnected`" → Task 2 step 1 ✓
- "Peripheral side: derive address from `peerClient.client.id`" → Task 2 step 2 ✓
- "Central side: propagate from `ScanCandidate.address`" → Task 2 step 3 ✓
- "`ConnectionService._onPortEvent` writes the cache on `Registered`" → Task 2 step 5 ✓
- Test plan items: peripheral cache write → Task 1, registry removal re-enables → Task 3, bidirectional convergence → Task 4 ✓
- Hardware verification → Task 5 step 5 ✓

**Edge cases from spec:**
- Multiple peripherals share an address (impossible per spec) — no test needed.
- Peripheral disconnects, new peer with same address connects — covered by Task 3 (cache is overwritten when next `Registered` event fires; the test asserts the registry contains the peer after re-connect).
- Peer reconnects in different role — implicit; the cache write is unconditional so the new role's address overwrites.
- Race between `peerConnections` firing and a scan emission — spec calls this theoretical; not a test case.

**Placeholder scan:** No "TBD" / "implement later" / vague-error-handling phrasing. Each step has concrete code.

**Type consistency:**
- `PortPeerConnected.address: BleAddress` (required) — Task 2 step 1.
- `_registerCentralConnection(NodeId, BleAddress, bluey.PeerConnection)` — Task 2 step 3.
- `_addressToNodeId[address] = nodeId` — Task 2 step 5, where `address` is the destructured `BleAddress` from the pattern match.
- Fake's `connect` synthesizes `BleAddress(target.value)` for central, `BleAddress(localNodeId.value)` for peripheral — Task 2 step 4. Matches `FakeBlueyNetwork.scanCandidatesFor` which already uses `BleAddress(p.localNodeId.value)`. ✓

No spec requirement is missing a task. Plan is internally consistent and ready to execute.
