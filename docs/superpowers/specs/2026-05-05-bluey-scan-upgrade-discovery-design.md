# gossip_bluey: swap `discoverPeers` for scan + upgrade

**Status:** Design
**Date:** 2026-05-05
**Type:** Diagnostic refactor (hypothesis-driven)

## Hypothesis

Connection issues observed after the gossip_chat migration to `gossip_bluey` are caused by `Bluey.discoverPeers`. That method is the only piece of the bluey discovery stack we use in production but has not been end-to-end tested on real hardware. Internally it executes a hidden connect → discoverServices → read ServerId → disconnect probe cycle for every scan candidate — exactly the kind of probe-and-tear-down sequence likely to leave a BLE radio in a bad state on real devices.

The bluey example app does **not** use `discoverPeers`. It uses `bluey.scanner().scan(services: [...])` (advertisement-only, no probing) followed by `bluey.connectAsPeer(device)` (connect, then read ServerId from the open connection, no disconnect on success).

This spec describes swapping `gossip_bluey`'s discovery loop to the example-app pattern. **If this fixes the connection issues, the bug lives in `Bluey.discoverPeers`. If it doesn't, `discoverPeers` is exonerated** and the bug is somewhere else in our stack.

## Scope

- `BlueyPort` (domain interface): add scan/identify methods, deprecate `discoverPeers`.
- `BlueyPortImpl` (infrastructure): implement scan/identify on top of `Bluey.scanner()` and `Bluey.connectAsPeer`.
- `ConnectionService` (application): replace the timer-based `_runDiscoveryRound` loop with a long-lived scan subscription.
- `BlueyTransport.create` (facade): no public API change beyond what's needed for tests; `discoveryInterval` becomes a no-op (left for now to avoid breaking gossip_chat).

Not in scope:
- Encoding NodeId in the BLE advertisement (would let us re-introduce pre-connect tie-break, but is a separate change).
- Star-topology specific filtering — handled today by toggling advertise/discover, unaffected by this swap.
- Removing `discoverPeers` from `BlueyPort` entirely (kept around for now; can be deleted once the diagnostic confirms the swap is the path forward).

## Background: why the model inverts

`discoverPeers` returns `List<DiscoveredPeer>` where each `DiscoveredPeer` carries the remote `NodeId`. That lets `ConnectionService` apply tie-break (`localNodeId.value < remote.value`) **before** spending a connection — only the side with the lower NodeId initiates, avoiding two simultaneous connections per pair.

With pure scan, the advertisement contains the gossip service UUID and a display name — but **not** the remote NodeId. The NodeId is only readable from a GATT control characteristic *after* the connection is open. So the new model is:

1. Both sides scan.
2. Both sides race to `connectAsPeer` whatever they see.
3. Both sides may briefly hold two redundant BLE links per pair.
4. Each side's `ConnectionRegistry` enforces its "one handle per NodeId" invariant — the second connection to register hits "already contains" and disconnects.

We accept the brief two-link race as the cost of skipping `discoverPeers`.

## DDD layering

Each addition lives in the layer where its responsibility belongs:

| Concern | Layer | Component |
|---|---|---|
| Pre-connect identity (BLE address, advertised name) | Domain | `BleAddress`, `ScanCandidate` |
| Post-connect identity uniqueness invariant | Domain (aggregate) | `ConnectionRegistry.tryRegister` + `RegistrationResult` |
| Discovery loop orchestration (scan → connect → dedup → backoff) | Application | `ConnectionService` |
| Resolving `BleAddress` to a `bluey.Device` and driving the BLE library | Infrastructure | `BlueyPortImpl` |
| Public lifecycle API | Facade | `BlueyTransport` |

No domain or application file gains a `package:bluey/` import. The `bluey.Device` handle never escapes `BlueyPortImpl` — the address-to-device map is infrastructure-private. The aggregate enforces its own first-write-wins invariant via `tryRegister` rather than the application layer reading `contains(nodeId)` and choosing what to do.

## Tie-break is gone

Tie-break existed solely to prevent the wasted concurrent connect. Once we're connecting to learn the NodeId, enforcing tie-break post-connect would be pure waste — we'd be tearing down a perfectly functional connection just to satisfy a rule whose purpose no longer applies. The race-loser branch in the registry handles deduplication; that's enough.

## One link is bidirectional

