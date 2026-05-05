# gossip_bluey: dedup scan candidates against peripheral-side connections

**Status:** Design
**Date:** 2026-05-05
**Type:** Bug fix (hardware-test follow-up)
**Builds on:** `2026-05-05-bluey-scan-upgrade-discovery-design.md`

## Problem

After landing the scan+upgrade discovery swap, hardware testing revealed a tight reconnect loop on iOS when both devices run discovery simultaneously:

1. **T=0:** Android (central) → iOS (peripheral). Connection established, gossip messages flow.
2. **T=1:** iOS turns on discovery. Its scanner emits Android's advertisement.
3. **T=2:** iOS calls `port.connectAndIdentify(androidCandidate)`. `Bluey.connectAsPeer` opens a new peer connection.
4. **T=3:** iOS's `_onPortEvent` for `PortPeerConnected(android, central)` runs `tryRegister` — registry already has Android (as peripheral, from step 0) → `DuplicateRejected` → calls `disconnectRole(android, central)`.
5. **T=4:** iOS's `peerConn.disconnect()` triggers CoreBluetooth's `cancelPeripheralConnection`. Because iOS represents one peer as one `CBPeer` regardless of role, this tears down the *only* physical LL link — including the original peripheral-side handle.
6. **T=5:** iOS's bluey emits `centralDisconnections` for Android's clientId. iOS's `_onPortEvent` for `PortPeerDisconnected(android, peripheral)` runs — registered handle's role matches → registry removes Android.
7. **T=6:** Next scan emission for Android's address. iOS's `_addressToNodeId` cache has the entry, but `registry.contains(android-nodeId)` is now `false` — pre-connect dedup misses. iOS calls `connectAndIdentify` again. Loop.

This loop continues until one side is restarted. Diagnostic logs in `2026-05-05-bluey-scan-upgrade-discovery-design.md` (post-implementation followup section) show the symptom: 9–10 "central identified" cycles in 25 ms on the Android side, each followed by a duplicate-rejection + `disconnectRole` on the iOS side, each in turn re-clearing Android's lifecycle identification.

The platform-level cause (iOS CoreBluetooth peer-merge) is documented in bluey backlog entry I324. It is not a bluey bug — Bluey is exposing what CoreBluetooth provides. The fix belongs at the application layer: **don't call `connectAndIdentify` for a device we already hold a peer relationship with in the inverse role.**

## Why the existing `_addressToNodeId` cache doesn't catch this

`ConnectionService` already has the right shape of cache: `Map<BleAddress, NodeId> _addressToNodeId`. Its check in `_onCandidate` is:

```dart
final knownNode = _addressToNodeId[c.address];
if (knownNode != null && registry.contains(knownNode)) return;
```

The cache is currently populated only on the **central side**, after `connectAndIdentify` returns. It is *never* populated for peripheral-initiated connections, because the application only sees `PortPeerConnected(nodeId, peripheral)` — not the underlying BLE address of the central that connected to us.

So the case "I'm peripheral and the remote is the central" silently bypasses the dedup, exactly the case that fails on iOS.

## The fix

The information needed already exists on both platforms — it just isn't propagated through bluey's event types into our adapter:

- **Central side (we initiate):** `Device.address` from the scan result. Already wired.
- **Peripheral side (remote initiates):** `PeerClient.client.id`. On Android this is the BLE MAC. On iOS this is `CBCentral.identifier.uuidString`, which equals `CBPeripheral.identifier.uuidString` for the same physical peer (both inherit from `CBPeer.identifier`).

Both identifiers refer to *the same physical peer* per platform. Treating them as opaque-but-comparable strings (i.e. the existing `BleAddress` value object) is sufficient for dedup.

### Interface change

Extend `PortPeerConnected` with a `BleAddress` field:

```dart
final class PortPeerConnected extends BlueyPortEvent {
  final NodeId nodeId;
  final ConnectionRole role;
  final String? displayName;
  final BleAddress address;          // new
  const PortPeerConnected({
    required this.nodeId,
    required this.role,
    required this.address,
    this.displayName,
  });
}
```

