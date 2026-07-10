# bluey Post-Connect Tie-Break + GSP2 Rejection Frame Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One physical BLE link per device pair in a mesh (deterministic post-connect tie-break, COR3-29) and an in-band rejection frame so capped-out peers stop gossiping into the void (COR3-21).

**Architecture:** The tie-break lives in `ConnectionManager`'s duplicate-connection branch: for any pair, the surviving link is the one where the lexicographically smaller `NodeId.value` is the central; the loser closes its *own* central link (each side's redundant central IS the other side's peripheral, so no peripheral-disconnect API is needed). The rejection frame is a new control-frame wire format (`GSP2` magic, type + reason bytes) sent on the still-live link when the capacity check rejects an inbound peripheral; the rejected central closes its own link and backs off. Old decoders skip `GSP2` bytes via the existing garbage-recovery path, so mixed versions are safe.

**Tech Stack:** Dart/Flutter (`packages/gossip_bluey`), `flutter test`, existing `FakeBlueyPort` test fake.

**Spec:** `docs/superpowers/specs/2026-07-10-bluey-tiebreak-rejection-design.md` — read it first.

## Global Constraints

- Strict TDD: write the failing test, RUN it and see it fail, then implement. Every task below is ordered that way.
- All commands run from `/Users/joel/git/neutrinographics/gossip/packages/gossip_bluey` unless stated otherwise.
- Run ONE test process at a time (concurrent `flutter test` runs starve each other on this machine). Never run `melos`.
- Production code changes only under `packages/gossip_bluey/lib/`; test code under `packages/gossip_bluey/test/`; docs per Task 9.
- Commit signing (1Password) can fail while the vault is locked ("agent returned an error"). If a commit fails, retry after asking the user to unlock — do not skip the commit.
- Known Dart footgun in this repo: `whenComplete(() => map.remove(key))` returns the removed value and deadlocks when it's the future being built. Use block bodies in callbacks.
- Final gates for every task: the named test file passes, then `flutter test` (whole package) passes, then `dart analyze` reports no issues.

---

### Task 1: GSP2 control-frame codec + `FrameDecoder.isAtFrameBoundary`

**Files:**
- Create: `lib/src/infrastructure/codec/control_frame_codec.dart`
- Modify: `lib/src/infrastructure/codec/frame_codec.dart` (add one getter)
- Test: `test/infrastructure/codec/control_frame_codec_test.dart`

**Interfaces:**
- Consumes: `kMaxFramePayload`, `FrameDecoder` from `frame_codec.dart`.
- Produces:
  - `const List<int> kControlMagicBytes` (ASCII "GSP2": `[0x47, 0x53, 0x50, 0x32]`)
  - `enum RejectionReason { capacity }` with `int wire` (capacity = 0x01) and `static RejectionReason? fromWire(int)`
  - `sealed class ControlFrame {}` / `final class ConnectionRejectedFrame extends ControlFrame { final RejectionReason reason; }`
  - `abstract final class ControlFrameCodec { static Uint8List encodeRejection(RejectionReason reason); static ControlFrame? tryParse(Uint8List data); }`
  - `bool FrameDecoder.isAtFrameBoundary` — true iff the decoder is seeking magic with an empty buffer.

- [ ] **Step 1: Write the failing tests**

Create `test/infrastructure/codec/control_frame_codec_test.dart`:

```dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/src/infrastructure/codec/control_frame_codec.dart';
import 'package:gossip_bluey/src/infrastructure/codec/frame_codec.dart';

void main() {
  group('ControlFrameCodec', () {
    test('encodeRejection produces GSP2 magic, length, type, reason', () {
      final bytes = ControlFrameCodec.encodeRejection(RejectionReason.capacity);

      // "GSP2" + u32 BE length (2: type + reason) + type 0x01 + reason 0x01
      expect(
        bytes,
        equals([0x47, 0x53, 0x50, 0x32, 0, 0, 0, 2, 0x01, 0x01]),
      );
    });

    test('tryParse round-trips a rejection frame', () {
      final bytes = ControlFrameCodec.encodeRejection(RejectionReason.capacity);
      final frame = ControlFrameCodec.tryParse(bytes);

      expect(frame, isA<ConnectionRejectedFrame>());
      expect(
        (frame! as ConnectionRejectedFrame).reason,
        RejectionReason.capacity,
      );
    });

    test('tryParse returns null for GSP1 data frames', () {
      final chunks = FrameEncoder.encode(
        Uint8List.fromList([1, 2, 3]),
        mtuPayloadSize: 200,
      );
      expect(ControlFrameCodec.tryParse(chunks.single), isNull);
    });

    test('tryParse returns null for truncated, oversized, or trailing-garbage input', () {
      final good = ControlFrameCodec.encodeRejection(RejectionReason.capacity);
      expect(ControlFrameCodec.tryParse(Uint8List.sublistView(good, 0, 9)), isNull,
          reason: 'truncated');
      expect(
        ControlFrameCodec.tryParse(Uint8List.fromList([...good, 0xFF])),
        isNull,
        reason: 'declared length must match exactly — trailing bytes mean '
            'this is not a lone control frame',
      );
      expect(ControlFrameCodec.tryParse(Uint8List(0)), isNull, reason: 'empty');
    });

    test('tryParse returns null for unknown type or reason bytes', () {
      // Unknown type 0x7F.
      expect(
        ControlFrameCodec.tryParse(
          Uint8List.fromList([0x47, 0x53, 0x50, 0x32, 0, 0, 0, 2, 0x7F, 0x01]),
        ),
        isNull,
      );
      // Known type, unknown reason 0x7F.
      expect(
        ControlFrameCodec.tryParse(
          Uint8List.fromList([0x47, 0x53, 0x50, 0x32, 0, 0, 0, 2, 0x01, 0x7F]),
        ),
        isNull,
      );
    });

    test('a GSP1 decoder skips a GSP2 frame via garbage recovery and still '
        'decodes a following GSP1 frame (mixed-version safety)', () {
      final decoder = FrameDecoder();
      final rejection = ControlFrameCodec.encodeRejection(RejectionReason.capacity);
      final payload = Uint8List.fromList([9, 8, 7]);
      final dataFrame = FrameEncoder.encode(payload, mtuPayloadSize: 200).single;

      final result = decoder.feed(Uint8List.fromList([...rejection, ...dataFrame]));

      expect(result.messages, hasLength(1));
      expect(result.messages.single, equals(payload));
      expect(result.bytesDiscarded, greaterThan(0),
          reason: 'the GSP2 bytes must be counted as discarded garbage');
    });
  });

  group('FrameDecoder.isAtFrameBoundary', () {
    test('true when idle, false mid-frame, true again after completion', () {
      final decoder = FrameDecoder();
      expect(decoder.isAtFrameBoundary, isTrue);

      final payload = Uint8List.fromList(List.filled(50, 42));
      final chunks = FrameEncoder.encode(payload, mtuPayloadSize: 20);
      decoder.feed(chunks.first);
      expect(decoder.isAtFrameBoundary, isFalse);

      for (final c in chunks.skip(1)) {
        decoder.feed(c);
      }
      expect(decoder.isAtFrameBoundary, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/infrastructure/codec/control_frame_codec_test.dart`
Expected: FAIL — `control_frame_codec.dart` does not exist / `isAtFrameBoundary` undefined.

- [ ] **Step 3: Implement the codec**

Create `lib/src/infrastructure/codec/control_frame_codec.dart`:

```dart
import 'dart:typed_data';

/// Magic prefix for CONTROL frames, ASCII "GSP2". Data frames keep the
/// "GSP1" magic byte-for-byte unchanged; a receiver without GSP2 support
/// treats a control frame as garbage and scan-recovers past it (existing,
/// tested FrameDecoder behavior), so new→old control frames are harmlessly
/// ignored. No version negotiation needed.
const List<int> kControlMagicBytes = [0x47, 0x53, 0x50, 0x32];

/// Wire values for [ConnectionRejectedFrame.reason].
enum RejectionReason {
  /// The remote is at its connection cap.
  capacity(0x01);

  const RejectionReason(this.wire);

  final int wire;

  static RejectionReason? fromWire(int byte) {
    for (final r in RejectionReason.values) {
      if (r.wire == byte) return r;
    }
    return null;
  }
}

/// A decoded control frame. Currently only rejection exists; the sealed
/// hierarchy leaves room for future control types without another wire
/// format change.
sealed class ControlFrame {
  const ControlFrame();
}

/// "Your connection was rejected — close your link." Sent by a device
/// that cannot keep an inbound peripheral link (it has no per-client
/// peripheral disconnect API); the receiving central CAN close the link
/// and must do so (COR3-21).
final class ConnectionRejectedFrame extends ControlFrame {
  final RejectionReason reason;
  const ConnectionRejectedFrame(this.reason);
}

/// Wire type byte for [ConnectionRejectedFrame].
const int _kTypeConnectionRejected = 0x01;

/// Encodes/decodes GSP2 control frames.
///
/// Wire format mirrors GSP1: `[magic 4 bytes]["length" u32 BE][payload]`
/// where the payload is `[type u8][type-specific bytes]`. Control frames
/// are always sent as a single write well under any MTU, so [tryParse]
/// requires the input to be EXACTLY one frame — a prefix match with
/// trailing bytes is not a control frame.
abstract final class ControlFrameCodec {
  static Uint8List encodeRejection(RejectionReason reason) {
    final payloadLength = 2; // type + reason
    final bytes = Uint8List(kControlMagicBytes.length + 4 + payloadLength);
    bytes.setRange(0, kControlMagicBytes.length, kControlMagicBytes);
    ByteData.view(bytes.buffer, bytes.offsetInBytes)
        .setUint32(kControlMagicBytes.length, payloadLength, Endian.big);
    bytes[8] = _kTypeConnectionRejected;
    bytes[9] = reason.wire;
    return bytes;
  }

  /// Returns the decoded control frame when [data] is exactly one valid
  /// GSP2 frame, or null otherwise (including unknown type/reason bytes —
  /// forward compatibility demands unknowns be ignored, not errored).
  static ControlFrame? tryParse(Uint8List data) {
    const headerSize = 8; // magic + length
    if (data.length < headerSize + 1) return null;
    for (var i = 0; i < kControlMagicBytes.length; i++) {
      if (data[i] != kControlMagicBytes[i]) return null;
    }
    final declared = ByteData.view(data.buffer, data.offsetInBytes)
        .getUint32(kControlMagicBytes.length, Endian.big);
    if (data.length != headerSize + declared) return null;
    switch (data[headerSize]) {
      case _kTypeConnectionRejected:
        if (declared != 2) return null;
        final reason = RejectionReason.fromWire(data[headerSize + 1]);
        if (reason == null) return null;
        return ConnectionRejectedFrame(reason);
      default:
        return null;
    }
  }
}
```

Then add the getter to `FrameDecoder` in `lib/src/infrastructure/codec/frame_codec.dart`, directly below the `_expectedLength` field (line 105):

```dart
  /// True when the decoder sits exactly between frames: no partial frame
  /// bytes buffered. Used by the control-frame dispatch to ensure GSP2
  /// detection never fires on bytes that belong inside a GSP1 payload.
  bool get isAtFrameBoundary =>
      _state == _DecoderState.seekingMagic && _buffer.isEmpty;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/infrastructure/codec/control_frame_codec_test.dart`
Expected: PASS (7 tests).

- [ ] **Step 5: Full gates, then commit**

Run: `flutter test` → all pass; `dart analyze` → no issues.

```bash
git add lib/src/infrastructure/codec/ test/infrastructure/codec/control_frame_codec_test.dart
git commit -m "feat(gossip_bluey): GSP2 control-frame codec + FrameDecoder.isAtFrameBoundary"
```

---

### Task 2: `ConnectionManager` learns its own NodeId

**Files:**
- Modify: `lib/src/application/services/connection_manager.dart:34-51` (constructor), `:63` (fields)
- Modify: `lib/src/facade/bluey_transport.dart:92` and `:137` (the two `ConnectionManager(` construction sites)
- Modify: every test/harness that constructs `ConnectionManager(` (find with `grep -rn "ConnectionManager(" test/`)

**Interfaces:**
- Produces: `ConnectionManager` gains `required NodeId localNodeId` constructor parameter and a `final NodeId localNodeId` field. Task 3 depends on it.

The tie-break compares the local NodeId with the remote's; `ConnectionManager` currently doesn't know its own identity. Pure plumbing — behavior arrives in Task 3, so the gate here is "everything still compiles and passes".

- [ ] **Step 1: Add the field and parameter**

In `lib/src/application/services/connection_manager.dart`, extend the constructor and fields:

```dart
  ConnectionManager({
    required this.port,
    required this.registry,
    required this.metrics,
    required this.localNodeId,
    this.maxConnections,
    this.onLog,
    this.sendTimeout = defaultSendTimeout,
    Clock? clock,
  }) : _clock = clock ?? const Clock() {
```

and next to the other fields (after `final BlueyMetrics metrics;`):

```dart
  /// This device's own identity — the tie-break (Task 3) compares it
  /// against the remote NodeId to pick the surviving link in a mutual
  /// connect.
  final NodeId localNodeId;
```

- [ ] **Step 2: Wire the two facade construction sites**

In `lib/src/facade/bluey_transport.dart` the site near line 92 sits inside `create()` where the local id is the variable `nodeId`; the site near line 137 sits inside `testing()` where it is the parameter `localNodeId`. Add to each call respectively:

```dart
      localNodeId: nodeId,        // create() site, ~line 92
```
```dart
      localNodeId: localNodeId,   // testing() site, ~line 137
```

- [ ] **Step 3: Update every test construction site**

Run: `grep -rn "ConnectionManager(" test/`
For each hit (expected in `test/application/services/connection_manager_test.dart`, `connection_manager_identity_test.dart`, `resilience_test.dart`, `test/integration/_adverse_link_harness.dart`, possibly others), add a `localNodeId:` argument using that test's existing local-node value if it has one, else `NodeId('local-node')`.

- [ ] **Step 4: Full gates, then commit**

Run: `flutter test` → all pass; `dart analyze` → no issues.

```bash
git add lib/src/application/services/connection_manager.dart lib/src/facade/bluey_transport.dart test/
git commit -m "refactor(gossip_bluey): ConnectionManager knows its own NodeId (tie-break prerequisite)"
```

---

### Task 3: The post-connect tie-break

**Files:**
- Modify: `lib/src/application/services/connection_manager.dart:176-234` (the `PortPeerConnected` case)
- Test: `test/application/services/connection_manager_tiebreak_test.dart` (new)

**Interfaces:**
- Consumes: `localNodeId` (Task 2), `ConnectionRegistry.get/remove/tryRegister`, `_disconnectRoleGuarded(NodeId, ConnectionRole)`, `FrameDecoder`.
- Produces: behavior only. Rule for all later tasks: **the surviving link is the one whose central is the lexicographically smaller `NodeId.value`** (`localNodeId.value.compareTo(remote.value) < 0` ⇒ we must be central).

Semantics being implemented (spec table, cases 1–4). Same-role duplicates (a reconnect race, not a mutual connect) keep today's drop-the-newcomer behavior. On a registration swap the peer never disconnected at NodeId level, so NO `PeerClosed`/`PeerOpened` is emitted — consumers see continuous connectivity; the swap is logged at info. The decoder is replaced on swap (new link = new byte stream; any residue from the dying link is handled by the decoder's garbage recovery — accepted in the spec).

- [ ] **Step 1: Write the failing tests**

