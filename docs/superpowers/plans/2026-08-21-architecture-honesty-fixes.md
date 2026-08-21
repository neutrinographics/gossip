# Architecture Honesty Fixes (Batch 3, Part 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the declared architecture true in all three packages: delete the dead bridge, get wire-format knowledge out of the application layer, break nearby's app↔infra cycle, stop leaking bluey enums through gossip_bluey's public API, and make peer persistence honest (memory-only by design).

**Architecture:** Behavior-neutral honesty fixes (except ARCH3-5's public-API *type* change in gossip_bluey, whose consumers are all in-repo). Each transport gains a `protocol/` layer for its wire codecs; dispatcher interfaces move to (or are created in) the application layer; owned lifecycle enums translate at the adapter exactly like the existing `BluetoothAdapterState`/`ScanMode` ACLs; `PeerService` shrinks to its real consumers.

**Tech Stack:** Pure Dart (`packages/gossip`), Flutter (`packages/gossip_nearby`, `packages/gossip_bluey`, `examples/gossip_chat`). Melos monorepo.

**Spec:** `docs/superpowers/specs/2026-08-21-architecture-honesty-fixes-design.md`

## Global Constraints

- Work directly on `working-connection` (repo precedent; no worktree).
- Strict TDD for new behavior (WireDispatcher, dispatcher-stream seam, enum translation): failing test first, watch it fail, minimal green. Pure moves/deletions are behavior-neutral refactors — the existing suites are the net; gates green after every task.
- Never weaken an existing assertion. Tests covering removed `PeerService` API are removed with the API; add/remove/query assertions stay byte-identical.
- ARCH3-6 owner decision (binding): SWIM-driven peer state (status/contact/metrics) is memory-only by design — do NOT route protocol mutations through `PeerService`.
- Gates per task: the touched package's `test` + `analyze`; final task runs the full monorepo (`melos run test && melos run analyze`) plus `examples/gossip_chat` tests.
- Commit style: `refactor(scope): …` / `feat(scope): …` / `test(scope): …` / `docs(scope): …`, each commit ending with:

```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

### Task 1: Delete the dead application↔protocol bridge (ARCH3-2, core)

**Files:**
- Delete: `packages/gossip/lib/src/application/coordinator_sync_service.dart`
- Delete: `packages/gossip/lib/src/application/interfaces/sync_coordinator_service.dart`
- Delete: `packages/gossip/test/application/coordinator_sync_service_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing — the point is the absence. Later tasks must not reference these names.

- [ ] **Step 1: Verify the deadness claim before deleting**

Run (from repo root):
```bash
grep -rn "CoordinatorSyncService\|SyncCoordinatorService\|coordinator_sync_service\|sync_coordinator_service" packages/ examples/ --include="*.dart" | grep -v "packages/gossip/lib/src/application/coordinator_sync_service.dart\|packages/gossip/lib/src/application/interfaces/sync_coordinator_service.dart\|packages/gossip/test/application/coordinator_sync_service_test.dart"
```
Expected: no output (the only references are the three files themselves; verified 2026-08-21). If anything else appears, STOP and report BLOCKED with the hit.

- [ ] **Step 2: Delete the three files**

```bash
git rm packages/gossip/lib/src/application/coordinator_sync_service.dart packages/gossip/lib/src/application/interfaces/sync_coordinator_service.dart packages/gossip/test/application/coordinator_sync_service_test.dart
```

If `lib/src/application/interfaces/` is now empty, remove the directory.

- [ ] **Step 3: Gate**

Run: `cd packages/gossip && dart test && dart analyze`
Expected: all green, zero issues (nothing imported the deleted files).

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor(gossip): delete dead CoordinatorSyncService bridge (ARCH3-2)"
```
(with the co-author trailer.)

---

### Task 2: PeerService memory-only simplification (ARCH3-6, core)

**Files:**
- Modify: `packages/gossip/lib/src/application/services/peer_service.dart`
- Modify: `packages/gossip/lib/src/domain/interfaces/peer_repository.dart` (doc only)
- Modify/Delete tests: `packages/gossip/test/application/services/peer_service_test.dart`, `packages/gossip/test/application/peer_service_ordering_test.dart`, `packages/gossip/test/error_emission_test.dart` (only the sections covering removed methods)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `PeerService` with exactly `addPeer(NodeId, {String? displayName})`, `removePeer(NodeId)`, and whatever query surface it has today. The five mutation methods disappear.

**Verified facts (2026-08-21):** `Coordinator` calls only `_peerService.addPeer` (coordinator.dart:654) and `_peerService.removePeer` (:740). The methods `updatePeerStatus`, `recordPeerContact`, `recordPeerAntiEntropy`, `recordMessageReceived`, `recordMessageSent` (peer_service.dart:125-191) have ZERO production callers — the protocol layer writes `PeerRegistry` directly, which is now the declared design. The class doc's "Used by:" line (:39) already names the Coordinator (the ChannelService half of this finding was fixed earlier); keep it accurate.

- [ ] **Step 1: Re-verify zero production callers**

```bash
grep -rn "updatePeerStatus\|recordPeerContact\|recordPeerAntiEntropy\|recordMessageReceived\|recordMessageSent" packages/gossip/lib --include="*.dart" | grep -v "peer_service.dart\|peer_registry.dart"
```
Expected: hits only in `PeerRegistry` (the registry's own methods, which STAY — they are the memory-only home) and possibly protocol files calling the REGISTRY. No hits calling `PeerService`'s versions. If a production call to a `PeerService` mutation method appears, STOP and report BLOCKED.

- [ ] **Step 2: Remove the five mutation methods and their persistence plumbing**

In `peer_service.dart`: delete `updatePeerStatus`, `recordPeerContact`, `recordPeerAntiEntropy`, `recordMessageReceived`, `recordMessageSent`, and any `_persistPeer` branches now unreachable (keep whatever `addPeer`/`removePeer` still use — `addPeer` persists the add; `removePeer` persists the delete). Do not touch `PeerRegistry`.

- [ ] **Step 3: Rewrite the class doc to declare the contract**

Replace the class-level doc comment on `PeerService` with:

```dart
/// Application service for peer membership: add, remove, query.
///
/// ## Persistence contract (memory-only SWIM state — by design)
///
/// Only membership itself (add/remove) reaches [PeerRepository].
/// SWIM-driven state — reachability status, contact times, RTT and
/// traffic metrics — lives exclusively in the in-memory [PeerRegistry]
/// and is NEVER persisted: it is ephemeral runtime observation that is
/// meaningless across restarts. A persistent [PeerRepository]
/// implementation therefore sees peers appear and disappear, nothing
/// else. (Owner decision, 2026-08-21 — see
/// docs/superpowers/specs/2026-08-21-architecture-honesty-fixes-design.md.)
///
/// Used by: the Coordinator facade (peer add/remove orchestration).
/// The protocol layer deliberately does NOT go through this service.
```

Add a matching short paragraph to `peer_repository.dart`'s interface doc: implementations receive only add/remove; SWIM state is never written to them, by design.

- [ ] **Step 4: Prune the tests of the removed methods**

In the three test files, delete only the groups/tests exercising the five removed methods and their persistence/ordering/error-emission behavior. Every remaining `expect` stays byte-identical. If a test mixes removed-method setup with add/remove assertions, refactor its setup to keep the assertion, never delete the assertion.

- [ ] **Step 5: Gate**

Run: `cd packages/gossip && dart test && dart analyze`
Expected: all green, zero issues.

- [ ] **Step 6: Commit**

```bash
git commit -m "refactor(gossip): PeerService to add/remove/query; declare SWIM state memory-only (ARCH3-6)"
```

---

### Task 3: nearby — wire knowledge into a protocol layer (ARCH3-3)

**Files:**
- Move: `packages/gossip_nearby/lib/src/infrastructure/codec/handshake_codec.dart` → `packages/gossip_nearby/lib/src/protocol/handshake_codec.dart`
- Create: `packages/gossip_nearby/lib/src/protocol/wire_dispatcher.dart`
- Modify: `packages/gossip_nearby/lib/src/application/services/connection_service.dart` (imports :15-16; dispatch site ~:471)
- Move test: `packages/gossip_nearby/test/infrastructure/codec/handshake_codec_test.dart` → `packages/gossip_nearby/test/protocol/handshake_codec_test.dart`
- Test: `packages/gossip_nearby/test/protocol/wire_dispatcher_test.dart` (new)
- Modify: `packages/gossip_nearby/docs/adr/005-*.md` (locate the codec-placement ADR by grep; amend)

**Interfaces:**
- Consumes: existing `HandshakeCodec`, `MessageType`, `WireFormat` (all in handshake_codec.dart).
- Produces: `class WireDispatcher { MessageType classify(Uint8List bytes); }` in `protocol/` — `ConnectionService` switches on its result and never reads `WireFormat.typeOffset` again.

- [ ] **Step 1: Move the codec file (pure move)**

```bash
cd packages/gossip_nearby
git mv lib/src/infrastructure/codec/handshake_codec.dart lib/src/protocol/handshake_codec.dart
git mv test/infrastructure/codec/handshake_codec_test.dart test/protocol/handshake_codec_test.dart
```
Fix the import path in `connection_service.dart:15` (`../../infrastructure/codec/handshake_codec.dart` → `../../protocol/handshake_codec.dart`) and in the moved test. Remove empty `infrastructure/codec/` dir.

Run: `flutter test && dart analyze` → green (move is behavior-neutral).

- [ ] **Step 2: Write the failing WireDispatcher test**

```dart
// test/protocol/wire_dispatcher_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_nearby/src/protocol/handshake_codec.dart';
import 'package:gossip_nearby/src/protocol/wire_dispatcher.dart';

/// ARCH3-3: byte-layout knowledge (WireFormat.typeOffset) executes in the
/// protocol layer; the application layer switches on MessageType only.
void main() {
  group('WireDispatcher', () {
    test('classifies each MessageType round-tripped through the wire byte',
        () {
      final dispatcher = WireDispatcher();
      for (final type in MessageType.values) {
        // Build the smallest frame whose type byte is `type` — mirror how
        // handshake_codec_test.dart constructs frames (its helpers are the
        // source of truth for byte layout; do NOT hand-roll offsets here).
        final bytes = buildFrameWithType(type); // helper mirrored from codec test
        expect(dispatcher.classify(bytes), type,
            reason: 'the dispatcher must agree with the codec about '
                'where the type byte lives');
      }
    });
  });
}
```

Note: `buildFrameWithType` is a thin local helper — mirror the frame-building already done in `handshake_codec_test.dart` (same file you just moved; its construction code is the byte-layout source of truth). The assertion set is the contract; if `MessageType` has values that cannot appear on the wire, cover the ones `ConnectionService`'s dispatch handles today and say so in a comment.

Run: `flutter test test/protocol/wire_dispatcher_test.dart`
Expected: FAIL — `wire_dispatcher.dart` does not exist.

- [ ] **Step 3: Implement WireDispatcher and re-home the dispatch**

```dart
// lib/src/protocol/wire_dispatcher.dart
import 'dart:typed_data';

import 'handshake_codec.dart' show MessageType, WireFormat;

/// Protocol-layer byte classification (ARCH3-3).
///
/// The ONLY place outside [HandshakeCodec] that may read the wire
/// layout. The application layer receives a [MessageType] and never
/// touches byte offsets.
class WireDispatcher {
  MessageType classify(Uint8List bytes) {
    // Mirror the exact classification ConnectionService performed at its
    // old dispatch site (bytes[WireFormat.typeOffset] plus whatever
    // guards surrounded it — preserve them verbatim, including any
    // length checks).
    ...
  }
}
```

The `...` is the classification logic MOVED VERBATIM from `connection_service.dart`'s dispatch site (~line 471 and its surrounding switch/guards). In `ConnectionService`: construct/inject a `WireDispatcher` (constructor field, default `WireDispatcher()`), replace the byte-peeking with `switch (_wireDispatcher.classify(bytes))`, and narrow the import to `show HandshakeCodec, MessageType` (WireFormat no longer needed there).

Run: `flutter test test/protocol/wire_dispatcher_test.dart` → PASS.

- [ ] **Step 4: Gate + amend the ADR**

Run: `flutter test && dart analyze` → all green, zero issues.

Locate the nearby ADR that the audit says contradicts this placement: `grep -rln "codec\|Codec" packages/gossip_nearby/docs/` — amend it (short dated addendum): wire codecs and byte classification live in `protocol/`; the application layer consumes `MessageType` only (ARCH3-3, 2026-08-21).

- [ ] **Step 5: Commit**

```bash
git commit -m "refactor(gossip_nearby): wire codec + byte dispatch into protocol layer (ARCH3-3)"
```

---

### Task 4: nearby — application-owned dispatcher seam replaces the callback slot (ARCH3-4)

**Files:**
- Create: `packages/gossip_nearby/lib/src/application/interfaces/message_dispatcher.dart`
- Modify: `packages/gossip_nearby/lib/src/application/services/connection_service.dart` (callback slot :103, invocation :574, typedef :20)
- Modify: `packages/gossip_nearby/lib/src/infrastructure/ports/nearby_message_port.dart` (imports + all `_connectionService` usages)
- Modify: `packages/gossip_nearby/lib/src/facade/nearby_transport.dart` (wiring ~:181-190 — type only)
- Test: `packages/gossip_nearby/test/infrastructure/ports/nearby_message_port_test.dart` (adapt/extend; if it doesn't exist, create it)

**Interfaces:**
- Consumes: gossip's `MessagePort`, `IncomingMessage`, `MessagePriority`, `NodeId` (via `package:gossip/gossip.dart`).
- Produces: the interface below. `NearbyMessagePort` depends ONLY on it; `ConnectionService implements MessageDispatcher`; the public mutable `onGossipMessage` slot and its typedef are DELETED.

```dart
// lib/src/application/interfaces/message_dispatcher.dart
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

/// Application-owned seam between message transport adapters and the
/// connection service (ARCH3-4). Mirrors gossip_bluey's dispatcher seam;
/// the interface lives in the application layer so infrastructure
/// depends inward, never the reverse.
abstract interface class MessageDispatcher {
  /// Sends a gossip message to a destination peer. Mirror
  /// ConnectionService.sendGossipMessage's exact current signature —
  /// including its priority parameter if present — so the move is
  /// behavior-neutral.
  Future<void> sendGossipMessage(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  });

  /// Broadcast stream of decoded inbound gossip messages. REPLACES the
  /// mutable `onGossipMessage` callback slot.
  Stream<IncomingMessage> get incomingMessages;

  int pendingSendCount(NodeId peer);
  int get totalPendingSendCount;
}
```

(Adaptation rule: the interface's members are exactly the four things `NearbyMessagePort` consumes today — `sendGossipMessage`, incoming delivery, `pendingSendCount`, `totalPendingSendCount`. If `sendGossipMessage`'s real signature differs from the sketch, the REAL signature wins; do not add members the port doesn't use.)

- [ ] **Step 1: Write the failing test — the port works against the interface, and the slot is gone**

In `nearby_message_port_test.dart`, add (or create the file with):

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_nearby/src/application/interfaces/message_dispatcher.dart';
import 'package:gossip_nearby/src/infrastructure/ports/nearby_message_port.dart';

class _FakeDispatcher implements MessageDispatcher {
  final sent = <(NodeId, Uint8List)>[];
  final _incoming = StreamController<IncomingMessage>.broadcast();

  @override
  Future<void> sendGossipMessage(NodeId destination, Uint8List bytes,
      {MessagePriority priority = MessagePriority.normal}) async {
    sent.add((destination, bytes));
  }

  @override
  Stream<IncomingMessage> get incomingMessages => _incoming.stream;

  @override
  int pendingSendCount(NodeId peer) => 0;

  @override
  int get totalPendingSendCount => 0;

  void emit(IncomingMessage m) => _incoming.add(m);
}

void main() {
  final peer = NodeId('22222222-2222-2222-2222-222222222222');

  test('port sends through the dispatcher interface', () async {
    final dispatcher = _FakeDispatcher();
    final port = NearbyMessagePort(dispatcher);
    await port.send(peer, Uint8List.fromList([1, 2, 3]));
    expect(dispatcher.sent.single.$1, peer);
  });

  test('port forwards the dispatcher incoming stream', () async {
    final dispatcher = _FakeDispatcher();
    final port = NearbyMessagePort(dispatcher);
    final received = <IncomingMessage>[];
    final sub = port.incoming.listen(received.add);

    dispatcher.emit(IncomingMessage(sender: peer, bytes: Uint8List.fromList([7])));
    await Future<void>.delayed(Duration.zero);

    expect(received.single.sender, peer);
    await sub.cancel();
  });
}
```