Why on the connected event and not the disconnected event: dedup needs the address only at registration time. Disconnects already remove from `_addressToNodeId` lazily via the registry-removal cleanup (see below).

### `BlueyPortImpl` changes

- **Peripheral side**, in the `server.peerConnections.listen` handler:
  ```dart
  final clientId = peerClient.client.id.toString();
  final address = BleAddress(clientId);
  // ... existing _peripheralClients/_clientIdToNodeId/_mtuByNode wiring ...
  _events.add(PortPeerConnected(
    nodeId: nodeId,
    role: ConnectionRole.peripheral,
    address: address,
  ));
  ```
- **Central side**, in `_registerCentralConnection(NodeId, bluey.PeerConnection)`: we currently only know the NodeId. The `bluey.Device` came in via `connectAndIdentify(candidate)` and was looked up in `_devicesByAddress`. Add `BleAddress address` as a parameter to `_registerCentralConnection`, propagate it from `connectAndIdentify` (where we have `candidate.address`), and from `connect(NodeId target)` derive it from `_bluey.peer(...).device.address` or fall back to `BleAddress(target.value)` (the existing pattern uses NodeId as the bluey ServerId, and the `device.address` on the central side is what the platform reports — they are not the same value, but `connect(NodeId)` is now only used by tests, so the fallback is acceptable).

### `ConnectionService._onPortEvent` change

In the `PortPeerConnected` handler, after a successful `Registered` result, write to the cache:

```dart
case Registered():
  _addressToNodeId[address] = nodeId;
  _decoders[nodeId] = FrameDecoder();
  metrics.recordConnectionEstablished();
  metrics.setConnectedPeerCount(registry.connectionCount);
  _events.add(PeerOpened(nodeId: nodeId, displayName: displayName));
```

Note the cache is now written for *both* central and peripheral roles. The existing central-side `_addressToNodeId[c.address] = nodeId` write in `_onCandidate` after `connectAndIdentify` becomes redundant (the same write happens via `_onPortEvent` since `connectAndIdentify` itself emits `PortPeerConnected`). Either remove the redundant write or leave it — both are idempotent.

### `_onCandidate` is unchanged

The existing pre-connect check already does the right thing once the cache is populated for peripheral connections:

```dart
final knownNode = _addressToNodeId[c.address];
if (knownNode != null && registry.contains(knownNode)) return;
```

After this fix, on iOS:
- T=0: Android connects to iOS as central. iOS's `_onPortEvent` writes `_addressToNodeId[android-address] = android-nodeId`. Registry has android.
- T=1: iOS scans, emits `ScanCandidate(address=android-address, ...)`.
- T=2: `_onCandidate` checks the cache: known. `registry.contains(android-nodeId)` → true. Silence.
- iOS never calls `connectAndIdentify`. CoreBluetooth peer-merge never triggered. Original connection preserved.

### Cache lifecycle

The cache should not accumulate forever. Today, `_addressToNodeId` entries are written but never explicitly cleared. Disconnects do not remove them. That's fine for the central side (the cache is a hint; if the address re-emits and registry is empty, we re-attempt the connect and refresh the entry).

For the peripheral side, the same logic holds: if the peripheral disconnects (registry removes the nodeId), the next scan emission for that address misses the `registry.contains` check and proceeds to `connectAndIdentify`, which re-populates the entry. So no explicit cleanup needed — the dedup gate is `registry.contains`, not just cache presence.

We should still clear the cache in `dispose` (already done in the current implementation).

## DDD layering

| Concern | Layer | Component |
|---|---|---|
| Knowing a peripheral's BLE address pre-connect | Domain (event payload) | `PortPeerConnected.address` |
| Mapping address → NodeId for dedup | Application | `ConnectionService._addressToNodeId` |
| Resolving `BleAddress` to platform handles | Infrastructure | `BlueyPortImpl` (already does this for `_devicesByAddress`) |

No new value objects, no new ports, no new aggregates. The fix is one field on an existing event plus one extra map-write in the existing handler. The dedup invariant ("don't connect to a peer we already have") was always supposed to live in `_onCandidate`; we just plug the missing data path that lets it fire.

## Edge cases