Create `test/application/services/connection_manager_tiebreak_test.dart`. Build on the construction pattern used in `test/application/services/connection_manager_test.dart` (same fakes; read it first). The tests drive `FakeBlueyPort`-style port events directly; use the real `FakeBlueyPort` from `test/fakes/fake_bluey_port.dart` if its event injection suffices, otherwise the file-local fake pattern the existing manager tests use.

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/application/observability/bluey_metrics.dart';
import 'package:gossip_bluey/src/application/services/connection_manager.dart';
import 'package:gossip_bluey/src/domain/aggregates/connection_registry.dart';
import 'package:gossip_bluey/src/domain/events/connection_event.dart';
import 'package:gossip_bluey/src/domain/interfaces/bluey_port.dart';
import 'package:gossip_bluey/src/domain/value_objects/ble_address.dart';

import '../../fakes/fake_bluey_port.dart';

// The tie-break rule: the surviving link is the one whose CENTRAL is the
// lexicographically smaller NodeId. 'aaa' < 'zzz', so:
//   local 'aaa' vs remote 'zzz'  → local wins  → local must be central.
//   local 'zzz' vs remote 'aaa'  → local loses → local must be peripheral.
void main() {
  late FakeBlueyNetwork network;

  setUp(() {
    network = FakeBlueyNetwork();
  });

  (ConnectionManager, FakeBlueyPort, ConnectionRegistry, List<ConnectionEvent>)
      makeManager(String localId) {
    final port = network.createPort(NodeId(localId));
    final registry = ConnectionRegistry();
    final manager = ConnectionManager(
      port: port,
      registry: registry,
      metrics: BlueyMetrics(),
      localNodeId: NodeId(localId),
    );
    final events = <ConnectionEvent>[];
    manager.events.listen(events.add);
    return (manager, port, registry, events);
  }

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  group('mutual-connect tie-break', () {
    test('case 1: registered central survives when local wins; '
        'inbound peripheral is declined', () async {
      final (_, port, registry, events) = makeManager('aaa');
      final remote = NodeId('zzz');

      port.emitPeerConnected(remote, ConnectionRole.central,
          address: const BleAddress('addr-1'));
      await pump();
      expect(registry.get(remote)!.role, ConnectionRole.central);

      port.emitPeerConnected(remote, ConnectionRole.peripheral,
          address: const BleAddress('addr-1'));
      await pump();

      expect(registry.get(remote)!.role, ConnectionRole.central,
          reason: 'winning central registration must be untouched');
      expect(
        port.disconnectRoleCalls,
        contains((remote, ConnectionRole.peripheral)),
        reason: 'the losing peripheral is declined (remote closes it '
            'physically from its end — it is the remote\'s central)',
      );
      expect(events.whereType<PeerClosed>(), isEmpty,
          reason: 'NodeId-level connectivity never flapped');
    });

    test('case 2: registered central is closed and replaced when local '
        'loses; peripheral becomes the active handle', () async {
      final (_, port, registry, events) = makeManager('zzz');
      final remote = NodeId('aaa');

      port.emitPeerConnected(remote, ConnectionRole.central,
          address: const BleAddress('addr-1'));
      await pump();

      port.emitPeerConnected(remote, ConnectionRole.peripheral,
          address: const BleAddress('addr-1'));
      await pump();

      expect(registry.get(remote)!.role, ConnectionRole.peripheral,
          reason: 'we lost: the link where the remote (smaller id) is '
              'central must survive — that is our peripheral link');
      expect(
        port.disconnectRoleCalls,
        contains((remote, ConnectionRole.central)),
        reason: 'we must close our own redundant central',
      );
      expect(events.whereType<PeerClosed>(), isEmpty);
      expect(events.whereType<PeerOpened>(), hasLength(1),
          reason: 'no PeerOpened re-emission on swap');
    });

    test('case 3: registered peripheral is replaced by late-completing '
        'central when local wins', () async {
      final (_, port, registry, events) = makeManager('aaa');
      final remote = NodeId('zzz');

      port.emitPeerConnected(remote, ConnectionRole.peripheral,
          address: const BleAddress('addr-1'));
      await pump();

      port.emitPeerConnected(remote, ConnectionRole.central,
          address: const BleAddress('addr-1'));
      await pump();

      expect(registry.get(remote)!.role, ConnectionRole.central);
      expect(
        port.disconnectRoleCalls,
        contains((remote, ConnectionRole.peripheral)),
        reason: 'the stale peripheral is marked rejected so its inbound '
            'stops flowing (remote physically closes it)',
      );
      expect(events.whereType<PeerClosed>(), isEmpty);
    });

    test('case 4: late-completing central is closed immediately when '
        'local loses; peripheral registration untouched', () async {
      final (_, port, registry, events) = makeManager('zzz');
      final remote = NodeId('aaa');

      port.emitPeerConnected(remote, ConnectionRole.peripheral,
          address: const BleAddress('addr-1'));
      await pump();
      final peripheralHandle = registry.get(remote);

      port.emitPeerConnected(remote, ConnectionRole.central,
          address: const BleAddress('addr-1'));
      await pump();

      expect(identical(registry.get(remote), peripheralHandle), isTrue,
          reason: 'surviving registration must be the SAME handle object');
      expect(
        port.disconnectRoleCalls,
        contains((remote, ConnectionRole.central)),
      );
      expect(events.whereType<PeerClosed>(), isEmpty);
    });

    test('a disconnect event for the closed loser link does not '
        'unregister the surviving link', () async {
      final (_, port, registry, _) = makeManager('zzz');
      final remote = NodeId('aaa');

      port.emitPeerConnected(remote, ConnectionRole.central,
          address: const BleAddress('addr-1'));
      await pump();
      port.emitPeerConnected(remote, ConnectionRole.peripheral,
          address: const BleAddress('addr-1'));
      await pump();

      // The physical close of our central eventually surfaces as a
      // disconnect event for the CENTRAL role. The registered handle is
      // now peripheral, so the existing role guard must ignore it.
      port.emitPeerDisconnected(remote, ConnectionRole.central, 'closed');
      await pump();

      expect(registry.contains(remote), isTrue);
      expect(registry.get(remote)!.role, ConnectionRole.peripheral);
    });

    test('same-role duplicate keeps today\'s drop-the-newcomer behavior',
        () async {
      final (_, port, registry, _) = makeManager('aaa');
      final remote = NodeId('zzz');

      port.emitPeerConnected(remote, ConnectionRole.central,
          address: const BleAddress('addr-1'));
      await pump();
      final first = registry.get(remote);

      port.emitPeerConnected(remote, ConnectionRole.central,
          address: const BleAddress('addr-2'));
      await pump();

      expect(identical(registry.get(remote), first), isTrue);
      expect(
        port.disconnectRoleCalls,
        contains((remote, ConnectionRole.central)),
      );
    });
  });
}
```

NOTE for the implementer: `FakeBlueyPort` may not yet expose `emitPeerConnected` / `emitPeerDisconnected` helpers with these exact names — check `test/fakes/fake_bluey_port.dart` first. If equivalent injection helpers exist under other names, use those in the test. If none exist, add these two thin helpers to the fake (test code, fair game):

```dart
  /// Test hook: inject a PortPeerConnected event as if the platform
  /// reported a new link.
  void emitPeerConnected(
    NodeId nodeId,
    ConnectionRole role, {
    required BleAddress address,
    String? displayName,
  }) {
    if (!_events.isClosed) {
      _events.add(PortPeerConnected(
        nodeId: nodeId,
        role: role,
        address: address,
        displayName: displayName,
      ));
    }
  }

  /// Test hook: inject a PortPeerDisconnected event.
  void emitPeerDisconnected(NodeId nodeId, ConnectionRole role, String reason) {
    if (!_events.isClosed) {
      _events.add(PortPeerDisconnected(
        nodeId: nodeId,
        role: role,
        reason: reason,
      ));
    }
  }