A single BLE connection carries data in both directions: central writes to the peripheral's characteristics, peripheral notifies subscribed centrals. `BlueyPort.sendData` already abstracts this — it picks `write` or `notifyTo` based on which role we hold for that NodeId. Two connections per pair is pure waste; one is sufficient and full-duplex. This is why the registry only needs one handle per NodeId regardless of role.

## New domain value objects

```dart
// domain/value_objects/ble_address.dart
class BleAddress {
  final String value;
  const BleAddress(this.value);
  @override bool operator ==(Object other) =>
      other is BleAddress && other.value == value;
  @override int get hashCode => value.hashCode;
  @override String toString() => 'BleAddress($value)';
}
```

```dart
// domain/value_objects/scan_candidate.dart
//
// A device surfaced by the BLE scanner — pre-connect, NodeId not yet
// known. Pure domain: only primitive/domain types. The infrastructure
// adapter resolves [address] to its internal device handle when
// connect-and-identify is invoked.
class ScanCandidate {
  final BleAddress address;
  final String? displayName;
  const ScanCandidate({required this.address, this.displayName});
}
```

## Interface diff: `BlueyPort`

Add four methods to the domain interface:

```dart
/// Long-lived scan filtered by the gossip service UUID. Emits a
/// [ScanCandidate] per advertisement seen — the same device may be
/// emitted repeatedly (BLE scans stream continuously). Caller is
/// responsible for dedup.
Stream<ScanCandidate> scanForCandidates({required ServiceUuid serviceUuid});

Future<void> stopScan();

/// Connect to [candidate] and read the remote NodeId from the bluey
/// control characteristic. Returns the NodeId on success; throws on
/// connection failure or if the device is not a bluey peer (in which
/// case the connection is already torn down by bluey).
Future<NodeId> connectAndIdentify(ScanCandidate candidate);

/// Disconnect a specific role's link to [nodeId]. Used by the race-loser
/// cleanup path, where [disconnect] (which prefers central) is too
/// coarse — the duplicate role may be central or peripheral.
Future<void> disconnectRole(NodeId nodeId, ConnectionRole role);
```

Mark deprecated (do not remove yet):

```dart
@Deprecated('Use scanForCandidates + connectAndIdentify instead')
Future<List<DiscoveredPeer>> discoverPeers({...});
```

`connect(NodeId)` is also deprecated for the central-initiated path (it remains usable for tests). Production central-initiate goes through `connectAndIdentify`, which already establishes and registers the connection internally.

## `BlueyPortImpl` implementation

The infrastructure adapter holds the bluey-typed device handles. A scan-emission cache maps `BleAddress → bluey.Device` so the domain `ScanCandidate` stays free of infrastructure types.

```dart
// Infrastructure-only: pre-resolved handles for connect-and-identify.
final Map<BleAddress, bluey.Device> _devicesByAddress = {};

@override
Stream<ScanCandidate> scanForCandidates({required ServiceUuid serviceUuid}) {
  final scanner = _bluey.scanner();
  return scanner.scan(services: [bluey.UUID(serviceUuid.value)]).map(
    (result) {
      final address = BleAddress(result.device.address);
      _devicesByAddress[address] = result.device;
      return ScanCandidate(
        address: address,
        displayName: result.device.name,
      );
    },
  );
}

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
  _registerCentralConnection(nodeId, peerConn);  // shared with connect(NodeId)
  return nodeId;
}
```

`_registerCentralConnection(NodeId, bluey.PeerConnection)` is the private helper extracted from the existing `connect(NodeId)` body — wires MTU negotiation, gossip data characteristic subscription, state-change sub, and emits `PortPeerConnected(nodeId, ConnectionRole.central)`. Both code paths share it.

## `ConnectionService` discovery loop

Replace the timer-driven `_runDiscoveryRound` with a long-lived stream subscription. State carried by `ConnectionService`:

```dart
StreamSubscription<ScanCandidate>? _scanSub;
final Set<BleAddress> _connectingAddresses = {};
final Map<BleAddress, NodeId> _addressToNodeId = {};
final Map<BleAddress, ({Duration delay, DateTime nextAttempt})> _addressBackoff = {};
```

Lifecycle:

```dart
Future<void> startDiscovery({bool Function(NodeId)? filter}) async {
  if (_scanSub != null) return;
  _discoveryFilter = filter;
  _scanSub = port.scanForCandidates(serviceUuid: serviceUuid).listen(_onCandidate);
}

Future<void> stopDiscovery() async {
  await _scanSub?.cancel();
  _scanSub = null;
  await port.stopScan();
}
```

