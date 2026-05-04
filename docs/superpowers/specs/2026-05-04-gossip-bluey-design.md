# gossip_bluey: BLE transport for gossip atop the bluey library

**Status:** Design
**Date:** 2026-05-04
**Replaces:** `packages/gossip_ble`

## Summary

Add a new `gossip_bluey` package — a BLE transport for `gossip` built on top of [bluey](https://github.com/neutrinographics/bluey), Neutrinographics' new cross-platform BLE library. It mirrors the public surface of `gossip_nearby` so applications can swap transports with minimal API change. The existing `gossip_ble` package is removed once `gossip_bluey` is working.

## Goals

- Public-API parity with `gossip_nearby`: facade, peer events, lifecycle methods, observability hooks.
- Replace the broken `gossip_ble` (known `ambiguous_import` errors, built on the dual `bluetooth_low_energy_*` packages) with a transport that uses `bluey`'s peer-aware primitives directly.
- Support both mesh and star topologies through composable primitives — the transport stays topology-agnostic; the application chooses by enabling subsets of `startAdvertising` / `startDiscovery` and configuring peer sets accordingly.
- Survive an 8-device fully connected mesh on real BLE hardware: adaptive discovery (pause at capacity), per-`NodeId` connection backoff, soft connection target distinct from hard cap.
- DDD layered architecture matching the rest of the monorepo (facade → application → domain → infrastructure).

## Non-goals (v1)

- Encryption beyond what BLE provides natively.
- Multi-hop routing.
- Custom retention/QoS policies on the transport.
- iOS background-mode wiring.
- Multi-channel multiplexing on a single BLE connection.
- Real-device CI (matches `gossip_nearby`'s precedent — physical-device coverage lives in example apps).

## Public API

```dart
class BlueyTransport {
  static Future<BlueyTransport> create({
    required LocalNodeRepository localNodeRepository,
    required ServiceUuid serviceUuid,
    required String displayName,
    int? maxConnections,            // hard cap; reject incoming/outgoing past this
    int? targetConnections,         // soft cap; stop initiating past this. Defaults to maxConnections.
    LogCallback? onLog,
  });

  NodeId get localNodeId;
  MessagePort get messagePort;
  Stream<PeerEvent> get peerEvents;          // PeerConnected | PeerDisconnected
  Stream<ConnectionError> get errors;
  Set<NodeId> get connectedPeers;
  int get connectedPeerCount;
  BlueyMetrics get metrics;
  bool get isAdvertising;
  bool get isDiscovering;

  Future<void> startAdvertising();
  Future<void> stopAdvertising();
  Future<void> startDiscovery({bool Function(NodeId)? filter});
  Future<void> stopDiscovery();
  Future<void> disconnectAll();
  Future<void> dispose();
}

sealed class PeerEvent {}
class PeerConnected extends PeerEvent { final NodeId nodeId; ... }
class PeerDisconnected extends PeerEvent { final NodeId nodeId; ... }
```

Differences from `NearbyTransport`:

- `serviceId` (string) is replaced by `serviceUuid` (a 128-bit BLE UUID) — that's how BLE identifies services.
- `BlueyMetrics` (BLE-relevant counters: MTU negotiated, fragments sent/received, etc.) replaces `NearbyMetrics`.
- `BlueyTransport.create()` validates that `localNodeId.value` is a well-formed UUID and throws `ArgumentError` if not. Required because the value is fed directly into bluey's `ServerId` (which strictly validates UUID format). The default `InMemoryLocalNodeRepository.generateNodeId()` already produces UUID-format IDs (`Uuid().v4()`), so the standard path needs no change.

## Architecture

### Identity model

bluey provides a `ServerId` value object — a stable BLE-protocol identity for a server, decoupled from transient platform IDs (iOS session rotation, Android MAC randomization). gossip provides a `NodeId` — the identity of a peer in the gossip protocol.

**They are the same value.** At server construction time, `gossip_bluey` passes `bluey.server(identity: ServerId(localNodeId.value))`. The `ServerId` discovered over BLE *is* the `NodeId`. No translation table, no exchange, no handshake.

This eliminates the entire handshake subsystem that `gossip_nearby` requires (because Nearby Connections has no peer-identity primitive — it only has transient `endpointId`s).

### Layered structure

```
packages/gossip_bluey/lib/
  gossip_bluey.dart                                    # Public exports
  src/
    facade/
      bluey_transport.dart                             # BlueyTransport, PeerEvent
    application/
      services/
        connection_service.dart                        # Peer lifecycle orchestration
      observability/
        log_level.dart                                 # LogLevel, LogCallback
        bluey_metrics.dart                             # Counters
    domain/
      aggregates/
        connection_registry.dart                       # NodeId ↔ ConnectionHandle
      entities/
        connection_handle.dart                         # Wraps PeerConnection (central) or PeerClient (peripheral)
      value_objects/
        service_uuid.dart                              # Validated 128-bit UUID
        gossip_characteristic_uuids.dart               # Well-known UUIDs for the GATT service
      events/
        connection_event.dart                          # PeerOpened, PeerClosed
      errors/
        connection_error.dart                          # SendFailedError, ConnectionLostError, ...
      interfaces/
        bluey_port.dart                                # Domain abstraction over `Bluey` (testable)
    infrastructure/
      adapters/
        bluey_port_impl.dart                           # Wraps real `Bluey` instance
        gossip_gatt_service.dart                       # HostedService factory + write-request handler
      codec/
        frame_codec.dart                               # 4-byte length-prefix framing
      ports/
        bluey_message_port.dart                        # Implements gossip's MessagePort
```

### `BlueyPort` domain interface

`bluey` exposes the concrete `Bluey` class. `gossip_bluey` wraps it in a `BlueyPort` interface (mirroring `NearbyPort` in `gossip_nearby`) so the application layer is testable without real BLE — fakes implement `BlueyPort` directly.

The port surfaces only what `ConnectionService` needs: scanner, server, peer construction, state stream, lifecycle events. Bluey-specific types (`BlueyPeer`, `PeerConnection`, `Server`, `PeerClient`) flow through the port; `gossip_bluey` does not re-wrap them.

## Connection lifecycle

Each device runs *both* roles simultaneously: a peripheral hosting the gossip GATT service and a central scanning for other gossip-speaking peers.

### Server (peripheral) role

Started by `startAdvertising()`. Calls `bluey.server(identity: ServerId(localNodeId.value))` once at transport creation. On `startAdvertising`:

```dart
await server.startAdvertising(
  name: displayName,
  services: [serviceUuid.toBlueyUuid()],
  peerDiscoverable: true,    // include bluey lifecycle control service in advertisement
);
```

`peerDiscoverable: true` ensures `discoverPeers()` on remote devices finds us. The gossip service UUID in the advertisement filters the discovery to gossip-speaking peers.

The server registers our `HostedService` (built by `gossip_gatt_service.dart`) before advertising starts. Listens to `server.peerConnections` (only fires when a remote completes bluey's lifecycle handshake) — each emission becomes a candidate inbound peer.

### Client (central) role

Started by `startDiscovery()`. Periodically calls `bluey.discoverPeers(timeout: ..., probeTimeout: ...)`. Returned `BlueyPeer`s are filtered so only those advertising our gossip service UUID are kept.

For each kept peer, **tie-break**: only initiate `peer.connect()` if `localNodeId.value < remoteServerId.value` (lexicographic). Otherwise skip — the other side will initiate against us.

On successful `peer.connect()`:

1. Verify the gossip service is in `peerConnection.services()` (defensive — discovery filter may have lied, e.g., a peer that advertised the service but doesn't expose it).
2. Subscribe to notifications on the gossip characteristic.
3. Register in `ConnectionRegistry`.
4. Emit `PeerConnected(NodeId(peerConnection.serverId.value))`.

### Tie-break and duplicate handling

Both sides scan and advertise simultaneously. Tie-breaking by `NodeId.value` ensures only one side initiates. If a race produces duplicate connections anyway, `ConnectionRegistry` enforces NodeId uniqueness and tears down the duplicate (mirrors `gossip_nearby`'s registry).

### Disconnect

Two paths:

- **Silent peer detection.** bluey's lifecycle heartbeat (already running on every `PeerConnection`) detects silent peers in ~30s and triggers a local disconnect. `ConnectionService` listens to connection state changes and emits `PeerDisconnected`.
- **Explicit `disconnectAll()`.** Calls `peerConnection.disconnect()` for each connection — bluey's peer-protocol disconnect (courtesy write to control characteristic + platform disconnect).

### Connection caps: `maxConnections` and `targetConnections`

Two caps with distinct semantics:

- **`maxConnections` (hard cap).** Enforced in two places:
  - **Initiator side:** before calling `peer.connect()`, check `registry.connectionCount`; skip if at capacity.
  - **Responder side:** when `server.peerConnections` fires past capacity, immediately call `peerClient.disconnect()` — does not enter the registry, no `PeerConnected` emission.
- **`targetConnections` (soft cap, defaults to `maxConnections`).** Once we reach `targetConnections`, we stop *initiating* new connections (still accept inbound up to `maxConnections`). Lets a star-spoke pin to one server with `targetConnections: 1` while still allowing a mesh to fill up to `maxConnections`.

### Adaptive discovery

The discovery loop pauses scanning when `connectedPeerCount >= targetConnections` and resumes on any `PeerDisconnected`. Reasons:
- Scanning concurrent with multiple active connections degrades both on most BLE chipsets.
- Once we have enough peers, scanning is pure power and bandwidth waste.

`startDiscovery()` flips an "enabled" flag; the actual `bluey.discoverPeers()` call is gated by `connectedPeerCount < targetConnections`. `stopDiscovery()` clears the flag entirely.

### Discovery filter

`startDiscovery({bool Function(NodeId)? filter})` accepts an optional predicate. When provided, peers found by `bluey.discoverPeers()` are passed through `filter(NodeId(serverId.value))` before any connect attempt; rejected peers are silently dropped from this round of discovery. Used by star-spokes to pin to a known server `NodeId`. When `filter` is `null` (the default), all gossip-speaking peers are considered (current mesh behavior).

### Connection backoff

Per-`NodeId` exponential backoff for failed connect attempts. State lives in `ConnectionService`:

```dart
Map<NodeId, BackoffState> _backoff;  // delay, nextAttempt
```

On `peer.connect()` failure, set `delay = min(delay * 2, 30s)` (initial 1s) and `nextAttempt = now + delay`. The discovery loop skips peers whose `nextAttempt` is in the future. On successful connect, the entry is cleared. On explicit `disconnectAll()` or peer-initiated disconnect, the entry stays cleared (no penalty for a clean session).

Entries for peers we've never seen consume no memory; the map is populated lazily on first failure and pruned on `dispose()`.

## Wire format

### GATT structure

One service, one characteristic:

```
Service UUID:        <user-provided 128-bit UUID>
  Characteristic:    <fixed 128-bit UUID derived from service UUID; e.g. service[15] XOR 0x01>
    Properties:      WRITE_NO_RESPONSE | NOTIFY
```

Each peer hosts the same service. The single characteristic carries both directions, but the send/receive APIs differ by role:

- **Outgoing (we are central):** `peerConnection.connection.service(serviceUuid).characteristic(charUuid).write(bytes, withResponse: false)` — write to the remote's characteristic.
- **Outgoing (we are peripheral):** `Server.notifyTo(peerClient, charUuid, data: bytes)` — notify on our local characteristic; the central receives it via its notification subscription.
- **Incoming (we are central):** subscribe to `characteristic.notifications` on the remote — fires when the remote's `Server.notifyTo` is called.
- **Incoming (we are peripheral):** `Server.writeRequests` filtered to our characteristic UUID — fires when the central calls `characteristic.write`.

The `ConnectionRegistry` stores a `ConnectionHandle` per `NodeId` — a small wrapper around either a `PeerConnection` (central role) or a `PeerClient` (peripheral role) — that exposes a uniform `send(Uint8List)` and a notification/write-request stream. The send path picks the right bluey API based on the handle's role; everything above the registry is role-agnostic.

### Framing

Each gossip message is wrapped:

```
+--------+----------------------+
| len    | payload              |
| 4B BE  | len bytes            |
+--------+----------------------+
```

`len` is a 4-byte big-endian unsigned int. `len > 32 * 1024` triggers a decode error and connection drop (gossip's stated payload limit).

Sender splits frames into chunks of `min(MTU - 3 - safety_margin, remaining)` bytes (effective ATT payload). Writes are sequential; no interleaving. Multiple outgoing messages queue per connection.

Receiver maintains a `FrameDecoder` per connection: buffers chunks until 4-byte length is known, then accumulates until length is satisfied. Delivers complete payloads to the `MessagePort`. Surplus bytes start the next message.

### Send/receive path

**Send.** `Coordinator` calls `MessagePort.sendMessage(NodeId, bytes)` → `BlueyMessagePort` looks up the connection in `ConnectionRegistry` → `FrameCodec.encode(bytes)` produces chunks → write each chunk via the remote's gossip characteristic. Any write failure drops the connection and emits `SendFailedError`.

**Receive.** Two sources merge into one per-connection stream:

- Notifications from the remote's gossip characteristic (we're central).
- `WriteRequest`s landing on our local `Server` for that characteristic (we're peripheral).

Both feed the per-connection `FrameDecoder`. Decoded payloads flow up to `BlueyMessagePort.onMessage`.

### Errors

All errors are typed (`ConnectionError` hierarchy) and emitted on the `errors` stream — no silent catches. Decode errors (oversize frame, unexpected EOF if connection drops mid-frame) tear the connection down; gossip resyncs via anti-entropy when the peer reconnects.

## Topologies

`gossip_bluey` does not own a topology concept. The application chooses by enabling subsets of the primitives. Two patterns are explicitly supported and tested.

### Mesh (every device peers with every other)

Every device runs both roles. Tie-breaking ensures one initiator per pair.

```dart
final transport = await BlueyTransport.create(
  localNodeRepository: repo,
  serviceUuid: ServiceUuid('f0000000-...'),
  displayName: 'Phone-A',
  maxConnections: 7,    // 8-device fully connected mesh
);
await transport.startAdvertising();
await transport.startDiscovery();
```

Every other device added to the channel via `coordinator.addPeer(...)` becomes a direct gossip peer; the mesh is fully connected at the gossip layer.

### Star (one server, many spokes)

One device acts as the server (advertise only). Spokes only discover and pin to that server.

**Server:**
```dart
final server = await BlueyTransport.create(
  localNodeRepository: serverRepo,
  serviceUuid: ServiceUuid('f0000000-...'),
  displayName: 'Hub',
  maxConnections: 7,    // accept up to 7 spokes
);
await server.startAdvertising();
// no startDiscovery — server doesn't initiate
```

**Spoke:**
```dart
final serverNodeId = NodeId('<known-server-uuid>');
final spoke = await BlueyTransport.create(
  localNodeRepository: spokeRepo,
  serviceUuid: ServiceUuid('f0000000-...'),
  displayName: 'Phone-1',
  maxConnections: 1,
  targetConnections: 1,
);
// no startAdvertising — spoke doesn't accept incoming
await spoke.startDiscovery(filter: (id) => id == serverNodeId);
```

The application configures peer sets accordingly: each spoke adds *only* the server as a gossip peer; the server adds *all* spokes. Anti-entropy converges transitively through the server — no relay logic needed in the transport.

### Hybrid topologies

The same primitives compose into other shapes (tree of stars, redundant pair of servers, sparse mesh with `targetConnections < maxConnections`). The transport stays out of the way; the application decides.

## Testing strategy

### Unit tests (bulk of suite)

- **`FrameCodec`** — round-trips, MTU-sized chunking, partial-frame buffering, oversize-frame rejection (>32KB), boundary cases (1-byte payload, exactly-MTU payload, length-prefix split across chunks).
- **`ConnectionRegistry`** — NodeId-uniqueness invariants, capacity limits, lookup, removal.
- **`ConnectionService`** — full lifecycle against a fake `BlueyPort` (in-memory): discovery, tie-break logic, connect, notifications, write requests, disconnect, capacity rejection (`maxConnections`), soft-cap halt of new initiations (`targetConnections`), adaptive discovery pause/resume on capacity changes, discovery-filter rejection, per-NodeId backoff progression and clearing, error paths.
- **`BlueyMessagePort`** — adapter logic between `ConnectionService` and gossip's `MessagePort`.
- **`BlueyTransport`** — facade wiring, `startAdvertising`/`startDiscovery` state machine, `dispose` cleanup.

### Integration tests

End-to-end tests through an in-memory `FakeBlueyPort` (single fake, multiple views) verifying gossip sync without real BLE:

- **Two-node mesh** — baseline smoke test: two `BlueyTransport` instances converge on a shared channel.
- **Three-node star** — one server, two spokes pinned via `discoveryFilter`; entries originating on either spoke must converge to the other through the server.
- **Capacity behavior** — at `maxConnections` the responder rejects extra incoming; at `targetConnections` the initiator stops scanning and resumes after a disconnect.

### TDD discipline

Strict Red-Green-Refactor per the project's `CLAUDE.md`. Test count target is roughly comparable to `gossip_nearby`'s test surface; exact count emerges from TDD, not a goal.

## Migration: removing `gossip_ble`

1. Build `gossip_bluey` end-to-end (TDD, all tests green) before touching `gossip_ble`.
2. Add `bluey` (path or git dep — see Open Questions) and `gossip_bluey` to `melos.yaml` workspace.
3. Verify `gossip_bluey` works in isolation (`melos run test`, `melos run analyze`).
4. Delete `packages/gossip_ble` in a single commit. Update the root README and any monorepo docs that reference it.
5. Update `MEMORY.md` to drop the "gossip_ble has pre-existing ambiguous_import errors" note.

The two transports can coexist on `main` between steps 1 and 4 — different names, different deps, no conflict.

## Risks and open questions

- **`bluey` is unpublished.** It's not on pub.dev yet. v1 will depend on it via a path or git dependency. The `pubspec.yaml` will need `bluey: { git: https://github.com/neutrinographics/bluey.git, path: bluey }` (or similar). The dependency model can be revisited once `bluey` publishes.
- **MTU negotiation.** `bluey` exposes per-connection MTU. We use it as-is. If MTU negotiation fails or is delayed, we use the default 23-byte MTU (effective payload 20 bytes) — slow but functional. Acceptable for v1.
- **Service UUID collisions.** The user picks the gossip service UUID; `gossip_bluey` does not own one. If two unrelated apps using `gossip_bluey` pick the same UUID, they will discover each other; the gossip layer's channel/peer logic should still keep them isolated, but the BLE-level connection cost is real. Document clearly in the README.
- **iOS GATT cache staleness.** Cold-launch peers may not surface their gossip service immediately due to the central's GATT cache. bluey's `watchPeer` API handles this for the lifecycle service; we should verify our gossip service surfaces correctly on cold launch and use a similar retry pattern if not. Resolve during implementation, not design.

## Out of scope (explicit)

- Real-device CI.
- Encryption beyond BLE-native pairing.
- Multi-channel multiplexing.
- iOS background mode.
- Multi-hop / relay routing.
- Custom QoS / retention policies in the transport layer.
