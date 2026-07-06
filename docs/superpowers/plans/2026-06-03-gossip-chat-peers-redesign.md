# gossip_chat peers screen redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current peers screen with a unified discovery + connection view: every nearby peer the BLE scanner sees is rendered with explicit per-peer connection status, RSSI-based BLE signal indicator, and a separate gossip-assessed health indicator. The user controls topology directly via independent Advertise/Discover toggles, and chooses between manual tap-to-connect and auto-connect (mesh) modes. Discovered-but-never-connected peers vanish when discovery stops. Gossip protocol cadences become user-tunable through a settings sheet.

**Architecture:** Three layers of change:

- **gossip package** (`packages/gossip`) — extend `CoordinatorConfig` with timing knobs (`gossipInterval`, `probeInterval`, `pingTimeout`, `adaptiveTimingEnabled`) and plumb them through `Coordinator.create` into the existing `GossipEngine` / `FailureDetector` constructors (both already accept these as optionals; the facade just doesn't surface them today).
- **gossip_bluey** (`packages/gossip_bluey`) — split today's monolithic `ConnectionService` into three application services with cleaner DDD seams: `DiscoveryService` (owns the scan subscription and current-candidates map; emits but never connects), `ConnectionManager` (owns the registry, backoff, send-queue, frame-decoders; explicit `connectTo(ScanCandidate)` and `disconnect(NodeId)`), and `AutoConnectPolicy` (subscribes the discovery stream and drives the connection manager; toggleable). Enrich `ScanCandidate` with `rssi` and `lastSeen` (sourced from `bluey.ScanResult`). Surface `advertisingState` / `scanState` enums + replay-current streams on `BlueyTransport`, plus a new `candidates` stream and explicit `connectTo` / `disconnect` / `setConnectionMode` API. Drop the existing boolean `isAdvertising` / `isDiscovering` getters.
- **gossip_chat** — introduce `DiscoveredPeer` view model (presentation), derive `BleHealth` from RSSI buckets (separate from existing SWIM-based `SignalStrengthManager` output), extend `ConnectionStatus` and `PeerConnectionStatus` with explicit transient states, replace the merge step in `ChatController` to fold candidate stream + peer events + gossip status into a single `Map<dynamic, DiscoveredPeer>`. On `scanState` transition out of `scanning`, prune any peer never admitted to the connection registry. Rebuild `PeersScreen` as a unified list with per-row status pill + dual indicators, replace the single button row with Advertise/Discover toggles + Mesh/Manual segmented control, and add a `SettingsSheet` for gossip-rate knobs.

**Tech Stack:** Dart 3 / Flutter, gossip package (this workspace), gossip_bluey package (this workspace), bluey BLE library (currently pointed at local `i343-bisect-instrumentation` branch via path overrides), mocktail for unit-test mocks, melos workspace.

**Breaking changes:** OK throughout. User has explicitly opted out of backwards compatibility for this redesign.

**Locked design decisions** (from brainstorming session 2026-06-03):
- Tap to connect (single tap on a discovered peer = connect attempt).
- No stale-discovery TTL — the prune-on-stop rule replaces it.
- Mode toggle does not persist across sessions; default is `manual`.
- Switching auto → manual keeps current connections, only stops the auto-connect policy. Manual → auto subscribes the policy to the current candidate stream.
- Settings changes (gossip rate) apply on next `Start Networking`; no live reconfigure.
- Indirect (gossip-relayed) peers stay in a separate, visually distinct section.

**Out of scope for this plan:**
- Live-reconfigure of gossip timings while connected (would require a new `Coordinator.reconfigure(...)` path).
- Persistence of mode / settings across app launches.
- Connection-attempt retry UX beyond "tap a `failed` peer to try again."
- Per-peer details screen (current plan keeps the peer-tile-as-leaf interaction model).

---

## File structure

### gossip package

**Modified:**
- `packages/gossip/lib/src/facade/coordinator_config.dart` — add four optional timing fields.
- `packages/gossip/lib/src/facade/coordinator.dart` — pass the new fields through to `GossipEngine` and `FailureDetector` constructors at `:307-334`.

**New tests:**
- `packages/gossip/test/facade/coordinator_config_timing_test.dart` — config-value tests.
- `packages/gossip/test/facade/coordinator_timing_passthrough_test.dart` — wiring test using fake ports.

### gossip_bluey package

**New files:**
- `packages/gossip_bluey/lib/src/domain/value_objects/connection_mode.dart` — `enum ConnectionMode { manual, auto }`.
- `packages/gossip_bluey/lib/src/application/services/discovery_service.dart` — owns scan subscription + current candidates map.
- `packages/gossip_bluey/lib/src/application/services/auto_connect_policy.dart` — subscribes discovery stream, drives connection manager.
- `packages/gossip_bluey/test/domain/value_objects/connection_mode_test.dart`
- `packages/gossip_bluey/test/application/services/discovery_service_test.dart`
- `packages/gossip_bluey/test/application/services/auto_connect_policy_test.dart`
- `packages/gossip_bluey/test/facade/bluey_transport_candidates_test.dart`
- `packages/gossip_bluey/test/facade/bluey_transport_state_streams_test.dart`

**Modified:**
- `packages/gossip_bluey/lib/src/domain/value_objects/scan_candidate.dart` — add `rssi` and `lastSeen`.
- `packages/gossip_bluey/lib/src/application/services/connection_service.dart` — **rename to `connection_manager.dart`**, narrow scope: remove `_onCandidate` / `_scanSub` / `startDiscovery` / `stopDiscovery` / `_discoveryFilter` / `_addressBackoff` / `_connectingAddresses` / `_addressToNodeId` (move to discovery service / auto-connect policy as appropriate). Add public `Future<NodeId> connectTo(ScanCandidate)` that wraps `port.connectAndIdentify` and updates the registry. Keep send-queue, decoders, registry ownership.
- `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart` — at `:599-609`, populate `ScanCandidate.rssi = result.rssi` and `ScanCandidate.lastSeen = _clock.now()`. Add `Scanner.state` snapshot + `Scanner.stateChanges` plumbing if not already present (it is — at `:594-595`); expose as public getter `scanState` and a broadcast `scanStateStream`. Same shape for `advertisingState` / `advertisingStateStream` (already maintained internally at `:218-220`).
- `packages/gossip_bluey/lib/src/domain/interfaces/bluey_port.dart` — drop `isAdvertising` / `isDiscovering`; add `advertisingState` / `advertisingStateStream` / `scanState` / `scanStateStream`.
- `packages/gossip_bluey/lib/src/facade/bluey_transport.dart` — drop boolean getters; add state enums + streams; add `candidates : Stream<List<ScanCandidate>>` (or `Stream<ScanCandidate>` — see Task C2); add `connectionMode` snapshot + setter; add `connectTo(ScanCandidate)` and `disconnect(NodeId)`; advertising and discovery controls become independent (`startAdvertising` / `stopAdvertising` / `startDiscovery` / `stopDiscovery`).
- `packages/gossip_bluey/test/fakes/fake_bluey_port.dart` — implement the new BlueyPort surface.

### gossip_chat

**New files:**
- `examples/gossip_chat/lib/presentation/view_models/discovered_peer.dart` — unified row model.
- `examples/gossip_chat/lib/presentation/view_models/ble_health.dart` — RSSI-bucket value object + thresholds.
- `examples/gossip_chat/lib/presentation/widgets/peer_status_pill.dart`
- `examples/gossip_chat/lib/presentation/widgets/ble_signal_indicator.dart`
- `examples/gossip_chat/lib/presentation/widgets/topology_controls.dart` — Advertise + Discover chips + Mesh/Manual toggle.
- `examples/gossip_chat/lib/presentation/screens/settings_sheet.dart`
- `examples/gossip_chat/lib/application/services/gossip_config_service.dart` — owns the user-tunable `CoordinatorConfig` knobs in memory.
- Tests under matching test paths.

**Modified:**
- `examples/gossip_chat/lib/presentation/controllers/chat_controller.dart` — replace `peers : List<PeerState>` with `peers : List<DiscoveredPeer>`; subscribe candidates stream + advertising/scan state streams; add prune-on-stop handler; add `mode`, `setMode`, `tapPeer`, `setAdvertising`, `setDiscovering` methods; extend `ConnectionStatus` enum to surface transients.
- `examples/gossip_chat/lib/presentation/screens/peers_screen.dart` — fully rebuilt (see Phase E).
- `examples/gossip_chat/lib/application/services/connection_service.dart` — drop today's `isAdvertising` / `isDiscovering` boolean forwarders; add forwarders for new state enums, candidates stream, mode toggle, connectTo, etc.
- `examples/gossip_chat/lib/presentation/widgets/connection_status_bar.dart` — extend status text to cover transient and invalidated states; let the bar reflect the composed (advertising × scanning) signal.

---

## Phase A — gossip package: configurable timing

### Task A1: Extend `CoordinatorConfig` with timing knobs

**Files:**
- Modify: `packages/gossip/lib/src/facade/coordinator_config.dart`
- Create: `packages/gossip/test/facade/coordinator_config_timing_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/gossip/test/facade/coordinator_config_timing_test.dart
import 'package:gossip/src/facade/coordinator_config.dart';
import 'package:test/test.dart';

void main() {
  group('CoordinatorConfig timing knobs', () {
    test('defaults are all null (= adaptive)', () {
      const cfg = CoordinatorConfig();
      expect(cfg.gossipInterval, isNull);
      expect(cfg.probeInterval, isNull);
      expect(cfg.pingTimeout, isNull);
      expect(cfg.adaptiveTimingEnabled, isTrue);
    });

    test('explicit values are preserved', () {
      const cfg = CoordinatorConfig(
        gossipInterval: Duration(milliseconds: 250),
        probeInterval: Duration(milliseconds: 750),
        pingTimeout: Duration(seconds: 2),
        adaptiveTimingEnabled: false,
      );
      expect(cfg.gossipInterval, const Duration(milliseconds: 250));
      expect(cfg.probeInterval, const Duration(milliseconds: 750));
      expect(cfg.pingTimeout, const Duration(seconds: 2));
      expect(cfg.adaptiveTimingEnabled, isFalse);
    });

    test('CoordinatorConfig.defaults still has null timing fields', () {
      expect(CoordinatorConfig.defaults.gossipInterval, isNull);
      expect(CoordinatorConfig.defaults.probeInterval, isNull);
      expect(CoordinatorConfig.defaults.pingTimeout, isNull);
      expect(CoordinatorConfig.defaults.adaptiveTimingEnabled, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd packages/gossip && dart test test/facade/coordinator_config_timing_test.dart
```

Expected: compile error / missing field.

- [ ] **Step 3: Add the fields to `CoordinatorConfig`**

In `packages/gossip/lib/src/facade/coordinator_config.dart`, extend the class. Preserve existing fields verbatim; add the four new fields with the contract documented:

```dart
class CoordinatorConfig {
  // ... existing fields unchanged ...

  /// Explicit gossip round interval. When null (default), `GossipEngine`
  /// computes the interval adaptively from per-peer RTT, bounded to
  /// [100ms, 5s]. When non-null, the engine uses this value verbatim.
  final Duration? gossipInterval;

  /// Explicit SWIM probe interval. When null (default), `FailureDetector`
  /// derives the interval adaptively from pingTimeout * 3.
  final Duration? probeInterval;

  /// Explicit SWIM ping timeout. When null (default), `FailureDetector`
  /// computes the timeout adaptively from per-peer RTT.
  final Duration? pingTimeout;

  /// Whether to allow adaptive timing for any knob left null above.
  /// When false, the engine and failure-detector use their internal
  /// fallback constants instead of adaptive computation.
  final bool adaptiveTimingEnabled;

  const CoordinatorConfig({
    // ... existing parameters unchanged ...
    this.gossipInterval,
    this.probeInterval,
    this.pingTimeout,
    this.adaptiveTimingEnabled = true,
  });

  static const CoordinatorConfig defaults = CoordinatorConfig();
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd packages/gossip && dart test test/facade/coordinator_config_timing_test.dart
```

Expected: PASS.

- [ ] **Step 5: Run all package tests to verify nothing broke**

```bash
cd packages/gossip && dart test
```

Expected: 262+ tests pass.

- [ ] **Step 6: Commit**

```bash
git add packages/gossip/lib/src/facade/coordinator_config.dart packages/gossip/test/facade/coordinator_config_timing_test.dart
git commit -m "feat(gossip): add timing knobs to CoordinatorConfig (gossipInterval, probeInterval, pingTimeout, adaptiveTimingEnabled)"
```

### Task A2: Plumb timing knobs through `Coordinator.create`

**Files:**
- Modify: `packages/gossip/lib/src/facade/coordinator.dart`
- Create: `packages/gossip/test/facade/coordinator_timing_passthrough_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/gossip/test/facade/coordinator_timing_passthrough_test.dart
//
// Verifies that CoordinatorConfig timing fields reach the GossipEngine
// and FailureDetector. Uses an in-memory port pair and probes the
// effective interval reported by the engine/detector after construction.

import 'package:gossip/gossip.dart';
import 'package:gossip/src/protocol/gossip_engine.dart';
import 'package:test/test.dart';
// ... import in-memory test fixtures used elsewhere in the package ...

void main() {
  group('Coordinator timing passthrough', () {
    test('static gossipInterval propagates to GossipEngine', () async {
      // Construct Coordinator with explicit gossipInterval; assert the
      // resulting engine reports the static value (not an adaptive one).
      // See coordinator_test.dart for the fixture setup pattern.
      // ...
    });

    test('static probeInterval propagates to FailureDetector', () async { ... });

    test('null defaults preserve current adaptive behavior', () async { ... });
  });
}
```

(Concrete fixture wiring follows the existing `coordinator_test.dart` pattern; the implementer mirrors it.)

- [ ] **Step 2: Run test to verify it fails**

```bash
cd packages/gossip && dart test test/facade/coordinator_timing_passthrough_test.dart
```

- [ ] **Step 3: Pass the fields through in `Coordinator.create`**

In `packages/gossip/lib/src/facade/coordinator.dart` at `:307-334`, extend the `GossipEngine` and `FailureDetector` constructors:

```dart
coordinator._gossipEngine = GossipEngine(
  localNode: localNode,
  peerRegistry: peerRegistry,
  entryRepository: entryRepository,
  timePort: timerPort,
  messagePort: messagePort,
  onError: coordinator._handleError,
  onEntriesMerged: coordinator._handleEntriesMerged,
  onLog: onLog,
  hlcClock: hlcClock,
  localNodeRepository: localNodeRepository,
  random: random,
  adaptiveTimingEnabled: cfg.adaptiveTimingEnabled,
  gossipInterval: cfg.gossipInterval,
);

coordinator._failureDetector = FailureDetector(
  localNode: localNode,
  peerRegistry: peerRegistry,
  timePort: timerPort,
  messagePort: messagePort,
  onError: coordinator._handleError,
  onLog: onLog,
  random: random,
  failureThreshold: cfg.suspicionThreshold,
  unreachableThreshold: cfg.unreachableThreshold,
  unreachableProbeInterval: cfg.unreachableProbeInterval,
  probeInterval: cfg.probeInterval,
  pingTimeout: cfg.pingTimeout,
  rttTracker: failureDetectorRttTracker,
);
```

- [ ] **Step 4: Run tests, verify pass**

```bash
cd packages/gossip && dart test
```

- [ ] **Step 5: Commit**

```bash
git add packages/gossip/lib/src/facade/coordinator.dart packages/gossip/test/facade/coordinator_timing_passthrough_test.dart
git commit -m "feat(gossip): plumb CoordinatorConfig timing knobs through to GossipEngine and FailureDetector"
```

---

## Phase B — gossip_bluey: enrich ScanCandidate + surface state

### Task B1: Add `rssi` and `lastSeen` to `ScanCandidate`

**Files:**
- Modify: `packages/gossip_bluey/lib/src/domain/value_objects/scan_candidate.dart`
- Modify: `packages/gossip_bluey/test/domain/value_objects/scan_candidate_test.dart` (or create if absent)

- [ ] **Step 1: Write the failing test**

```dart
// packages/gossip_bluey/test/domain/value_objects/scan_candidate_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/src/domain/value_objects/ble_address.dart';
import 'package:gossip_bluey/src/domain/value_objects/scan_candidate.dart';

void main() {
  group('ScanCandidate', () {
    final addr = BleAddress('AA:BB:CC:DD:EE:FF');
    final t = DateTime.utc(2026, 6, 3, 12);

    test('exposes address, displayName, rssi, lastSeen', () {
      final c = ScanCandidate(
        address: addr,
        displayName: 'Pixel 6a',
        rssi: -48,
        lastSeen: t,
      );
      expect(c.address, addr);
      expect(c.displayName, 'Pixel 6a');
      expect(c.rssi, -48);
      expect(c.lastSeen, t);
    });

    test('displayName and rssi are nullable; lastSeen is required', () {
      final c = ScanCandidate(address: addr, lastSeen: t);
      expect(c.displayName, isNull);
      expect(c.rssi, isNull);
    });

    test('value equality by all four fields', () {
      final a = ScanCandidate(address: addr, displayName: 'X', rssi: -50, lastSeen: t);
      final b = ScanCandidate(address: addr, displayName: 'X', rssi: -50, lastSeen: t);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd packages/gossip_bluey && flutter test test/domain/value_objects/scan_candidate_test.dart
```

- [ ] **Step 3: Extend `ScanCandidate`**

```dart
// packages/gossip_bluey/lib/src/domain/value_objects/scan_candidate.dart
import 'ble_address.dart';

class ScanCandidate {
  final BleAddress address;
  final String? displayName;

  /// Last-known signal strength in dBm. Null when the underlying scanner
  /// did not provide an RSSI value for this emission.
  final int? rssi;

  /// Observation time of the most recent emission for this address.
  /// Used by consumers to decide whether to drop a peer that has stopped
  /// advertising.
  final DateTime lastSeen;

  const ScanCandidate({
    required this.address,
    required this.lastSeen,
    this.displayName,
    this.rssi,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScanCandidate &&
          address == other.address &&
          displayName == other.displayName &&
          rssi == other.rssi &&
          lastSeen == other.lastSeen;

  @override
  int get hashCode => Object.hash(address, displayName, rssi, lastSeen);
}
```

- [ ] **Step 4: Update `BlueyPortImpl.scanForCandidates` to populate the fields**

At `bluey_port_impl.dart:599-609`, replace the candidate construction:

```dart
.listen(
  (result) {
    final address = BleAddress(result.device.address.value);
    _devicesByAddress[address] = result.device;
    if (!controller.isClosed) {
      controller.add(
        ScanCandidate(
          address: address,
          displayName: result.device.name,
          rssi: result.rssi,
          lastSeen: _clock.now(),
        ),
      );
    }
  },
  onError: controller.addError,
)
```

Verify that `_clock` is the existing clock dependency on the port (already used elsewhere in this file for backoff timing). If not, inject it; do not call `DateTime.now()` directly.

- [ ] **Step 5: Run all gossip_bluey tests; fix call sites of `ScanCandidate(...)` in tests**

```bash
cd packages/gossip_bluey && flutter test
```

Expected: existing fake_bluey_port and fixture call sites fail compile. Repair each to include `lastSeen:` (use any test clock value).

- [ ] **Step 6: Commit**

```bash
git add packages/gossip_bluey/lib/src/domain/value_objects/scan_candidate.dart \
        packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart \
        packages/gossip_bluey/test/
git commit -m "feat(gossip_bluey): enrich ScanCandidate with rssi and lastSeen (breaking: required lastSeen field)"
```

### Task B2: Surface `advertisingState` / `scanState` enums and streams on `BlueyTransport`

**Files:**
- Modify: `packages/gossip_bluey/lib/src/domain/interfaces/bluey_port.dart`
- Modify: `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart`
- Modify: `packages/gossip_bluey/lib/src/facade/bluey_transport.dart`
- Modify: `packages/gossip_bluey/test/fakes/fake_bluey_port.dart`
- Create: `packages/gossip_bluey/test/facade/bluey_transport_state_streams_test.dart`

- [ ] **Step 1: Drop `isAdvertising` / `isDiscovering` from `BlueyPort` interface**

In `bluey_port.dart`, replace the boolean getters with:

```dart
/// Current advertising lifecycle state. Replays via [advertisingStateStream].
bluey.AdvertisingState get advertisingState;

/// Stream of advertising-state transitions. Replays the current value on
/// subscribe (Stream.multi pattern; matches bluey's I334 convention).
Stream<bluey.AdvertisingState> get advertisingStateStream;

/// Current scan lifecycle state.
bluey.ScanState get scanState;

/// Stream of scan-state transitions. Replays current value on subscribe.
Stream<bluey.ScanState> get scanStateStream;
```

(Import `package:bluey/bluey.dart` as `bluey` in the interface file.)

- [ ] **Step 2: Implement on `BlueyPortImpl`**

In `bluey_port_impl.dart`:
- Replace `bool get isAdvertising => _advertisingState == bluey.AdvertisingState.advertising;` (line 157-158) with `bluey.AdvertisingState get advertisingState => _advertisingState;`.
- Add a broadcast `StreamController<bluey.AdvertisingState>` (`_advertisingStateController`) that the existing `_advertisingStateSub` writes to (it currently writes only to `_advertisingState` at `:220`). The controller must replay-on-subscribe — use `Stream.multi` or a re-broadcast through a `BehaviorSubject` pattern (no rxdart dep — implement manually if necessary, see [the existing bluetoothStateStream pattern]).
- Same shape for `scanState` and `scanStateStream`. The internal `_scanState` and `_scanStateSub` already exist at `:594-595`.
- Drop the `bool get isDiscovering` getter.

- [ ] **Step 3: Update `BlueyTransport` facade**

In `bluey_transport.dart`:
- Drop `bool get isAdvertising` and `bool get isDiscovering` (lines 161 and 167).
- Add forwarding getters:

```dart
bluey.AdvertisingState get advertisingState => _port.advertisingState;
Stream<bluey.AdvertisingState> get advertisingStateStream =>
    _port.advertisingStateStream;
bluey.ScanState get scanState => _port.scanState;
Stream<bluey.ScanState> get scanStateStream => _port.scanStateStream;
```

- [ ] **Step 4: Test that the streams replay-on-subscribe**

```dart
// packages/gossip_bluey/test/facade/bluey_transport_state_streams_test.dart
test('advertisingStateStream replays current value on subscribe', () async {
  // ... construct transport with fake port at advertisingState=advertising ...
  final first = await transport.advertisingStateStream.first;
  expect(first, bluey.AdvertisingState.advertising);
});

test('subsequent subscribers see independent replay', () async { ... });

test('scanState transitions deliver every state change', () async { ... });
```

- [ ] **Step 5: Update `FakeBlueyPort` to implement the new getters**

- [ ] **Step 6: Fix every call site that referenced `isAdvertising` / `isDiscovering`**

Repository-wide grep:
```bash
grep -rn "isAdvertising\|isDiscovering" packages/gossip_bluey examples/gossip_chat
```

Replace each with the state-enum equivalent (e.g., `state == AdvertisingState.advertising`). Defer the gossip_chat call sites in `chat_controller.dart` to Phase D; just make the package compile.

- [ ] **Step 7: Run all package tests**

```bash
cd packages/gossip_bluey && flutter test
```

- [ ] **Step 8: Commit**

```bash
git add -A packages/gossip_bluey
git commit -m "feat(gossip_bluey): expose AdvertisingState/ScanState enums + replay-current streams; drop boolean isAdvertising/isDiscovering"
```

---

## Phase C — gossip_bluey: split `ConnectionService`

### Task C1: Introduce `ConnectionMode` value object

**Files:**
- Create: `packages/gossip_bluey/lib/src/domain/value_objects/connection_mode.dart`
- Create: `packages/gossip_bluey/test/domain/value_objects/connection_mode_test.dart`

- [ ] **Step 1: Test + implementation**

```dart
// packages/gossip_bluey/lib/src/domain/value_objects/connection_mode.dart

/// Policy for what gossip_bluey does with peers surfaced by the scanner.
enum ConnectionMode {
  /// Default. Discovered peers are exposed via the candidates stream but
  /// no connection is initiated until the consumer explicitly calls
  /// [BlueyTransport.connectTo].
  manual,

  /// Every discovered candidate (subject to backoff, dedup, and the
  /// target-connections cap) triggers an automatic
  /// `connectAndIdentify` attempt — mesh topology.
  auto,
}
```

Test asserts both values exist and have stable names.

- [ ] **Step 2: Commit**

```bash
git add packages/gossip_bluey/lib/src/domain/value_objects/connection_mode.dart \
        packages/gossip_bluey/test/domain/value_objects/connection_mode_test.dart
git commit -m "feat(gossip_bluey): add ConnectionMode value object"
```

### Task C2: Extract `DiscoveryService`

**Goal:** Move scan-subscription ownership out of `ConnectionService`. The new service owns `_scanSub`, maintains a `Map<BleAddress, ScanCandidate>` of current candidates, exposes a broadcast `Stream<ScanCandidate>` (raw stream — list-aggregation happens at the controller layer where it's cheap to recompute) and a `Stream<List<ScanCandidate>>` for snapshot consumers.

**Files:**
- Create: `packages/gossip_bluey/lib/src/application/services/discovery_service.dart`
- Create: `packages/gossip_bluey/test/application/services/discovery_service_test.dart`

- [ ] **Step 1: Test scaffolding**

```dart
group('DiscoveryService', () {
  test('start() subscribes to port.scanForCandidates', () async { ... });
  test('candidates stream replays current snapshot on subscribe', () async { ... });
  test('repeated emissions for the same address overwrite (RSSI/lastSeen update)', () async { ... });
  test('stop() unsubscribes, clears candidates, and emits the empty snapshot', () async { ... });
  test('start() is idempotent', () async { ... });
});
```

- [ ] **Step 2: Implement**

```dart
// packages/gossip_bluey/lib/src/application/services/discovery_service.dart
class DiscoveryService {
  DiscoveryService({
    required BlueyPort port,
    required ServiceUuid serviceUuid,
  })  : _port = port,
        _serviceUuid = serviceUuid;

  final BlueyPort _port;
  final ServiceUuid _serviceUuid;
  StreamSubscription<ScanCandidate>? _sub;
  final Map<BleAddress, ScanCandidate> _current = {};
  final StreamController<ScanCandidate> _events =
      StreamController<ScanCandidate>.broadcast();
  final StreamController<List<ScanCandidate>> _snapshots =
      StreamController<List<ScanCandidate>>.broadcast();

  bool get isRunning => _sub != null;

  /// Per-candidate stream. Emits every refresh.
  Stream<ScanCandidate> get candidates => _events.stream;

  /// Snapshot stream. Emits the current map values whenever the set
  /// changes. Replays the current value on subscribe.
  Stream<List<ScanCandidate>> get snapshots => _snapshots.stream;

  List<ScanCandidate> get currentCandidates =>
      List.unmodifiable(_current.values);

  Future<void> start() async {
    if (_sub != null) return;
    _sub = _port
        .scanForCandidates(serviceUuid: _serviceUuid)
        .listen(_onCandidate);
  }

  Future<void> stop() async {
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    await _port.stopScan();
    _current.clear();
    _snapshots.add(const []);
  }

  void _onCandidate(ScanCandidate c) {
    _current[c.address] = c;
    if (!_events.isClosed) _events.add(c);
    if (!_snapshots.isClosed) {
      _snapshots.add(List.unmodifiable(_current.values));
    }
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
    await _snapshots.close();
  }
}
```

(`snapshots.replayCurrentOnSubscribe` requires a `Stream.multi` pattern — see how `bluey`'s `advertisingStateChanges` does it, or wrap with a small `BehaviorSubject`-style helper in the same file.)

- [ ] **Step 3: Run tests; commit**

```bash
cd packages/gossip_bluey && flutter test test/application/services/discovery_service_test.dart
git add packages/gossip_bluey/lib/src/application/services/discovery_service.dart \
        packages/gossip_bluey/test/application/services/discovery_service_test.dart
git commit -m "feat(gossip_bluey): extract DiscoveryService — owns scan subscription + current-candidates map"
```

### Task C3: Rename `ConnectionService` → `ConnectionManager`, narrow scope, add `connectTo`

**Files:**
- Rename: `packages/gossip_bluey/lib/src/application/services/connection_service.dart` → `connection_manager.dart`
- Rename: `packages/gossip_bluey/test/application/services/connection_service_test.dart` → `connection_manager_test.dart`

- [ ] **Step 1: Rename and remove discovery-related members**

Remove the following from the class:
- `_scanSub`, `_discoveryEnabled`, `_discoveryFilter`
- `_addressBackoff`, `_initialBackoff`, `_maxBackoff`, `_addressLongBackoff`
- `_connectingAddresses`, `_addressToNodeId`
- `startDiscovery`, `stopDiscovery`, `_onCandidate`
- `targetConnections` constructor parameter (moves to AutoConnectPolicy)

Keep:
- registry, decoders, send-queue, metrics, error/event streams
- `sendGossipMessage`, `_sendChunked`
- handling of `PortPeerConnected` / `PortPeerDisconnected` / `PortPeerData` from `port.events`

- [ ] **Step 2: Add `connectTo(ScanCandidate)` public method**

```dart
Future<NodeId> connectTo(ScanCandidate candidate) async {
  if (_connectingAddresses.contains(candidate.address)) {
    throw StateError('already connecting to ${candidate.address}');
  }
  _connectingAddresses.add(candidate.address);
  try {
    return await port.connectAndIdentify(candidate);
  } finally {
    _connectingAddresses.remove(candidate.address);
  }
}
```

The `_connectingAddresses` set survives because `connectTo` needs reentrancy protection. It is no longer used for auto-connect dedup — that moves to `AutoConnectPolicy`.

- [ ] **Step 3: Update tests + call sites**

Repo-wide grep:
```bash
grep -rn "ConnectionService\b" packages/gossip_bluey examples/gossip_chat
```

Rename every reference. Tests under `connection_manager_test.dart` lose discovery-flow tests (those move to discovery + auto-connect tests).

- [ ] **Step 4: Run tests; commit**

```bash
cd packages/gossip_bluey && flutter test
git add -A packages/gossip_bluey
git commit -m "refactor(gossip_bluey): rename ConnectionService -> ConnectionManager, narrow to connection lifecycle; add explicit connectTo"
```

### Task C4: Introduce `AutoConnectPolicy`

**Files:**
- Create: `packages/gossip_bluey/lib/src/application/services/auto_connect_policy.dart`
- Create: `packages/gossip_bluey/test/application/services/auto_connect_policy_test.dart`

- [ ] **Step 1: Test scaffolding**

```dart
group('AutoConnectPolicy', () {
  test('manual mode: candidate emission does NOT trigger connectTo', () async { ... });
  test('auto mode: each new candidate triggers connectTo once', () async { ... });
  test('auto mode: backoff prevents immediate re-attempt after failure', () async { ... });
  test('auto mode: exponential backoff cap', () async { ... });
  test('auto mode: target-connections cap prevents further attempts', () async { ... });
  test('auto mode: known-but-disconnected address eligible after backoff expires', () async { ... });
  test('setMode(manual) preserves existing connections', () async { ... });
  test('setMode(auto) catches up on currently-emitted candidates', () async { ... });
});
```

- [ ] **Step 2: Implement**

```dart
// packages/gossip_bluey/lib/src/application/services/auto_connect_policy.dart

class AutoConnectPolicy {
  AutoConnectPolicy({
    required DiscoveryService discovery,
    required ConnectionManager connections,
    required ConnectionRegistry registry,
    required Clock clock,
    int? targetConnections,
    Duration initialBackoff = const Duration(seconds: 1),
    Duration maxBackoff = const Duration(seconds: 60),
    Duration longBackoff = const Duration(minutes: 10),
    this.onLog,
  })  : _discovery = discovery,
        _connections = connections,
        _registry = registry,
        _clock = clock,
        _targetConnections = targetConnections,
        _initialBackoff = initialBackoff,
        _maxBackoff = maxBackoff,
        _longBackoff = longBackoff;

  // ... fields ...

  ConnectionMode _mode = ConnectionMode.manual;
  StreamSubscription<ScanCandidate>? _sub;
  final Map<BleAddress, ({Duration delay, DateTime nextAttempt})>
      _backoff = {};
  final Set<BleAddress> _knownAddressesAsNotBluey = {};
  final Map<BleAddress, NodeId> _knownAddressToNode = {};

  ConnectionMode get mode => _mode;

  void setMode(ConnectionMode m) {
    if (m == _mode) return;
    _mode = m;
    if (_mode == ConnectionMode.auto) {
      _subscribe();
      // Catch up: try every currently-emitted candidate immediately.
      for (final c in _discovery.currentCandidates) {
        unawaited(_tryConnect(c));
      }
    } else {
      _unsubscribe();
    }
  }

  void _subscribe() {
    _sub ??= _discovery.candidates.listen(_tryConnect);
  }
  void _unsubscribe() {
    final s = _sub;
    _sub = null;
    s?.cancel();
  }

  Future<void> _tryConnect(ScanCandidate c) async {
    if (_mode != ConnectionMode.auto) return;
    // Dedup: if we already know this address's NodeId and it's still in the
    // registry, skip.
    final knownNode = _knownAddressToNode[c.address];
    if (knownNode != null && _registry.contains(knownNode)) return;
    // Backoff gate
    final entry = _backoff[c.address];
    if (entry != null && _clock.now().isBefore(entry.nextAttempt)) return;
    // Target-connections cap
    if (_targetConnections != null &&
        _registry.connectionCount >= _targetConnections!) {
      return;
    }
    try {
      final nodeId = await _connections.connectTo(c);
      _knownAddressToNode[c.address] = nodeId;
      _backoff.remove(c.address);
    } on NotABlueyPeerException {
      _backoff[c.address] = (delay: _longBackoff, nextAttempt: _clock.now().add(_longBackoff));
    } catch (e, st) {
      onLog?.call(LogLevel.warning, 'auto-connect failed for ${c.address}', e, st);
      final prev = _backoff[c.address]?.delay ?? Duration.zero;
      final next = prev == Duration.zero
          ? _initialBackoff
          : Duration(
              milliseconds: (prev.inMilliseconds * 2).clamp(
                _initialBackoff.inMilliseconds,
                _maxBackoff.inMilliseconds,
              ),
            );
      _backoff[c.address] = (delay: next, nextAttempt: _clock.now().add(next));
    }
  }

  Future<void> dispose() async => _unsubscribe();
}
```

The backoff / dedup state previously inside `ConnectionService` now lives here. `ConnectionManager` is unaware of policy.

- [ ] **Step 3: Run tests; commit**

```bash
cd packages/gossip_bluey && flutter test
git add packages/gossip_bluey/lib/src/application/services/auto_connect_policy.dart \
        packages/gossip_bluey/test/application/services/auto_connect_policy_test.dart
git commit -m "feat(gossip_bluey): add AutoConnectPolicy — toggleable auto-connect with backoff, dedup, target-connections cap"
```

### Task C5: Wire everything together on `BlueyTransport`

**Files:**
- Modify: `packages/gossip_bluey/lib/src/facade/bluey_transport.dart`
- Create: `packages/gossip_bluey/test/facade/bluey_transport_candidates_test.dart`

- [ ] **Step 1: Update the facade constructor / `create()` factory**

```dart
factory BlueyTransport.create({ ... }) async {
  // ... existing setup ...
  final discovery = DiscoveryService(port: port, serviceUuid: serviceUuid);
  final connections = ConnectionManager(
    port: port,
    registry: registry,
    // ...
  );
  final autoConnect = AutoConnectPolicy(
    discovery: discovery,
    connections: connections,
    registry: registry,
    clock: clock,
    targetConnections: targetConnections,
  );
  return BlueyTransport._(
    discovery: discovery,
    connections: connections,
    autoConnect: autoConnect,
    // ...
  );
}
```

- [ ] **Step 2: Add the facade API**

```dart
// Candidates view
Stream<List<ScanCandidate>> get candidates => _discovery.snapshots;
Stream<ScanCandidate> get candidateEvents => _discovery.candidates;
List<ScanCandidate> get currentCandidates => _discovery.currentCandidates;

// Connection actions
Future<NodeId> connectTo(ScanCandidate candidate) =>
    _connections.connectTo(candidate);
Future<void> disconnect(NodeId nodeId) => _port.disconnect(nodeId);

// Mode
ConnectionMode get connectionMode => _autoConnect.mode;
void setConnectionMode(ConnectionMode mode) =>
    _autoConnect.setMode(mode);

// Independent discovery / advertising controls
Future<void> startDiscovery() => _discovery.start();
Future<void> stopDiscovery() => _discovery.stop();
// startAdvertising/stopAdvertising already exist on the port; surface
// them unchanged.
```

- [ ] **Step 3: Default to `ConnectionMode.manual` at construction**

`AutoConnectPolicy` already defaults to manual; assert this in a test:

```dart
test('BlueyTransport defaults to ConnectionMode.manual', () { ... });
```

- [ ] **Step 4: Run all gossip_bluey tests; commit**

```bash
cd packages/gossip_bluey && flutter test
git add -A packages/gossip_bluey
git commit -m "feat(gossip_bluey): wire DiscoveryService + ConnectionManager + AutoConnectPolicy through BlueyTransport facade"
```

---

## Phase D — gossip_chat: presentation model

### Task D1: `BleHealth` value object

**Files:**
- Create: `examples/gossip_chat/lib/presentation/view_models/ble_health.dart`
- Create: `examples/gossip_chat/test/presentation/view_models/ble_health_test.dart`

- [ ] **Step 1: Test bucket boundaries**

```dart
group('BleHealth.fromRssi', () {
  test('null rssi -> unknown', () => expect(BleHealth.fromRssi(null), BleHealth.unknown));
  test('-50 -> excellent', () => expect(BleHealth.fromRssi(-50), BleHealth.excellent));
  test('-60 -> excellent (boundary)', () => expect(BleHealth.fromRssi(-60), BleHealth.excellent));
  test('-61 -> good', () => expect(BleHealth.fromRssi(-61), BleHealth.good));
  test('-75 -> good (boundary)', () => expect(BleHealth.fromRssi(-75), BleHealth.good));
  test('-76 -> fair', () => expect(BleHealth.fromRssi(-76), BleHealth.fair));
  test('-85 -> fair (boundary)', () => expect(BleHealth.fromRssi(-85), BleHealth.fair));
  test('-86 -> poor', () => expect(BleHealth.fromRssi(-86), BleHealth.poor));
  test('-120 -> poor', () => expect(BleHealth.fromRssi(-120), BleHealth.poor));
});
```

- [ ] **Step 2: Implement**

```dart
// examples/gossip_chat/lib/presentation/view_models/ble_health.dart
enum BleHealth {
  excellent, // RSSI >= -60
  good,      // -75 <= RSSI < -60
  fair,      // -85 <= RSSI < -75
  poor,      // RSSI < -85
  unknown;   // RSSI null (no recent scan emission)

  static BleHealth fromRssi(int? rssi) {
    if (rssi == null) return BleHealth.unknown;
    if (rssi >= -60) return BleHealth.excellent;
    if (rssi >= -75) return BleHealth.good;
    if (rssi >= -85) return BleHealth.fair;
    return BleHealth.poor;
  }
}
```

- [ ] **Step 3: Commit**

```bash
git add examples/gossip_chat/lib/presentation/view_models/ble_health.dart \
        examples/gossip_chat/test/presentation/view_models/ble_health_test.dart
git commit -m "feat(gossip_chat): add BleHealth value object — RSSI-derived signal bucket"
```

### Task D2: `DiscoveredPeer` view model

**Files:**
- Create: `examples/gossip_chat/lib/presentation/view_models/discovered_peer.dart`
- Create: `examples/gossip_chat/test/presentation/view_models/discovered_peer_test.dart`

- [ ] **Step 1: Define the model**

```dart
// examples/gossip_chat/lib/presentation/view_models/discovered_peer.dart

enum DiscoveredPeerStatus {
  /// Scanner has seen this address; no connection has been attempted.
  discovered,
  /// `connectTo` is in flight.
  connecting,
  /// Connected (registry says so); SWIM says reachable.
  connected,
  /// Connected, SWIM probes are failing.
  suspected,
  /// Connected, SWIM probes are sustained-failing.
  unreachable,
  /// Local-side disconnect in flight.
  disconnecting,
  /// Most recent attempt failed.
  failed,
}

@immutable
class DiscoveredPeer {
  final BleAddress address;
  final NodeId? nodeId;
  final String? displayName;
  final int? rssi;
  final DateTime lastSeenAt;
  final DiscoveredPeerStatus status;

  /// Whether this peer has ever entered the connection registry during
  /// this session. Used by the prune-on-stop rule to decide whether to
  /// retain after discovery stops.
  final bool everConnected;

  const DiscoveredPeer({
    required this.address,
    required this.lastSeenAt,
    required this.status,
    this.nodeId,
    this.displayName,
    this.rssi,
    this.everConnected = false,
  });

  DiscoveredPeer copyWith({ ... });

  // Equality on all fields.
}
```

- [ ] **Step 2: Tests for equality, copyWith, value-object semantics**

- [ ] **Step 3: Commit**

### Task D3: Extend `PeerConnectionStatus` and `ConnectionStatus`

**Files:**
- Modify: `examples/gossip_chat/lib/presentation/view_models/view_models.dart` (or wherever `PeerConnectionStatus` lives)
- Modify: `examples/gossip_chat/lib/presentation/controllers/chat_controller.dart`

- [ ] **Step 1: Extend `PeerConnectionStatus`**

This enum currently has `connected`, `suspected`, `unreachable`. The new values are subsumed by `DiscoveredPeerStatus` above; in the controller, **delete `PeerConnectionStatus`** and use `DiscoveredPeerStatus` as the single source of truth for peer row status. Keep gossip's `PeerStatus` (in the gossip package) as the input that maps into `DiscoveredPeerStatus.connected / suspected / unreachable`.

- [ ] **Step 2: Extend `ConnectionStatus`**

```dart
enum ConnectionStatus {
  bluetoothOff,
  disconnected,

  // Transient advertising / scanning
  advertisingStarting,
  advertising,
  advertisingStopping,
  discoveryStarting,
  discovering,
  discoveryStopping,

  // Composed (both up)
  meshActive,

  // Terminal recovery state
  invalidated,

  connected,
}
```

Compose in `_updateConnectionStatus()`:

```dart
void _updateConnectionStatus() {
  final old = _connectionStatus;
  if (_bluetoothState != BluetoothAdapterState.on) {
    _connectionStatus = ConnectionStatus.bluetoothOff;
  } else if (_advertisingState == bluey.AdvertisingState.invalidated
      || _scanState == bluey.ScanState.invalidated) {
    _connectionStatus = ConnectionStatus.invalidated;
  } else if (_connectionService.connectedPeerCount > 0) {
    _connectionStatus = ConnectionStatus.connected;
  } else {
    // Compose advertising × scanning
    final adv = _advertisingState;
    final scan = _scanState;
    if (adv == bluey.AdvertisingState.advertising
        && scan == bluey.ScanState.scanning) {
      _connectionStatus = ConnectionStatus.meshActive;
    } else if (adv == bluey.AdvertisingState.starting) {
      _connectionStatus = ConnectionStatus.advertisingStarting;
    } else if (adv == bluey.AdvertisingState.advertising) {
      _connectionStatus = ConnectionStatus.advertising;
    } else if (adv == bluey.AdvertisingState.stopping) {
      _connectionStatus = ConnectionStatus.advertisingStopping;
    } else if (scan == bluey.ScanState.starting) {
      _connectionStatus = ConnectionStatus.discoveryStarting;
    } else if (scan == bluey.ScanState.scanning) {
      _connectionStatus = ConnectionStatus.discovering;
    } else if (scan == bluey.ScanState.stopping) {
      _connectionStatus = ConnectionStatus.discoveryStopping;
    } else {
      _connectionStatus = ConnectionStatus.disconnected;
    }
  }
  if (old != _connectionStatus) notifyListeners();
}
```

- [ ] **Step 3: Tests for every transition**

- [ ] **Step 4: Commit**

### Task D4: ChatController merge step + manual API

**Files:**
- Modify: `examples/gossip_chat/lib/presentation/controllers/chat_controller.dart`
- Create: `examples/gossip_chat/test/presentation/controllers/chat_controller_merge_test.dart`

- [ ] **Step 1: Replace `peers : List<PeerState>` with a merged map**

```dart
final Map<dynamic /* NodeId | BleAddress */, DiscoveredPeer> _peers = {};
List<DiscoveredPeer> get peers => List.unmodifiable(_peers.values);
ConnectionMode get mode => _connectionService.connectionMode;
```

- [ ] **Step 2: Subscribe candidate stream**

```dart
_candidatesSub = _connectionService.candidateEvents.listen((c) {
  final byAddr = _peers[c.address];
  final byNode = _peers.values.firstWhereOrNull(
    (p) => p.address == c.address && p.nodeId != null,
  );
  // If we already know this candidate as a connected peer (keyed by NodeId),
  // just update rssi/lastSeen.
  if (byNode != null) {
    _peers[byNode.nodeId!] = byNode.copyWith(
      rssi: c.rssi, lastSeenAt: c.lastSeen,
      displayName: c.displayName ?? byNode.displayName,
    );
    notifyListeners();
    return;
  }
  // Otherwise upsert keyed by BleAddress as a discovered/connecting peer.
  _peers[c.address] = (byAddr ?? DiscoveredPeer(
    address: c.address,
    lastSeenAt: c.lastSeen,
    status: DiscoveredPeerStatus.discovered,
  )).copyWith(
    rssi: c.rssi, lastSeenAt: c.lastSeen,
    displayName: c.displayName ?? byAddr?.displayName,
  );
  notifyListeners();
});
```

- [ ] **Step 3: Subscribe transport peerEvents (PeerOpened/PeerClosed/...)**

On `PeerOpened`: find the entry keyed by BleAddress (if present), rekey by NodeId, set `status: connected`, `everConnected: true`.

On `PeerClosed`: keep the entry but set `status: disconnecting` initially, then `disconnected` once event propagates. Apply prune rule below.

- [ ] **Step 4: Subscribe gossip peer-status updates**

These already flow today via the existing `PeerStatus` plumbing. Map gossip `PeerStatus.reachable/suspected/unreachable` onto `DiscoveredPeerStatus.connected/suspected/unreachable` for peers in the connection registry.

- [ ] **Step 5: Prune-on-stop rule**

```dart
_scanStateSub = _connectionService.scanStateStream.listen((state) {
  _scanState = state;
  _updateConnectionStatus();
  if (state != bluey.ScanState.scanning) {
    _peers.removeWhere(
      (key, peer) => !peer.everConnected,
    );
    notifyListeners();
  }
});
```

- [ ] **Step 6: Manual-mode actions**

```dart
Future<void> tapPeer(DiscoveredPeer peer) async {
  switch (peer.status) {
    case DiscoveredPeerStatus.discovered:
    case DiscoveredPeerStatus.failed:
      // Move to connecting; let connectTo's resolution drive the next transition.
      _peers[peer.address] = peer.copyWith(status: DiscoveredPeerStatus.connecting);
      notifyListeners();
      try {
        await _connectionService.connectTo(/* construct ScanCandidate from peer */);
        // Success -> PeerOpened handler flips status to connected + everConnected.
      } catch (_) {
        _peers[peer.address] = peer.copyWith(status: DiscoveredPeerStatus.failed);
        notifyListeners();
      }
      return;
    case DiscoveredPeerStatus.connected:
    case DiscoveredPeerStatus.suspected:
      // Caller's responsibility to show an action sheet → disconnect.
      return;
    default:
      return; // already in transient state; ignore taps.
  }
}

void setMode(ConnectionMode mode) {
  _connectionService.setConnectionMode(mode);
  notifyListeners();
}

Future<void> setAdvertising(bool on) async {
  if (on) {
    await _connectionService.startAdvertising();
  } else {
    await _connectionService.stopAdvertising();
  }
}

Future<void> setDiscovering(bool on) async {
  if (on) {
    await _connectionService.startDiscovery();
  } else {
    await _connectionService.stopDiscovery();
  }
}
```

- [ ] **Step 7: Tests for the merge step (especially address↔NodeId rekey path)**

- [ ] **Step 8: Commit**

### Task D5: Reconciliation: ensure `tapPeer` actually finds the `ScanCandidate`

The merge step keeps `DiscoveredPeer` rows; `connectTo` requires a fresh `ScanCandidate`. Decide: either keep the most-recent `ScanCandidate` per address in the controller alongside `_peers`, or add an `BlueyTransport.connectByAddress(BleAddress)` shortcut that looks up the candidate in `DiscoveryService.currentCandidates`.

Recommended: latter. Add `BlueyTransport.connectByAddress(BleAddress)` that does `final c = _discovery.currentCandidates.firstWhere((c) => c.address == addr, orElse: ...); return _connections.connectTo(c);`. Simpler controller, single source of truth.

- [ ] **Step 1–4: Test + implement + integrate; commit**

---

## Phase E — gossip_chat: peers screen rebuild

### Task E1: Peer-row widgets

**Files:**
- Create: `examples/gossip_chat/lib/presentation/widgets/peer_status_pill.dart`
- Create: `examples/gossip_chat/lib/presentation/widgets/ble_signal_indicator.dart`

- [ ] **Step 1: `PeerStatusPill`** — small rounded-corner badge mapping `DiscoveredPeerStatus` → label + color. Spinner for `connecting` / `disconnecting`.

- [ ] **Step 2: `BleSignalIndicator`** — 3-bar icon driven by `BleHealth`. Greyed when `unknown` (no recent RSSI).

- [ ] **Step 3: Widget tests for both**

- [ ] **Step 4: Commit**

### Task E2: `TopologyControls`

**Files:**
- Create: `examples/gossip_chat/lib/presentation/widgets/topology_controls.dart`

- [ ] **Step 1: Widget contract**

```dart
class TopologyControls extends StatelessWidget {
  final bluey.AdvertisingState advertisingState;
  final bluey.ScanState scanState;
  final ConnectionMode mode;
  final VoidCallback onToggleAdvertise;
  final VoidCallback onToggleDiscover;
  final ValueChanged<ConnectionMode> onModeChanged;
  // ...
}
```

Layout: row 1 = Mesh / Manual segmented control. Row 2 = `Advertise` chip + `Discover` chip. Each chip:
- `idle` / `stopped`: outlined chip, primary color border, "Advertise" / "Discover" label.
- `starting`: filled chip, spinner glyph, "Starting…" label, taps disabled.
- `advertising` / `scanning`: filled chip with primary color, check glyph, "Advertising" / "Discovering" label.
- `stopping`: filled chip with spinner, "Stopping…" label, taps disabled.
- `invalidated`: error-tinted chip, warning glyph, "Reset" label; tap = call stop + start to recover.

- [ ] **Step 2: Widget tests for each state**

- [ ] **Step 3: Commit**

### Task E3: Rebuild `peers_screen.dart`

**Files:**
- Modify: `examples/gossip_chat/lib/presentation/screens/peers_screen.dart`

- [ ] **Step 1: New layout**

```dart
class PeersScreen extends StatelessWidget {
  // ...
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Nearby Peers'),
            actions: [
              IconButton(
                icon: const Icon(Icons.settings),
                onPressed: () => _openSettings(context),
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(child: _buildList()),
              TopologyControls(
                advertisingState: controller.advertisingState,
                scanState: controller.scanState,
                mode: controller.mode,
                onToggleAdvertise: () => controller.setAdvertising(
                  controller.advertisingState != bluey.AdvertisingState.advertising,
                ),
                onToggleDiscover: () => controller.setDiscovering(
                  controller.scanState != bluey.ScanState.scanning,
                ),
                onModeChanged: controller.setMode,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildList() {
    if (controller.peers.isEmpty && controller.indirectPeers.isEmpty) {
      return _buildEmptyState();
    }
    return ListView(
      children: [
        if (controller.peers.isNotEmpty) ...[
          const _SectionHeader(title: 'Nearby'),
          ...controller.peers.map((p) => _DiscoveredPeerTile(
            peer: p,
            scanningActive:
                controller.scanState == bluey.ScanState.scanning,
            onTap: () => _onPeerTap(context, p),
          )),
        ],
        if (controller.indirectPeers.isNotEmpty) ...[
          const _SectionHeader(title: 'Via Gossip'),
          ...controller.indirectPeers.map(
            (p) => _IndirectPeerTile(peer: p),
          ),
        ],
      ],
    );
  }
}
```

- [ ] **Step 2: `_DiscoveredPeerTile`**

```dart
class _DiscoveredPeerTile extends StatelessWidget {
  // ...
  @override
  Widget build(BuildContext context) {
    final gossipHealth =
        controller.signalStrengthFor(peer.nodeId); // existing manager output
    return ListTile(
      leading: NodeAvatar(
        identifier: peer.address.value,
        displayText: peer.displayName,
        radius: 20,
      ),
      title: Text(peer.displayName ?? peer.address.value),
      subtitle: PeerStatusPill(status: peer.status),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          BleSignalIndicator(
            health: scanningActive
              ? BleHealth.fromRssi(peer.rssi)
              : BleHealth.unknown,
            scanningActive: scanningActive,
          ),
          const SizedBox(width: 8),
          GossipHealthDot(health: gossipHealth),
        ],
      ),
      onTap: onTap,
    );
  }
}
```

- [ ] **Step 3: `_onPeerTap` action**

```dart
Future<void> _onPeerTap(BuildContext context, DiscoveredPeer p) async {
  switch (p.status) {
    case DiscoveredPeerStatus.discovered:
    case DiscoveredPeerStatus.failed:
      await controller.tapPeer(p);
    case DiscoveredPeerStatus.connected:
    case DiscoveredPeerStatus.suspected:
    case DiscoveredPeerStatus.unreachable:
      _showConnectedActionSheet(context, p);
    default:
      // Transient — no-op.
      return;
  }
}
```

- [ ] **Step 4: Widget tests**

Mock controller; assert each row renders the expected pill + indicators for each status; assert tap dispatch.

- [ ] **Step 5: Commit**

---

## Phase F — gossip_chat: settings sheet (gossip rate)

### Task F1: `GossipConfigService`

**Files:**
- Create: `examples/gossip_chat/lib/application/services/gossip_config_service.dart`
- Create: `examples/gossip_chat/test/application/services/gossip_config_service_test.dart`

- [ ] **Step 1: Implement**

```dart
class GossipConfigService extends ChangeNotifier {
  GossipConfigService();

  Duration? _gossipInterval; // null = adaptive
  Duration? _probeInterval;  // null = adaptive

  Duration? get gossipInterval => _gossipInterval;
  Duration? get probeInterval => _probeInterval;

  void setGossipInterval(Duration? d) {
    if (_gossipInterval == d) return;
    _gossipInterval = d;
    notifyListeners();
  }

  void setProbeInterval(Duration? d) {
    if (_probeInterval == d) return;
    _probeInterval = d;
    notifyListeners();
  }

  CoordinatorConfig buildCoordinatorConfig() => CoordinatorConfig(
    gossipInterval: _gossipInterval,
    probeInterval: _probeInterval,
  );
}
```

- [ ] **Step 2: Plumb into `Coordinator.create` at app startup**

Modify the app's Coordinator construction site (probably `main.dart` or `app.dart`) to pull the config from the service instance.

- [ ] **Step 3: Commit**

### Task F2: Settings sheet UI

**Files:**
- Create: `examples/gossip_chat/lib/presentation/screens/settings_sheet.dart`

- [ ] **Step 1: Layout**

Two slider sections, each with:
- A row showing current value (e.g. "250 ms" or "Adaptive")
- A slider (100ms-5000ms in 50ms steps)
- A "reset to adaptive" button that sets the value to null

Bottom note: "Changes take effect on next Start Networking."

- [ ] **Step 2: Wiring**

`onChanged` calls `GossipConfigService.setGossipInterval` / `setProbeInterval`. The service is `Provider`-injected (or whatever DI the app uses).

- [ ] **Step 3: Widget tests**

- [ ] **Step 4: Commit**

### Task F3: Apply-on-restart UX

- [ ] **Step 1: Show a "Restart networking to apply" snackbar when settings change while connected**

In the settings sheet, observe the controller's `connectionStatus`. If the user changes a setting while `connected`/`advertising`/`discovering`, surface the hint.

- [ ] **Step 2: Make `ChatController.startNetworking` re-read the GossipConfigService each time**

Already a natural consequence of how the service builds the `CoordinatorConfig` lazily, but verify with a test.

- [ ] **Step 3: Commit**

---

## Final verification

- [ ] **Step 1: Repo-wide grep for dead references**

```bash
grep -rn "isAdvertising\|isDiscovering\|ConnectionService\b\|PeerConnectionStatus" \
  packages/ examples/ \
  | grep -v "^Binary"
```

Expect: zero hits in `packages/gossip_bluey/lib`, `packages/gossip_bluey/test`, `examples/gossip_chat`. (`bluey` package not in scope.)

- [ ] **Step 2: Run melos analyze + test**

```bash
melos run analyze
melos run test
```

- [ ] **Step 3: Manual smoke test in a simulator**

- Open peers screen — empty state.
- Toggle Discover on — see peers appear with RSSI bars + "Discovered" pill.
- Toggle Discover off — non-connected peers vanish.
- Toggle Discover on, tap a peer — pill becomes "Connecting…", then "Connected"; status bar shows "1 peer connected."
- Switch mode to Mesh — observe auto-connect attempts for any other discovered candidates.
- Open Settings, lower gossip interval to 200ms — see "Restart networking to apply" hint.
- Toggle Stop Networking, then Start — settings now active.

- [ ] **Step 4: Final commit + push**

```bash
git status
git log --oneline -20
```

Push the branch and open a PR titled "Peers screen redesign: unified discovery + manual/auto modes + gossip rate config."

---

## Risks / things to revisit

- **`Stream.multi` replay-on-subscribe is non-trivial to implement correctly.** The pattern is in bluey's `advertisingStateChanges` (`bluey/lib/src/gatt_server/bluey_server.dart`). Copy that shape for `DiscoveryService.snapshots`. Don't take a `rxdart` dependency just for this.
- **`tapPeer` race conditions.** If the user taps the same row twice quickly, today's draft would attempt two connects in parallel. `ConnectionManager.connectTo` guards via `_connectingAddresses`, but the second tap will throw `StateError`. Acceptable for v1 but worth making the second tap idempotent in a follow-up.
- **Settings + I343 interaction.** As noted in plan body — a user lowering `gossipInterval` to 100ms while running against the I343 bisect branch will dramatically increase the rate of multi-chunk WriteNoResponse → corruption. Either land I343 first, or surface a "be careful" note in the settings UI.
- **Test for `everConnected` semantics.** The prune-on-stop rule's correctness hinges on `everConnected` being set exactly at `PeerOpened` time and never cleared. Add an explicit test that a peer that connected → disconnected → discovery stopped remains in the list with `unreachable` status (not pruned).
- **Indirect-peer rendering** unchanged in spirit but the file structure shifts. Verify `_IndirectPeerTile` keeps building cleanly after the view-model split.