- **Multiple peripherals share an address (impossible).** BLE addresses are unique per platform-identified peer. No risk.
- **A peripheral disconnects, then a new peripheral with the same address connects.** This is fine: `_handleClientDisconnected` flows through to `PortPeerDisconnected(role=peripheral)`, registry removes the nodeId. The cache still has `address → oldNodeId`. Next time the same address emits, `registry.contains(oldNodeId)` is false → we proceed to `connectAndIdentify`, which overwrites the cache with the (possibly new) nodeId. Self-healing.
- **A peer reconnects in a different role.** Cache gets overwritten with the new (address, nodeId) pair on the new `Registered` event. Self-healing.
- **Cache miss on first scan emission of an inbound peer.** Possible briefly: iOS receives `peerConnections`, our peerConnections handler runs synchronously, emits `PortPeerConnected`, `_onPortEvent` writes the cache. If a scan emission for the same address arrived *between* `peerConnections` firing and `_onPortEvent` processing it, the cache would still be empty. Theoretical race; in practice the BLE-level peer connection finishing and being identified takes much longer than a microtask, so by the time scan emits the address, the cache is already populated. We can ignore this edge.

## Test plan

Unit tests (in `connection_service_test.dart`):

1. **Peripheral connection populates address cache.** Stub a `PortPeerConnected(role=peripheral, address=X, nodeId=N)`; assert `_onCandidate` for a `ScanCandidate(address=X)` is silenced (no `connectAndIdentify` call).
2. **Both roles populate cache identically.** Repeat (1) with `role=central`; same assertion.
3. **Registry removal re-enables connect.** After (1), simulate `PortPeerDisconnected(role=peripheral)`; the next scan emission for X should now call `connectAndIdentify` (cache is stale but `registry.contains` gate is open).

Integration test (using `FakeBlueyPort`):

4. **Bidirectional discovery converges to one connection per pair, not a loop.** Two fakes both call `startAdvertising` + `startDiscovery`. The fake's `connect` already fires `PortPeerConnected` on both ends with role-symmetric addressing; verify each side ends up with one registered handle for the other and no further `connectAndIdentify` calls for already-known peers.

The existing duplicate-rejection test from the prior spec (`PortPeerConnected for already-registered NodeId triggers disconnectRole`) remains valuable as a defense-in-depth — even with the new dedup, race conditions where both sides simultaneously call `connectAndIdentify` before either has registered will still need the post-connect dedup. Keep that test.

## Hardware verification

Manual on iOS + Android (the original failing scenario):

1. Both devices launch gossip_chat, join same group.
2. Both run advertise + discovery simultaneously.
3. Expected: connection establishes once, persists. No tight reconnect loop. Lifecycle heartbeats stable on both sides.
4. Send a message from Android → iOS, then iOS → Android. Both directions deliver.

## Files touched

- `packages/gossip_bluey/lib/src/domain/interfaces/bluey_port.dart` — add `address: BleAddress` to `PortPeerConnected`.
- `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart` — propagate the address in both peripheral (`server.peerConnections`) and central (`_registerCentralConnection`) emit sites.
- `packages/gossip_bluey/lib/src/application/services/connection_service.dart` — write `_addressToNodeId` from `_onPortEvent` on `Registered`.
- `packages/gossip_bluey/test/fakes/fake_bluey_port.dart` — populate `address` on its synthesized `PortPeerConnected` events.
- `packages/gossip_bluey/test/application/services/connection_service_test.dart` — three new unit tests (above) plus updates to assertions that touch `PortPeerConnected` construction.

No public API change to `BlueyTransport`. No documentation changes other than possibly noting the dedup behavior in `BlueyPort.events` doc.

## Out of scope

- Encoding NodeId in BLE advertisement (option B from earlier brainstorming). Unnecessary once peripheral-side address dedup works; the address is already the deduping key.
- Reintroducing pre-connect tie-break by NodeId. Not needed — race-loser detection in `_onPortEvent` handles the (now rare) case where both sides connect simultaneously before either has a peripheral registration to dedup against.
- Fixing the bluey-side `connectAsPeer` defensive check (tracked in bluey backlog I323).