```

(Adjust the `PortPeerConnected`/`PortPeerDisconnected` constructor arguments to the actual event definitions in `lib/src/domain/interfaces/bluey_port.dart` — read them before writing.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/application/services/connection_manager_tiebreak_test.dart`
Expected: FAIL — cases 2/3 fail (registration not swapped), case-1/4 assertions on `disconnectRoleCalls` may pass incidentally (today's code drops any duplicate), but the swap cases must be red. If EVERYTHING passes, the test is vacuous — stop and fix the test.

- [ ] **Step 3: Implement the tie-break**

In `lib/src/application/services/connection_manager.dart`, replace the duplicate branch of `_handlePortEvent` (currently lines 184–195, the `if (registry.contains(nodeId))` block inside `case PortPeerConnected`) with:

```dart
        final existing = registry.get(nodeId);
        if (existing != null) {
          if (existing.role == role) {
            // Same-role duplicate: a reconnect race, not a mutual
            // connect. Keep first-write-wins; the port layer's
            // supersession handles genuine link replacement (COR3-5).
            onLog?.call(
              LogLevel.info,
              'duplicate $role connection for $nodeId; dropping newcomer',
            );
            _disconnectRoleGuarded(nodeId, role);
            return;
          }
          // Mutual connect: we now hold one central and one peripheral
          // link to the same peer. Tie-break (COR3-29): the surviving
          // link is the one whose CENTRAL is the lexicographically
          // smaller NodeId — the loser closes its own central, which is
          // physically the same link as the winner's peripheral, so the
          // pair converges to exactly one link with no peripheral-side
          // disconnect API.
          final localWins = localNodeId.value.compareTo(nodeId.value) < 0;
          final survivingLocalRole =
              localWins ? ConnectionRole.central : ConnectionRole.peripheral;
          if (existing.role == survivingLocalRole) {
            // Registered link survives; shed the newcomer. If the
            // newcomer is our central we close it for real; if it is our
            // peripheral this marks it rejected and the remote (the
            // loser there) closes it physically.
            onLog?.call(
              LogLevel.info,
              'tie-break for $nodeId: keeping ${existing.role} link, '
              'shedding new $role link',
            );
            _disconnectRoleGuarded(nodeId, role);
            return;
          }
          // The NEW link survives: swap the registration in place. The
          // peer never disconnected at NodeId level, so no PeerClosed/
          // PeerOpened — consumers see continuous connectivity. A fresh
          // decoder isolates the new link's byte stream; residue from
          // the dying link is absorbed by the decoder's garbage
          // recovery.
          onLog?.call(
            LogLevel.info,
            'tie-break for $nodeId: adopting new $role link, '
            'closing ${existing.role} link',
          );
          registry.remove(nodeId);
          registry.tryRegister(
            ConnectionHandle(
              nodeId: nodeId,
              role: role,
              displayName: displayName,
              connectedAt: _clock.now(),
            ),
          );
          _decoders[nodeId] = FrameDecoder();
          _disconnectRoleGuarded(nodeId, existing.role);
          return;
        }
```

(The subsequent cap-check and fresh-registration code is unchanged.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/application/services/connection_manager_tiebreak_test.dart`
Expected: PASS (7 tests).

- [ ] **Step 5: Full gates, then commit**

Run: `flutter test` → all pass (existing duplicate-handling tests in `connection_manager_test.dart` / `connection_manager_identity_test.dart` may assert the OLD role-blind duplicate behavior for opposite roles — if one fails, read it: if it encodes "newest always dropped" for an opposite-role duplicate, update it to the tie-break expectation and say so in the commit body); `dart analyze` → no issues.

```bash
git add lib/src/application/services/connection_manager.dart test/
git commit -m "feat(gossip_bluey): post-connect mesh tie-break — smaller NodeId is central (COR3-29)"
```

---

### Task 4: Send the rejection frame on capacity rejection

**Files:**
- Modify: `lib/src/application/services/connection_manager.dart` (cap branch of `_handlePortEvent`, currently lines 196–210)
- Test: `test/application/services/connection_manager_rejection_test.dart` (new)

**Interfaces:**
- Consumes: `ControlFrameCodec.encodeRejection`, `RejectionReason.capacity` (Task 1); `FakeBlueyPort.sentData` (existing recording list).
- Produces: on capacity rejection of an INBOUND PERIPHERAL link, exactly one GSP2 rejection frame is written via `port.sendData(nodeId, ...)` before the role-guarded disconnect. No frame for duplicate/tie-break rejections, none for a capacity-rejected central (we can close a central ourselves — no frame needed).

- [ ] **Step 1: Write the failing tests**

Create `test/application/services/connection_manager_rejection_test.dart` (same fixture style as Task 3's file):

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/application/observability/bluey_metrics.dart';
import 'package:gossip_bluey/src/application/services/connection_manager.dart';
import 'package:gossip_bluey/src/domain/aggregates/connection_registry.dart';
import 'package:gossip_bluey/src/domain/interfaces/bluey_port.dart';
import 'package:gossip_bluey/src/domain/value_objects/ble_address.dart';
import 'package:gossip_bluey/src/infrastructure/codec/control_frame_codec.dart';

import '../../fakes/fake_bluey_port.dart';

void main() {
  late FakeBlueyNetwork network;

  setUp(() {
    network = FakeBlueyNetwork();
  });

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  test('capacity rejection of an inbound peripheral sends one GSP2 '
      'rejection frame on the live link', () async {
    final port = network.createPort(NodeId('local'));
    final registry = ConnectionRegistry();
    // Also create the remote's port so sendData can route to it.
    network.createPort(NodeId('remote-2'));
    ConnectionManager(
      port: port,
      registry: registry,
      metrics: BlueyMetrics(),
      localNodeId: NodeId('local'),
      maxConnections: 1,
    );

    port.emitPeerConnected(NodeId('remote-1'), ConnectionRole.peripheral,
        address: const BleAddress('addr-1'));
    await pump();
    expect(registry.connectionCount, 1);

    // Second inbound peer hits the cap. NOTE: the fake's sendData
    // requires a live link record — mark it connected first.
    port.markConnectedAsPeripheralForTest(NodeId('remote-2'));
    port.emitPeerConnected(NodeId('remote-2'), ConnectionRole.peripheral,
        address: const BleAddress('addr-2'));
    await pump();

    final rejections = port.sentData
        .map(ControlFrameCodec.tryParse)
        .whereType<ConnectionRejectedFrame>()
        .toList();
    expect(rejections, hasLength(1));
    expect(rejections.single.reason, RejectionReason.capacity);
  });

  test('duplicate / tie-break rejections send NO frame', () async {
    final port = network.createPort(NodeId('aaa'));
    final registry = ConnectionRegistry();
    ConnectionManager(
      port: port,
      registry: registry,
      metrics: BlueyMetrics(),
      localNodeId: NodeId('aaa'),
    );

    port.emitPeerConnected(NodeId('zzz'), ConnectionRole.central,
        address: const BleAddress('addr-1'));
    await pump();
    port.emitPeerConnected(NodeId('zzz'), ConnectionRole.peripheral,
        address: const BleAddress('addr-1'));
    await pump();

    expect(
      port.sentData.map(ControlFrameCodec.tryParse).whereType<ControlFrame>(),
      isEmpty,
    );
  });

  test('a failed rejection-frame write is logged and does not throw',
      () async {
    final port = network.createPort(NodeId('local'));
    final registry = ConnectionRegistry();
    final logs = <String>[];
    ConnectionManager(
      port: port,
      registry: registry,
      metrics: BlueyMetrics(),
      localNodeId: NodeId('local'),
      maxConnections: 0,
      onLog: (level, message, [error, stack]) => logs.add(message),
    );

    // No link record exists for this peer → the fake's sendData throws.
    port.emitPeerConnected(NodeId('remote-1'), ConnectionRole.peripheral,
        address: const BleAddress('addr-1'));
    await pump();
    await pump();

    expect(registry.connectionCount, 0);
    expect(logs.where((m) => m.contains('rejection frame')), isNotEmpty);
  });
}
```

If `markConnectedAsPeripheralForTest` doesn't exist on the fake, add it (test code):

```dart
  /// Test hook: record an inbound link so sendData to [nodeId] routes.
  void markConnectedAsPeripheralForTest(NodeId nodeId) {
    _connectedAsPeripheral.add(nodeId);
  }
```

(Match `onLog`'s parameter list to the actual `LogCallback` typedef — read it in `lib/` before writing.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/application/services/connection_manager_rejection_test.dart`
Expected: FAIL — no rejection frame is sent (first and third tests red; second may already pass — that is fine, it pins a non-behavior).

- [ ] **Step 3: Implement the sender**

In `lib/src/application/services/connection_manager.dart`, add the import:

```dart
import '../../infrastructure/codec/control_frame_codec.dart';
```

and change the cap branch (after the `_emitError(ConnectionLimitReachedError(...))` call, before `_disconnectRoleGuarded(nodeId, role)`):

```dart
          if (role == ConnectionRole.peripheral) {
            // We cannot close an inbound peripheral link (no per-client
            // disconnect API) — tell the remote central to close it
            // (COR3-21). Best-effort single shot: on failure we are no
            // worse off than before the frame existed.
            unawaited(
              port
                  .sendData(
                    nodeId,
                    ControlFrameCodec.encodeRejection(RejectionReason.capacity),
                  )
                  .catchError((Object e, StackTrace st) {
                onLog?.call(
                  LogLevel.warning,
                  'rejection frame to $nodeId failed',
                  e,
                  st,
                );
              }),
            );
          }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/application/services/connection_manager_rejection_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Full gates, then commit**

Run: `flutter test` → all pass; `dart analyze` → no issues.

```bash
git add lib/src/application/services/connection_manager.dart test/
git commit -m "feat(gossip_bluey): send GSP2 rejection frame on capacity rejection (COR3-21 sender)"
```

---

### Task 5: Receive the rejection frame — close, emit, surface

**Files:**
- Modify: `lib/src/domain/errors/connection_error.dart` (new error class)
- Modify: `lib/gossip_bluey.dart` (export the new class alongside the other `ConnectionError`s — check how the existing ones are exported and match)
- Modify: `lib/src/application/services/connection_manager.dart` (the `PortPeerData` case, currently lines 258–280)
- Test: extend `test/application/services/connection_manager_rejection_test.dart`

**Interfaces:**
- Consumes: `ControlFrameCodec.tryParse`, `ConnectionRejectedFrame`, `FrameDecoder.isAtFrameBoundary` (Task 1).
- Produces: `final class ConnectionRejectedByPeerError extends ConnectionError` with fields `NodeId nodeId` (non-null) and `RejectionReason reason` — Task 6 subscribes to it. `PeerClosed(reason: 'rejected by peer: capacity')` emitted on the events stream.

Receiver rule: a `PortPeerData` payload is treated as a control frame ONLY when (a) the registered handle for that peer has `role == ConnectionRole.central` (we initiated; only a rejecting responder sends control frames), (b) the peer's decoder `isAtFrameBoundary` (bytes cannot belong inside a GSP1 payload), and (c) `tryParse` matches exactly. On match: unregister inline with a distinct `PeerClosed` reason, then physically close our central. The later platform disconnect event finds no matching registration and is ignored by the existing role guard.

- [ ] **Step 1: Write the failing tests**

Append to `test/application/services/connection_manager_rejection_test.dart`:

```dart
  group('rejection receiver', () {
    test('central receiving CONNECTION_REJECTED closes its link, emits '
        'PeerClosed with a distinct reason, and surfaces a typed error',
        () async {
      final port = network.createPort(NodeId('local'));
      final registry = ConnectionRegistry();
      final manager = ConnectionManager(
        port: port,
        registry: registry,
        metrics: BlueyMetrics(),
        localNodeId: NodeId('local'),
      );
      final events = <ConnectionEvent>[];
      final errors = <ConnectionError>[];
      manager.events.listen(events.add);
      manager.errors.listen(errors.add);

      final remote = NodeId('remote');
      port.emitPeerConnected(remote, ConnectionRole.central,
          address: const BleAddress('addr-1'));
      await pump();

      port.emitPeerData(
        remote,
        ControlFrameCodec.encodeRejection(RejectionReason.capacity),
      );
      await pump();

      expect(registry.contains(remote), isFalse);
      expect(
        port.disconnectRoleCalls,
        contains((remote, ConnectionRole.central)),
      );
      final closed = events.whereType<PeerClosed>().single;
      expect(closed.reason, contains('rejected by peer'));
      final rejected =
          errors.whereType<ConnectionRejectedByPeerError>().single;
      expect(rejected.nodeId, remote);
      expect(rejected.reason, RejectionReason.capacity);
    });

    test('a rejection frame on a link where we are NOT central is ignored',
        () async {
      final port = network.createPort(NodeId('local'));
      final registry = ConnectionRegistry();
      ConnectionManager(
        port: port,
        registry: registry,
        metrics: BlueyMetrics(),
        localNodeId: NodeId('local'),
      );

      final remote = NodeId('remote');
      port.emitPeerConnected(remote, ConnectionRole.peripheral,
          address: const BleAddress('addr-1'));
      await pump();

      port.emitPeerData(
        remote,
        ControlFrameCodec.encodeRejection(RejectionReason.capacity),
      );
      await pump();

      expect(registry.contains(remote), isTrue,
          reason: 'only a central acts on rejection frames');
    });

    test('GSP2-looking bytes inside a GSP1 payload are NOT treated as '
        'control frames', () async {
      final port = network.createPort(NodeId('local'));
      final registry = ConnectionRegistry();
      final manager = ConnectionManager(
        port: port,
        registry: registry,
        metrics: BlueyMetrics(),
        localNodeId: NodeId('local'),
      );
      final received = <IncomingMessage>[];
      manager.incomingMessages.listen(received.add);

      final remote = NodeId('remote');
      port.emitPeerConnected(remote, ConnectionRole.central,
          address: const BleAddress('addr-1'));
      await pump();

      // A gossip payload whose bytes are exactly a rejection frame,
      // legitimately framed in GSP1 and split so the second chunk starts
      // with the GSP2 magic (decoder is mid-frame at that point).
      final payload = ControlFrameCodec.encodeRejection(RejectionReason.capacity);
      final chunks = FrameEncoder.encode(payload, mtuPayloadSize: 9);
      for (final c in chunks) {
        port.emitPeerData(remote, c);
      }
      await pump();

      expect(registry.contains(remote), isTrue);
      expect(received, hasLength(1));
      expect(received.single.bytes, equals(payload));
    });
  });
```

Add imports the file now needs (`connection_event.dart`, `connection_error.dart`, `frame_codec.dart`, `IncomingMessage` comes from `package:gossip/gossip.dart`). If the fake lacks `emitPeerData`, add the thin hook:

```dart
  /// Test hook: inject inbound data as if [from] wrote to us.
  void emitPeerData(NodeId from, Uint8List data) {
    if (!_events.isClosed) {
      _events.add(PortPeerData(nodeId: from, data: data));
    }
  }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/application/services/connection_manager_rejection_test.dart`
Expected: FAIL — `ConnectionRejectedByPeerError` undefined; after stubbing the class, the first test still red (no receiver logic).

- [ ] **Step 3: Implement the error class and receiver**

In `lib/src/domain/errors/connection_error.dart`, following the exact style of the sibling classes (read `SendFailedError` first), add:

```dart
/// The remote peer rejected our connection via an in-band GSP2 control
/// frame (COR3-21) — e.g. it is at its connection cap. We closed our own
/// link in response; retrying later is legitimate (a slot may free up).
final class ConnectionRejectedByPeerError extends ConnectionError {
  final NodeId nodeId;
  final RejectionReason reason;

  ConnectionRejectedByPeerError({
    required String message,
    required DateTime occurredAt,
    required this.nodeId,
    required this.reason,
  }) : super(message: message, occurredAt: occurredAt);
}
```

(Match the actual `ConnectionError` super-constructor signature — read it; the snippet assumes named `message`/`occurredAt`. Add the needed import of `control_frame_codec.dart` for `RejectionReason` — if importing infrastructure from domain violates the package's layering lint, move `RejectionReason` into `lib/src/domain/value_objects/rejection_reason.dart` instead and have the codec import IT; prefer that move if in doubt, updating Task 1's import in the codec.)

Export it from `lib/gossip_bluey.dart` the same way the sibling error classes are exported.

In `connection_manager.dart`, at the TOP of `case PortPeerData(:final nodeId, :final data):` (before the existing decoder lookup):

```dart
        final decoder = _decoders[nodeId];
        if (decoder == null) {
          // Data from a peer we don't know about — ignore.
          return;
        }
        final registered = registry.get(nodeId);
        if (registered != null &&
            registered.role == ConnectionRole.central &&
            decoder.isAtFrameBoundary) {
          final control = ControlFrameCodec.tryParse(data);
          if (control is ConnectionRejectedFrame) {
            // The responder cannot close its inbound link; we can and
            // must (COR3-21). Unregister inline so PeerClosed carries a
            // distinct reason — the later platform disconnect event
            // finds no matching registration and is ignored.
            onLog?.call(
              LogLevel.info,
              'peer $nodeId rejected our connection '
              '(${control.reason.name}); closing our central link',
            );
            registry.remove(nodeId);
            _decoders.remove(nodeId);
            metrics.setConnectedPeerCount(registry.connectionCount);
            _emitEvent(PeerClosed(
              nodeId: nodeId,
              reason: 'rejected by peer: ${control.reason.name}',
            ));
            _emitError(ConnectionRejectedByPeerError(
              message: 'peer $nodeId rejected our connection '
                  '(${control.reason.name})',
              occurredAt: _clock.now(),
              nodeId: nodeId,
              reason: control.reason,
            ));
            _disconnectRoleGuarded(nodeId, ConnectionRole.central);
            return;
          }
        }
```

(The existing `metrics.recordFrameReceived()` / `decoder.feed(...)` flow continues below, using the `decoder` local already looked up — deduplicate so the lookup happens once.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/application/services/connection_manager_rejection_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 5: Full gates, then commit**

Run: `flutter test` → all pass; `dart analyze` → no issues (layering lint may force the `RejectionReason` move described above).

```bash
git add lib/ test/
git commit -m "feat(gossip_bluey): act on GSP2 rejection — close own central, typed error (COR3-21 receiver)"
```

---

### Task 6: `AutoConnectPolicy` backs off rejected peers

**Files:**
- Modify: `lib/src/application/services/auto_connect_policy.dart` (constructor subscribes; `dispose` at line ~212 cancels)
- Test: `test/application/services/auto_connect_policy_test.dart` (extend)

**Interfaces:**
- Consumes: `ConnectionManager.errors` (already a field: `_connections`), `ConnectionRejectedByPeerError` (Task 5), `_recordExponentialBackoff(BleAddress)` (existing, line ~199), `_knownAddressToNode` map (existing).
- Produces: behavior only — after a rejected-by-peer error for NodeId N, every address currently mapped to N in `_knownAddressToNode` is under exponential backoff.

Why: without this, the retry loop is hot — the rejected central closed its link, `connectTo` had SUCCEEDED (clearing backoff), and the scan re-emits the candidate ~continuously, so reconnect attempts pace at scan speed against a still-full peer.

- [ ] **Step 1: Write the failing test**

Read `test/application/services/auto_connect_policy_test.dart` first and reuse its fixture style (it already constructs a policy with fakes and a manual clock). Add:

```dart
    test('a ConnectionRejectedByPeerError applies exponential backoff to '
        'the rejected NodeId\'s known address', () async {
      // Arrange the policy in auto mode with a candidate that has
      // already been connected once (so _knownAddressToNode maps
      // addr → nodeId) — follow the existing tests' arrangement for a
      // successful connect, then simulate the rejection:
      manager.emitErrorForTest(ConnectionRejectedByPeerError(
        message: 'rejected',
        occurredAt: clock.now(),
        nodeId: remoteNodeId,
        reason: RejectionReason.capacity,
      ));
      await Future<void>.delayed(Duration.zero);

      // The next candidate emission for that address must NOT trigger
      // a connect attempt until the backoff window passes.
      connectAttempts = 0;                       // reset the fixture's counter
      emitCandidate(remoteAddress);
      await Future<void>.delayed(Duration.zero);
      expect(connectAttempts, 0,
          reason: 'address must be under backoff after peer rejection');

      clock.advance(const Duration(seconds: 2)); // > initialBackoff (1s)
      emitCandidate(remoteAddress);
      await Future<void>.delayed(Duration.zero);
      expect(connectAttempts, 1,
          reason: 'backoff expires — retry is legitimate (slot may free)');
    });
```

This snippet names fixture helpers (`manager.emitErrorForTest`, `emitCandidate`, `connectAttempts`, `clock.advance`) that must be adapted to the file's actual fixtures — the EXISTING tests in that file show how candidates are emitted and connects counted; follow them exactly. If the fixture's manager is the real `ConnectionManager`, emit the error by driving the Task-5 receiver path (register a central via `emitPeerConnected`, then `emitPeerData` a rejection frame) instead of an `emitErrorForTest` hook — prefer that, it needs no new hooks.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/application/services/auto_connect_policy_test.dart`
Expected: the new test FAILS (connect attempt happens immediately, `connectAttempts == 1` at the first assertion).

- [ ] **Step 3: Implement the subscription**

In `auto_connect_policy.dart`, add a field and subscribe in the constructor body (the constructor currently has no body — add one):

```dart
  })  : _discovery = discovery,
        _connections = connections,
        _registry = registry,
        _now = now,
        _targetConnections = targetConnections,
        _initialBackoff = initialBackoff,
        _maxBackoff = maxBackoff,
        _longBackoff = longBackoff {
    // A peer that rejected us (GSP2, e.g. at capacity) must not be
    // re-dialed at scan cadence: connectTo SUCCEEDED (clearing backoff)
    // before the rejection arrived, so without this hook the retry loop
    // would pace at scan speed against a still-full peer.
    _errorsSub = _connections.errors.listen(
      (error) {
        if (error is! ConnectionRejectedByPeerError) return;
        for (final entry in _knownAddressToNode.entries) {
          if (entry.value == error.nodeId) {
            _recordExponentialBackoff(entry.key);
          }
        }
      },
      onError: (Object e, StackTrace st) {
        onLog?.call(LogLevel.warning, 'connection error stream error', e, st);
      },
    );
  }

  StreamSubscription<ConnectionError>? _errorsSub;
```

Add the import for `connection_error.dart` (and `rejection_reason.dart`/codec if needed). In `dispose()` (line ~212):

```dart
  Future<void> dispose() async {
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    final errorsSub = _errorsSub;
    _errorsSub = null;
    await errorsSub?.cancel();
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/application/services/auto_connect_policy_test.dart`
Expected: PASS, including the new test.

- [ ] **Step 5: Full gates, then commit**

Run: `flutter test` → all pass; `dart analyze` → no issues.

```bash
git add lib/src/application/services/auto_connect_policy.dart test/
git commit -m "feat(gossip_bluey): back off peers that rejected us via GSP2 (COR3-21 policy)"
```

---

### Task 7: End-to-end — mutual connect converges to ONE physical link

**Files:**
- Test: `test/integration/adverse_link_tiebreak_test.dart` (new)
- Possibly modify: `test/fakes/fake_bluey_port.dart` (physical-link introspection helper), `test/integration/_adverse_link_harness.dart` / `_coordinator_helpers.dart` (reuse; read both first)

**Interfaces:**
- Consumes: the full stack via the existing integration harness (`AdverseLinkNode` in `_adverse_link_harness.dart` — real Coordinator over `BlueyTransport`-equivalent wiring over `FakeBlueyPort`); the fake's `connectedAsCentral`/`connectedAsPeripheral` getters (lines 246–249).
- Produces: a fake helper `int physicalLinkCountTo(NodeId peer)` = `(_connectedAsCentral.contains(peer) ? 1 : 0) + (_connectedAsPeripheral.contains(peer) ? 1 : 0)` — the metric COR3-29 says is invisible in production.

This is a characterization-of-new-behavior task: the assertions were IMPOSSIBLE to satisfy before Task 3 (mutual connect left 2 links). Write the test, confirm it passes, then mutation-check it (step 4) so it is not vacuous.

- [ ] **Step 1: Add the fake helper**

In `test/fakes/fake_bluey_port.dart`, next to the `connectedAsCentral` getter (line 246):

```dart
  /// Number of live physical links to [peer] — central and peripheral
  /// counted separately. This is the ground truth the production
  /// registry cannot see (COR3-29): a mutual connect that converged
  /// correctly shows exactly 1 here.
  int physicalLinkCountTo(NodeId peer) =>
      (_connectedAsCentral.contains(peer) ? 1 : 0) +
      (_connectedAsPeripheral.contains(peer) ? 1 : 0);
```

- [ ] **Step 2: Write the test**

Create `test/integration/adverse_link_tiebreak_test.dart`. Read `_adverse_link_harness.dart` and `mesh_two_node_test.dart` FIRST and reuse their node-spawning helpers verbatim; the shape:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';

import '_adverse_link_harness.dart';

void main() {
  test('simultaneous mutual connect converges to exactly one physical '
      'link, with the smaller NodeId as central, and gossip still syncs',
      () async {
    // Spawn two nodes in mesh mode (both advertising + discovering,
    // auto-connect on) using the harness helpers. Node ids chosen so
    // the tie-break direction is unambiguous.
    final a = await spawnAdverseLinkNode('node-aaa');
    final b = await spawnAdverseLinkNode('node-zzz');
    addTearDown(() async {
      await a.dispose();
      await b.dispose();
    });

    // Drive BOTH connects concurrently to force the mutual-connect race.
    await Future.wait([
      a.connectToPeer(b.nodeId),
      b.connectToPeer(a.nodeId),
    ]);

    // Let tie-break + physical closes settle.
    await waitUntil(
      () =>
          a.fakePort.physicalLinkCountTo(b.nodeId) == 1 &&
          b.fakePort.physicalLinkCountTo(a.nodeId) == 1,
      timeout: const Duration(seconds: 5),
      reason: 'pair must converge to exactly ONE physical link',
    );

    // The surviving link's central is the smaller NodeId.
    expect(a.fakePort.connectedAsCentral.contains(b.nodeId), isTrue,
        reason: 'node-aaa < node-zzz: aaa must be the central');
    expect(b.fakePort.connectedAsCentral.contains(a.nodeId), isFalse);

    // And the surviving link carries real gossip: write on A, read on B.
    await a.writeEntry([1, 2, 3]);
    await waitUntil(() async => (await b.entryCount()) == 1,
        timeout: const Duration(seconds: 10));
  });

  test('mutual connect converges regardless of which link registers '
      'first on each side (staggered race)', () async {
    final a = await spawnAdverseLinkNode('node-aaa');
    final b = await spawnAdverseLinkNode('node-zzz');
    addTearDown(() async {
      await a.dispose();
      await b.dispose();
    });

    // Stagger: A initiates first, B initiates while A's connect is
    // resolving — exercises the arrival-order cases the unit tests
    // cover in isolation, through the whole stack.
    final first = a.connectToPeer(b.nodeId);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final second = b.connectToPeer(a.nodeId);
    await Future.wait([first, second]);

    await waitUntil(
      () =>
          a.fakePort.physicalLinkCountTo(b.nodeId) == 1 &&
          b.fakePort.physicalLinkCountTo(a.nodeId) == 1,
      timeout: const Duration(seconds: 5),
    );

    await a.writeEntry([9]);
    await waitUntil(() async => (await b.entryCount()) == 1,
        timeout: const Duration(seconds: 10));
  });
}
```

The helper names (`spawnAdverseLinkNode`, `connectToPeer`, `writeEntry`, `entryCount`, `fakePort`, `waitUntil`) MUST be adapted to what `_adverse_link_harness.dart` actually exposes — do not invent parallel helpers if equivalents exist; extend the harness minimally if one is missing (e.g. `waitUntil` — a simple poll loop with a deadline, if the harness lacks one:)

```dart
Future<void> waitUntil(
  FutureOr<bool> Function() condition, {
  required Duration timeout,
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail(reason ?? 'condition not met within $timeout');
}
```

Also check whether the fake's `connectAndIdentify` supports two SIMULTANEOUS opposite-direction connects between the same pair; if it collapses them or throws, extend the fake so both physical links can coexist (that is the real-world situation the tie-break resolves). Keep the extension minimal and documented.

- [ ] **Step 3: Run the test**

Run: `flutter test test/integration/adverse_link_tiebreak_test.dart`
Expected: PASS (Tasks 3–5 are in). If it FAILS, debug the integration — the unit tests passing while e2e fails usually means the fake collapses the mutual connect (see step 2's note) or the harness helpers were misadapted.

- [ ] **Step 4: Mutation-check the test is not vacuous**

Temporarily disable the tie-break: in `connection_manager.dart`, change the duplicate branch's `final localWins = ...` line to `final localWins = true;` (both sides think they win → neither closes its central).
Run: `flutter test test/integration/adverse_link_tiebreak_test.dart`
Expected: FAIL on `physicalLinkCountTo == 1` (count stays 2).
REVERT the mutation (`git diff lib/` must be clean of it) and re-run: PASS.

- [ ] **Step 5: Full gates, then commit**

Run: `flutter test` → all pass; `dart analyze` → no issues.

```bash
git add test/
git commit -m "test(gossip_bluey): e2e — mutual connect converges to one physical link (COR3-29)"
```

---

### Task 8: End-to-end — capacity rejection, backoff, recovery; mixed-version safety

**Files:**
- Test: `test/integration/adverse_link_rejection_test.dart` (new)

**Interfaces:**
- Consumes: everything shipped in Tasks 1–7; harness helpers as adapted in Task 7; `FakeBlueyPort.connectAndIdentifyCallCount`-style counters (check the fake's existing counters — `scanForCandidatesCallCount` exists; find or add a connect counter).

- [ ] **Step 1: Write the tests**

Create `test/integration/adverse_link_rejection_test.dart` (adapting helper names exactly as in Task 7):

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';

import '_adverse_link_harness.dart';

void main() {
  test('a newcomer rejected at capacity closes its link, backs off, and '
      'syncs after a slot frees', () async {
    // hub capped at 1 connection; first peer fills the slot.
    final hub = await spawnAdverseLinkNode('hub', maxConnections: 1);
    final first = await spawnAdverseLinkNode('peer-1');
    final newcomer = await spawnAdverseLinkNode('peer-2');
    addTearDown(() async {
      await hub.dispose();
      await first.dispose();
      await newcomer.dispose();
    });

    await first.connectToPeer(hub.nodeId);
    await waitUntil(() => hub.fakePort.physicalLinkCountTo(first.nodeId) == 1,
        timeout: const Duration(seconds: 5));

    // Newcomer dials the full hub — must end NOT connected, with the
    // physical link closed (no void-gossip) after the rejection frame.
    await newcomer.connectToPeer(hub.nodeId).then((_) {}, onError: (_) {});
    await waitUntil(
      () => newcomer.fakePort.physicalLinkCountTo(hub.nodeId) == 0,
      timeout: const Duration(seconds: 5),
      reason: 'rejected central must close its own link',
    );

    // Backoff: over the next second of continuous scanning, connect
    // attempts to the hub must stay bounded (no scan-cadence hot loop —
    // the fake rebroadcasts candidates every 100ms, so an unbacked-off
    // policy would attempt ~10 times).
    final attemptsBefore = newcomer.fakePort.connectAndIdentifyCallCount;
    await Future<void>.delayed(const Duration(seconds: 1));
    final attemptsDuring =
        newcomer.fakePort.connectAndIdentifyCallCount - attemptsBefore;
    expect(attemptsDuring, lessThanOrEqualTo(1),
        reason: 'exponential backoff must pace retries');

    // Free the slot; the newcomer's next retry must succeed and sync.
    await hub.disconnectFrom(first.nodeId);
    await hub.writeEntry([7, 7]);
    await waitUntil(() async => (await newcomer.entryCount()) == 1,
        timeout: const Duration(seconds: 15),
        reason: 'after a slot frees, a backed-off retry must connect '
            'and sync');
  });

  test('a rejection frame sent to a receiver that does not understand '
      'GSP2 is skipped harmlessly and later data still decodes', () async {
    // Mixed-version safety at the decoder level, through the transport
    // data path: feed a GSP2 frame followed by a GSP1 data frame into a
    // node's inbound path from a connected peer, and assert the GSP1
    // message still arrives and the connection stays up. This pins the
    // legacy-receiver behavior without needing an actual old build: the
    // GSP1 FrameDecoder IS the legacy path (a peripheral-role receiver
    // never dispatches GSP2 — Task 5's role guard).
    final a = await spawnAdverseLinkNode('node-aaa');
    final b = await spawnAdverseLinkNode('node-zzz');
    addTearDown(() async {
      await a.dispose();
      await b.dispose();
    });
    await a.connectToPeer(b.nodeId);
    await waitUntil(() => b.fakePort.physicalLinkCountTo(a.nodeId) == 1,
        timeout: const Duration(seconds: 5));

    // b is the PERIPHERAL on this link (a initiated) — b's receive path
    // treats GSP2 as garbage by role guard, exactly like a legacy node.
    b.fakePort.emitPeerData(
      a.nodeId,
      ControlFrameCodec.encodeRejection(RejectionReason.capacity),
    );

    await a.writeEntry([4, 2]);
    await waitUntil(() async => (await b.entryCount()) == 1,
        timeout: const Duration(seconds: 10),
        reason: 'GSP2 residue must not poison the GSP1 stream');
    expect(b.fakePort.physicalLinkCountTo(a.nodeId), 1,
        reason: 'link must survive the unknown frame');
  });
}
```

Add the imports the file needs (`control_frame_codec.dart`). If the fake lacks `connectAndIdentifyCallCount`, add an increment in its `connectAndIdentify` plus the public counter (mirror `scanForCandidatesCallCount`). If the harness lacks `maxConnections:` or `disconnectFrom`, thread them through (`maxConnections` reaches `ConnectionManager`'s existing parameter; `disconnectFrom` calls `manager.disconnect(nodeId)`).

- [ ] **Step 2: Run the tests**

Run: `flutter test test/integration/adverse_link_rejection_test.dart`
Expected: PASS. If the backoff assertion flakes, widen only the OBSERVATION window (not the bound) and re-verify determinism by running the file twice.

- [ ] **Step 3: Mutation-check**

Temporarily comment out the Task 4 sender block (the `if (role == ConnectionRole.peripheral)` rejection-frame send).
Run: `flutter test test/integration/adverse_link_rejection_test.dart`
Expected: test 1 FAILS (newcomer's link count never drops to 0 — it gossips into the void, the pre-fix behavior).
REVERT and re-run: PASS.

- [ ] **Step 4: Full gates, then commit**

Run: `flutter test` (twice, back-to-back, to check for flakiness) → all pass both times; `dart analyze` → no issues.

```bash
git add test/
git commit -m "test(gossip_bluey): e2e — capacity rejection closes+backs off+recovers; GSP2 mixed-version safety (COR3-21)"
```

---

### Task 9: Documentation + roadmap closure

**Files:**
- Modify: `CLAUDE.md` (repo root, lines 109, 117–118)
- Modify: `docs/roadmap.md` (two Sync-engine lines)
- Modify: `docs/backlog/engine-mesh-connection-tiebreak.md` (Related note)

**Interfaces:** none — docs only.

- [ ] **Step 1: Fix the root CLAUDE.md claims**

Line 109 currently reads:
```
- `ConnectionService` (application): Discovery + tie-break, soft/hard caps, adaptive scan, per-NodeId backoff, send/receive paths
```
Replace with (matching the real class names):
```
- `ConnectionManager` / `AutoConnectPolicy` (application): connection registry + send/receive paths; discovery-driven auto-connect with per-address backoff and caps
```

Lines 117–118 currently read:
```
- **Mesh:** every device calls both `startAdvertising()` and `startDiscovery()`. Tie-break by `NodeId.value` ensures one initiator per pair.
- **Star:** hub calls `startAdvertising()` only; spokes call `startDiscovery(filter: hubId)` only.
```
Replace with:
```
- **Mesh:** every device calls both `startAdvertising()` and `startDiscovery()`. A mutual connect briefly holds two links; the post-connect tie-break (smaller `NodeId.value` stays central; the loser closes its own central link) converges every pair to one physical link.
- **Star:** hub calls `startAdvertising()` only; spokes call `startDiscovery()` only — spokes can only ever find the hub because nothing else advertises.
```

- [ ] **Step 2: Close the roadmap items**

In `docs/roadmap.md`, flip the two lines (keep the format exactly):

```
- ☑ **High** — [One Bluetooth link per device pair in a mesh](backlog/engine-mesh-connection-tiebreak.md) · post-connect tie-break (smaller NodeId is central; loser closes its own central) — advertisement approach rejected (iOS limits); see the spec
- ☑ **Medium** — [Tell a rejected Bluetooth peer it was rejected](backlog/engine-reject-notify-capped-peers.md) · GSP2 control frame + receiver close + policy backoff
```

Append the shipping-commit hashes to each line's trailing note once known (` — shipped in <hash>`), and add to `docs/backlog/engine-mesh-connection-tiebreak.md`'s Related section:

```markdown
- Done — implemented as a post-connect tie-break (the advertisement
  approach was rejected: iOS peripherals cannot advertise manufacturer
  data). Design:
  [the spec](../superpowers/specs/2026-07-10-bluey-tiebreak-rejection-design.md).
  A best-effort pre-connect hash on Android remains a possible future
  optimization of the transient double-connect.
```

- [ ] **Step 3: Verify no dangling references, then commit**

Run from repo root: `grep -rn "filter: hubId" . --include="*.md"` → no hits outside audit reports (audit documents describe the historical finding — leave those).
Run: `grep -rn "Tie-break by" CLAUDE.md` → no hits.

```bash
git add CLAUDE.md docs/
git commit -m "docs: real tie-break + star semantics; close COR3-29/COR3-21 roadmap items"
```

---

## Self-Review (performed at write time)

- **Spec coverage:** tie-break rule + 4 cases → Task 3; connectTo contract → covered by existing `connectTo` registry-wait (no change needed; Task 3 tests keep `registry.contains` true through swaps); send-queue behavior across swap → existing per-chunk `identical` guard + Task 3 decoder swap (spec-accepted residue); GSP2 wire format → Task 1; sender → Task 4; receiver + typed error + distinct PeerClosed → Task 5; backoff feed → Task 6; e2e one-physical-link, both orders → Task 7; capacity e2e + mixed-version → Task 8; docs + roadmap → Task 9. Spec's "per-NodeId backoff" is implemented per-ADDRESS via the NodeId→address reverse lookup (the policy's backoff map is address-keyed) — same observable effect, noted in Task 6.
- **Placeholders:** none; every step has complete code or an exact command. Steps that depend on reading existing fixtures say exactly which file to read and what to adapt.
- **Type consistency:** `RejectionReason.capacity` / `ControlFrameCodec.encodeRejection` / `tryParse` / `ConnectionRejectedFrame` / `isAtFrameBoundary` / `localNodeId` / `ConnectionRejectedByPeerError(nodeId, reason)` / `physicalLinkCountTo` used identically across Tasks 1–8; Task 5 flags the one legitimate variance (`RejectionReason` may move to domain for layering) and instructs updating Task 1's import if taken.