(If `IncomingMessage`'s constructor differs — positional args, extra fields — mirror its real shape; the assertions are the contract.)

Run: `flutter test test/infrastructure/ports/nearby_message_port_test.dart`
Expected: FAIL — `message_dispatcher.dart` doesn't exist / `NearbyMessagePort` takes a `ConnectionService`.

- [ ] **Step 2: Implement**

1. Create the interface file (above).
2. `ConnectionService`: add `implements MessageDispatcher`; replace the `onGossipMessage` slot (:103) and typedef (:20) with a `StreamController<IncomingMessage>.broadcast()` + `Stream<IncomingMessage> get incomingMessages`; the delivery site (:574) becomes `_incomingController.add(IncomingMessage(sender: nodeId, bytes: payload));` (mirror IncomingMessage's real shape). Close the controller wherever `ConnectionService` disposes today.
3. `NearbyMessagePort`: field type `MessageDispatcher`, constructor takes the interface; `incoming` forwards `_dispatcher.incomingMessages`; delete `_onGossipMessage`, the slot assignment (:18), and the null-out on close (:50). Remove the `connection_service.dart` import — the port must import ONLY the application interface + gossip.
4. `NearbyTransport` wiring (~:190): unchanged call shape (`NearbyMessagePort(connectionService)`) — it now flows through the interface type.

- [ ] **Step 3: Verify green + the cycle is gone**

Run: `flutter test && dart analyze` → all green, zero issues.

```bash
grep -n "application/services/connection_service" lib/src/infrastructure/ports/nearby_message_port.dart
```
Expected: no output (the infra→application-concrete edge is dead; only the interface import remains).

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor(gossip_nearby): application-owned MessageDispatcher seam; delete the callback slot (ARCH3-4)"
```

---

### Task 5: bluey — frame codecs into a protocol layer (ARCH3-3)

**Files:**
- Move: `packages/gossip_bluey/lib/src/infrastructure/codec/frame_codec.dart` → `packages/gossip_bluey/lib/src/protocol/frame_codec.dart`
- Move: `packages/gossip_bluey/lib/src/infrastructure/codec/control_frame_codec.dart` → `packages/gossip_bluey/lib/src/protocol/control_frame_codec.dart`
- Modify: `packages/gossip_bluey/lib/src/application/services/connection_manager.dart` (imports :16-17)
- Move tests: any `test/infrastructure/codec/*_test.dart` → `test/protocol/` (locate with `ls test/infrastructure/codec/`)

**Interfaces:** pure move — every class keeps its name and API; only paths change. `ConnectionManager` keeps orchestration (retry counts, backoff policy) and calls the codecs at their new home.

- [ ] **Step 1: Move + rewrite imports**

```bash
cd packages/gossip_bluey
git mv lib/src/infrastructure/codec/frame_codec.dart lib/src/protocol/frame_codec.dart
git mv lib/src/infrastructure/codec/control_frame_codec.dart lib/src/protocol/control_frame_codec.dart
grep -rln "infrastructure/codec/" lib test | xargs sed -i '' 's|infrastructure/codec/|protocol/|g'
```
Move any codec test files to `test/protocol/` with `git mv`. Verify only `connection_manager.dart` imported them in lib (verified 2026-08-21) — if the sed touched more lib files, list them in your report.

- [ ] **Step 2: Gate**

Run: `flutter test && dart analyze` → all green, zero issues (behavior-neutral move; the suites are the net).

- [ ] **Step 3: Commit**

```bash
git commit -m "refactor(gossip_bluey): frame + control-frame codecs into protocol layer (ARCH3-3)"
```

---

### Task 6: bluey — MessageDispatcher interface into the application layer (ARCH3-4)

**Files:**
- Create: `packages/gossip_bluey/lib/src/application/interfaces/message_dispatcher.dart`
- Modify: `packages/gossip_bluey/lib/src/infrastructure/ports/bluey_message_port.dart` (remove the interface definition, import it instead)
- Modify: `packages/gossip_bluey/lib/src/application/services/connection_manager.dart` (import :18 swaps from the infrastructure port file to the application interface)

**Interfaces:** the `MessageDispatcher` interface MOVES VERBATIM (same members: `sendGossipMessage`, `incomingMessages`, `pendingSendCount`, `totalPendingSendCount`, `close` — its full text lives at the top of today's `bluey_message_port.dart`). `BlueyMessagePort` keeps implementing `MessagePort` by delegating to it.

- [ ] **Step 1: Move the interface**

Cut the `MessageDispatcher` declaration (with its doc comments) out of `bluey_message_port.dart` into the new `application/interfaces/message_dispatcher.dart` (imports: `dart:typed_data`, `package:gossip/gossip.dart`). In `bluey_message_port.dart`, import `../../application/interfaces/message_dispatcher.dart`. In `connection_manager.dart`, replace the `../../infrastructure/ports/bluey_message_port.dart` import with `../interfaces/message_dispatcher.dart`.

- [ ] **Step 2: Verify the edge died + gate**

```bash
grep -n "infrastructure/ports" packages/gossip_bluey/lib/src/application/services/connection_manager.dart
```
Expected: no output — the application layer no longer imports infrastructure.

Run: `flutter test && dart analyze` → all green, zero issues.

- [ ] **Step 3: Commit**

```bash
git commit -m "refactor(gossip_bluey): MessageDispatcher interface to application layer (ARCH3-4)"
```

---

### Task 7: bluey — owned lifecycle enums (ARCH3-5)

**Files:**
- Create: `packages/gossip_bluey/lib/src/domain/value_objects/advertising_state.dart`
- Create: `packages/gossip_bluey/lib/src/domain/value_objects/scan_state.dart`
- Modify: `packages/gossip_bluey/lib/src/domain/interfaces/bluey_port.dart` (:108-129 — speak owned types)
- Modify: `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart` (translate at the adapter)
- Modify: `packages/gossip_bluey/lib/src/facade/bluey_transport.dart` (:207-223 — owned types; drop the `bluey.` prefix on these)
- Modify: `packages/gossip_bluey/lib/gossip_bluey.dart` (barrel: export both new files)
- Modify: `packages/gossip_bluey/test/fakes/fake_bluey_port.dart` + every test using `bluey.AdvertisingState`/`bluey.ScanState`
- Test: `packages/gossip_bluey/test/domain/value_objects/lifecycle_states_test.dart` (new)
- Modify: `examples/gossip_chat` — 4 lib files + 4 test files drop `package:bluey` (verified list: `lib/application/services/connection_service.dart`, `lib/presentation/screens/peers_screen.dart`, `lib/presentation/controllers/chat_controller.dart`, `lib/presentation/widgets/topology_controls.dart`, and the 4 test files grep finds)

**Interfaces:**
- Produces (public API of gossip_bluey — value sets verified against bluey 2026-08-21):

```dart
// lib/src/domain/value_objects/advertising_state.dart
import 'package:bluey/bluey.dart' as bluey;

/// Owned advertising lifecycle (ARCH3-5) — consumers never import bluey.
/// Values mirror bluey's enum 1:1; translation happens ONLY here.
enum AdvertisingState {
  idle,
  starting,
  advertising,
  stopping,
  invalidated;

  static AdvertisingState fromBluey(bluey.AdvertisingState s) =>
      switch (s) {
        bluey.AdvertisingState.idle => idle,
        bluey.AdvertisingState.starting => starting,
        bluey.AdvertisingState.advertising => advertising,
        bluey.AdvertisingState.stopping => stopping,
        bluey.AdvertisingState.invalidated => invalidated,
      };
}
```

```dart
// lib/src/domain/value_objects/scan_state.dart
import 'package:bluey/bluey.dart' as bluey;

/// Owned scan lifecycle (ARCH3-5) — consumers never import bluey.
enum ScanState {
  stopped,
  starting,
  scanning,
  stopping,
  invalidated;

  static ScanState fromBluey(bluey.ScanState s) => switch (s) {
        bluey.ScanState.stopped => stopped,
        bluey.ScanState.starting => starting,
        bluey.ScanState.scanning => scanning,
        bluey.ScanState.stopping => stopping,
        bluey.ScanState.invalidated => invalidated,
      };
}
```

(Design note: the domain VO importing `bluey` for its `fromBluey` mapper mirrors the package's existing `BluetoothAdapterState` ACL pattern — follow the in-repo precedent exactly; if `BluetoothAdapterState` keeps its mapper in the adapter instead, put `fromBluey` there and keep the enums import-free. Check first; match the precedent.)

- [ ] **Step 1: Write the failing translation test**

```dart
// test/domain/value_objects/lifecycle_states_test.dart
import 'package:bluey/bluey.dart' as bluey;
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/gossip_bluey.dart';

void main() {
  test('every bluey AdvertisingState maps to exactly one owned value', () {
    for (final s in bluey.AdvertisingState.values) {
      expect(AdvertisingState.fromBluey(s).name, s.name,
          reason: 'the owned enum mirrors bluey 1:1');
    }
    expect(AdvertisingState.values.length,
        bluey.AdvertisingState.values.length);
  });

  test('every bluey ScanState maps to exactly one owned value', () {
    for (final s in bluey.ScanState.values) {
      expect(ScanState.fromBluey(s).name, s.name);
    }
    expect(ScanState.values.length, bluey.ScanState.values.length);
  });
}
```

(Adapt the `fromBluey` call site if the precedent check moved the mapper to the adapter.)

Run: `flutter test test/domain/value_objects/lifecycle_states_test.dart`
Expected: FAIL — files don't exist.

- [ ] **Step 2: Implement the enums; watch the test pass**

- [ ] **Step 3: Push the owned types through port, adapter, facade, fake, barrel**

- `bluey_port.dart` :108-129: `advertisingState`/`advertisingStateStream`/`scanState`/`scanStateStream` return the OWNED types; fix the doc references.
- `bluey_port_impl.dart`: translate at the boundary (`AdvertisingState.fromBluey(...)`, `.map(AdvertisingState.fromBluey)` on streams; same for scan).
- `bluey_transport.dart` :207-223: types become owned; the `bluey.` prefixes on these lines go away.
- `fake_bluey_port.dart`: state fields/streams switch to owned types.
- Barrel: `export 'src/domain/value_objects/advertising_state.dart'; export 'src/domain/value_objects/scan_state.dart';`
- Update every gossip_bluey test that names `bluey.AdvertisingState`/`bluey.ScanState` (e.g. `test/facade/bluey_transport_test.dart` uses `bluey.AdvertisingState.idle`/`advertising` and `bluey.ScanState.scanning`/`stopped`) to the owned enums — assertions keep the same VALUES, only the type prefix changes. Remove `package:bluey` imports that become unused.

Run: `flutter test && dart analyze` → all green, zero issues.

- [ ] **Step 4: Purge bluey from the example app**

In the 8 gossip_chat files: replace `bluey.AdvertisingState` → `AdvertisingState`, `bluey.ScanState` → `ScanState` (now from `package:gossip_bluey/gossip_bluey.dart`), delete the `package:bluey` imports.

Run: `cd examples/gossip_chat && flutter test && dart analyze` → green, zero issues.

```bash
grep -rn "package:bluey" examples/gossip_chat/lib examples/gossip_chat/test
```
Expected: no output — the app composes only the public API.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(gossip_bluey): owned AdvertisingState/ScanState lifecycle enums (ARCH3-5)"
```

---

### Task 8: Full-monorepo gate + docs bookkeeping

**Files:**
- Modify: `docs/roadmap.md` (health-architecture-alignment line: part 1 done, note the commits)
- Modify: `docs/backlog/health-architecture-alignment.md` (Related: link this plan + spec as "Part 1 done")
- No code.

- [ ] **Step 1: Full gates**

Run from repo root: `melos run test && melos run analyze`, then `cd examples/gossip_chat && flutter test && dart analyze`.
Expected: every package green, zero analyzer issues anywhere.

- [ ] **Step 2: Roadmap + backlog updates**

Roadmap line for health-architecture-alignment flips to `◐` (part 1 of 2 done) with a note naming the Part-1 commits; backlog file's Related section links `docs/superpowers/specs/2026-08-21-architecture-honesty-fixes-design.md` and this plan as shipped. (Priority/status stay ONLY in the roadmap.)

- [ ] **Step 3: Commit**

```bash
git commit -m "docs: roadmap/backlog — architecture honesty fixes (Part 1) shipped"
```

---

## Self-Review Notes

- **Spec coverage:** ARCH3-2 → T1; ARCH3-6 → T2; ARCH3-3 nearby → T3, bluey → T5; ARCH3-4 nearby → T4, bluey → T6; ARCH3-5 → T7; ADR-005 amendment → T3 Step 4; gates → every task + T8. Out-of-scope items (ARCH3-1, ADR-010, core moves) appear in no task. ✓
- **Verified-fact anchors:** dead-bridge consumer list, PeerService call sites (coordinator.dart:654/:740), zero-caller mutation methods, codec importer lists, callback-slot lines (:20/:103/:574), bluey enum value sets, example-app file list — all grepped 2026-08-21; every task re-verifies its own claim before acting.
- **Known adaptation points (deliberate):** `sendGossipMessage`'s exact signature (T4), `IncomingMessage`'s constructor shape (T4), the `fromBluey` mapper's home (T7 — follow the `BluetoothAdapterState` precedent), frame-builder helpers in the WireDispatcher test (T3 — mirror the codec test). The assertions are the contract.
- **Type consistency:** nearby's new `MessageDispatcher` (T4) is nearby-local and deliberately mirrors bluey's (T6) — same member names, no shared file (different packages). T3's `WireDispatcher.classify` returns the existing `MessageType`. ✓