Per-candidate handling:

```dart
Future<void> _onCandidate(ScanCandidate c) async {
  // Pre-connect dedup using cached address → NodeId
  final knownNode = _addressToNodeId[c.address];
  if (knownNode != null && registry.contains(knownNode)) return;

  if (_connectingAddresses.contains(c.address)) return;
  if (_inBackoff(c.address)) return;
  if (targetConnections != null &&
      registry.connectionCount >= targetConnections!) return;

  _connectingAddresses.add(c.address);
  try {
    final nodeId = await port.connectAndIdentify(c);
    _addressToNodeId[c.address] = nodeId;
    _clearBackoff(c.address);

    // Filter check is application policy, distinct from registry
    // uniqueness. Apply it here.
    if (_discoveryFilter != null && !_discoveryFilter!(nodeId)) {
      await port.disconnect(nodeId);
    }
    // Note: race-loser detection lives in _onPortEvent (see below).
    // We do NOT check registry.contains here because the
    // PortPeerConnected event our own connect produced may have
    // already been delivered by the time this await resolves —
    // checking would false-positive on our own registration.
  } on NotABlueyPeerException {
    _setBackoff(c.address, longBackoff);
  } catch (e, st) {
    onLog?.call(LogLevel.warning, 'connectAndIdentify failed for ${c.address}', e, st);
    _setBackoff(c.address, _bumpBackoff(c.address));
  } finally {
    _connectingAddresses.remove(c.address);
  }
}
```

Backoff is keyed by address (we don't know NodeId until success). Initial 1s, exponential to 30s for transient failures; long (5 min) for `NotABlueyPeerException` since that's a stable property of the device.

## Race-loser detection: encapsulate in `ConnectionRegistry`

Today `ConnectionRegistry.add(handle)` returns "the previous handle if one existed, caller is responsible for tearing it down" — this is **last-write-wins** semantics. Our race-loser scenario wants **first-write-wins**: keep the established connection, reject the duplicate.

Rather than have `_onPortEvent` reach into the aggregate's state externally (`registry.contains(nodeId)`), encapsulate the new invariant in the aggregate itself:

```dart
// domain/aggregates/connection_registry.dart

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

class ConnectionRegistry {
  // ... existing fields and add() unchanged ...

  /// First-write-wins registration. Returns [Registered] if [handle] was
  /// stored, or [DuplicateRejected] if a handle for this NodeId already
  /// exists (the existing handle is left in place; the caller should
  /// tear down [attempted]).
  RegistrationResult tryRegister(ConnectionHandle handle) {
    final existing = _byNodeId[handle.nodeId];
    if (existing != null) {
      return DuplicateRejected(existing: existing, attempted: handle);
    }
    _byNodeId[handle.nodeId] = handle;
    return Registered(handle);
  }
}
```

`_onPortEvent` becomes:

```dart
case PortPeerConnected(:final nodeId, :final role, :final displayName):
  // ... existing maxConnections check ...
  final handle = ConnectionHandle(nodeId: nodeId, role: role, ...);
  switch (registry.tryRegister(handle)) {
    case DuplicateRejected():
      onLog?.call(LogLevel.info,
        'duplicate connection for $nodeId arrived as $role; dropping');
      unawaited(port.disconnectRole(nodeId, role));
      return;
    case Registered():
      _events.add(PeerConnected(...));  // existing emit
  }
```

The aggregate now owns its uniqueness invariant; the application layer just acts on the result.

This requires a small `BlueyPort` API addition: `disconnectRole(NodeId, ConnectionRole)` — `disconnect(NodeId)` is too coarse because it picks central first, but the duplicate may be central or peripheral depending on which side won the race. `BlueyPortImpl.disconnectRole` reads from `_centralConnections` or `_peripheralClients` based on the role argument and tears down only that side.

`add()` stays for backwards compatibility with any existing callers, but the new path uses `tryRegister`.

## Existing per-NodeId backoff (`_backoff`) is retired

Today `_backoff` is keyed by NodeId because `discoverPeers` returns NodeIds. In the new model we don't have NodeId pre-connect. The address-keyed backoff above replaces it.

## Edge cases & tradeoffs

**Peripheral-side asymmetry.** When peer A connects to us as central (we're peripheral), we get a platform `Client.id`, not the BLE address. Our scan may also surface A's advertisement. We'll briefly try `connectAndIdentify(A)` → succeed → registry already contains A → disconnect. One wasted cycle per peer per direction at startup, then `_addressToNodeId` learns the mapping and silences subsequent emissions. Bounded, not loopy.

**Two-link burst at startup.** During the brief window where both sides are mid-connect, each pair holds up to four BLE links (each side's central + each side's peripheral view). Resolves within hundreds of ms. Acceptable for ≤8-device channels per the existing design constraint.

**`maxConnections` enforcement.** The hard cap check moves to `_onCandidate` (pre-connect, by registry count) and stays in `_onPortEvent` (post-connect, defensive — for peripheral connects we didn't initiate). No semantic change.

**`discoveryInterval` becomes a no-op.** Left in the constructor for source compatibility; documented as deprecated.

## Test plan

Unit tests (new, in `connection_service_test.dart` or a new file):

1. **In-flight guard.** Even if the same address is emitted multiple times in quick succession, only one `connectAndIdentify` is in-flight per address.
2. **Filter rejects → disconnect.** Filter returns false → `port.disconnect(nodeId)` called for the just-completed central connection.
3. **`NotABlueyPeerException` → long backoff.** Throws → address goes into long backoff; subsequent emissions ignored within the window.
4. **Transient failure → exponential backoff.** Generic exception → short backoff, doubles on retry, caps at 30s.
5. **Address cache silences re-emissions.** After first successful connect, repeat scan emissions of the same address are silently dropped while the NodeId remains in the registry.
6. **`stopDiscovery` cancels scan and clears in-flight tracking.** Re-starting works.
7. **`targetConnections` respected.** Once at target, candidates ignored.
8. **`ConnectionRegistry.tryRegister` API.** Fresh NodeId returns `Registered`; duplicate returns `DuplicateRejected` carrying both `existing` and `attempted` handles; existing handle untouched.
9. **`_onPortEvent` race-loser path.** When `tryRegister` returns `DuplicateRejected`, `port.disconnectRole(nodeId, role)` is called with the just-arrived role; existing handle remains in the registry.

Existing `discoverPeers`-based tests stay green (the deprecated method still works for backwards-compatible callers — `discoverPeers` itself is unchanged in `BlueyPortImpl` for now).

Integration / hardware (manual):

- **Two-device pair connects without errors.** Both devices launch gossip_chat; within ~10s both should see each other in `connectedPeers`.
- **No connect/disconnect storm.** Watch `diagnosticEvents` for the first 60s. Expect at most one to two extra connect-disconnect cycles per peer (peripheral-side asymmetry), then quiet.
- **Compare against pre-swap behavior.** Same hardware, same app, with the previous `discoverPeers`-based commit checked out — does the issue reproduce?

## Success criteria for the diagnostic

- **If the swap fixes connection issues:** hypothesis confirmed, `Bluey.discoverPeers` has a bug. Open an issue against bluey, plan to delete the deprecated `BlueyPort.discoverPeers` once the hardware test confirms the new path is stable.
- **If issues persist:** hypothesis falsified, look elsewhere (handshake codec, framing, MTU, ConnectionService event handling, gossip_chat wiring).

## Files touched

- `packages/gossip_bluey/lib/src/domain/interfaces/bluey_port.dart` — interface additions, deprecations.
- `packages/gossip_bluey/lib/src/domain/value_objects/ble_address.dart` — new value object wrapping the BLE-address string (parallels `NodeId`, `ServiceUuid`).
- `packages/gossip_bluey/lib/src/domain/value_objects/scan_candidate.dart` — new value object (pure domain; no infrastructure handle).
- `packages/gossip_bluey/lib/src/domain/aggregates/connection_registry.dart` — add `tryRegister` + `RegistrationResult` sealed hierarchy.
- `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart` — `scanForCandidates`, `connectAndIdentify`, `stopScan`, refactor `_registerCentralConnection`.
- `packages/gossip_bluey/lib/src/application/services/connection_service.dart` — replace discovery loop, add address cache + address-keyed backoff.
- `packages/gossip_bluey/test/...` — new unit tests for the candidate handler; update existing tests using `BlueyPort` fakes to add the new methods.
- `packages/gossip_bluey/lib/src/facade/bluey_transport.dart` — wire `startDiscovery`/`stopDiscovery` through to the new methods (no public API change).
