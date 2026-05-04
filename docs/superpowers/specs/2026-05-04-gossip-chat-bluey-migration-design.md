# gossip_chat example: migrate from gossip_nearby to gossip_bluey

**Status:** Design
**Date:** 2026-05-04

## Summary

Migrate `examples/gossip_chat` from `gossip_nearby` to `gossip_bluey`. The app's value proposition shifts from "Android-only Nearby Connections demo" to "cross-platform BLE chat demo" — the same UI and gossip-level behavior, on a different transport, running on both Android and iOS. The `gossip_nearby` *package* itself stays in the repo for users who want it.

## Goals

- Single, working chat demo on top of `gossip_bluey` — Android + iOS.
- Preserve every UI/UX feature of the existing app: peers screen, channels, messages, signal strength, metrics, debug logger, indirect peers, typing indicators.
- Land as a series of small, scannable commits on a fresh branch off `main`.

## Non-goals

- Removing or modifying the `gossip_nearby` package.
- Real-device CI for the example app.
- New transport-specific UI affordances (topology toggle, hub/spoke mode picker).
- Cleanup of pre-existing analyzer warnings in `gossip_nearby`.

## Branch and commit shape

- Branch: `feat/gossip-chat-bluey` off `main`.
- Roughly five commits:
  1. **Add gossip_bluey dependency** — `pubspec.yaml` swap (drop `gossip_nearby` + `nearby_connections`, add `gossip_bluey` + `bluey`).
  2. **Migrate transport wiring** — `main.dart` and `connection_service.dart` (the wrapper).
  3. **Update debug logger** — rename `nearby*` symbols to `bluey*`, change log prefixes.
  4. **Update permissions** — drop Wi-Fi-Direct entries from manifest and `permission_service.dart`; rename methods.
  5. **Drop platform leftovers** — minor manifest comment cleanup, optional Info.plist text tweak, pubspec description.

Each commit should leave the example app compiling and (in principle) runnable. Running on a real device after each commit is not required, but `flutter analyze` must stay clean.

## Service UUID

The example uses a single hardcoded 128-bit UUID:

```dart
// gossip service UUID for the chat demo. Pick your own UUID for your
// app — collisions across unrelated apps would have all instances visible
// to each other at the BLE layer.
static final _serviceUuid = ServiceUuid('f0000000-0000-0000-0000-67c155b1ea7c');
```

The trailing 8 hex bytes are arbitrary but stable across the app's installs, so all phones running the demo find each other.

## File-by-file changes

### `examples/gossip_chat/pubspec.yaml`
Drop `gossip_nearby` (path) and `nearby_connections: ^4.0.0`. Add `gossip_bluey` (path: `../../packages/gossip_bluey`) and `bluey` (git from `https://github.com/neutrinographics/bluey.git`, path: `bluey`). Update `description` to "Demo app for gossip and gossip_bluey packages".

### `examples/gossip_chat/lib/main.dart`
- Replace `import 'package:gossip_nearby/gossip_nearby.dart'` with `package:gossip_bluey/gossip_bluey.dart`.
- Replace the `NearbyTransport.create(serviceId: ServiceId('gossipchat'), ...)` block with `BlueyTransport.create(serviceUuid: _serviceUuid, ...)`. Keep `localNodeRepository`, `displayName`, and `onLog` parameters as-is.
- Add the `_serviceUuid` constant near the top of the file with the explanatory comment.
- Logging-callback parameter: `onLog: blueyLogCallback` (renamed from `nearbyLogCallback`).
- Logging level: `blueyMinLogLevel = _verboseLogging ? LogLevel.trace : LogLevel.warning;`
- The `Coordinator.create` block, all subsequent service constructions, and the `runApp` call stay byte-identical.

### `examples/gossip_chat/lib/application/services/connection_service.dart`
Pure rename:
- Import: `package:gossip_nearby/gossip_nearby.dart` → `package:gossip_bluey/gossip_bluey.dart`.
- Field/parameter type: `NearbyTransport` → `BlueyTransport`.
- Metrics getter return type: `NearbyMetrics get metrics` → `BlueyMetrics get metrics`.
- Class doc: "bridges the NearbyTransport ..." → "bridges the BlueyTransport ...".
- Method docs that say "Starts advertising this device to nearby peers" / "Starts discovering nearby peers" — leave the natural-English meaning of "nearby" untouched (it's not a brand reference).

The class's logic is unchanged; the public surface of `BlueyTransport` is a superset of what this wrapper consumes (`peerEvents`, `errors`, `metrics`, `start/stopAdvertising/Discovery`, `disconnectAll`, `isAdvertising`, `isDiscovering`, `connectedPeerCount`).

### `examples/gossip_chat/lib/application/observability/debug_logger.dart`
- Import swap.
- Rename `nearbyMinLogLevel` → `blueyMinLogLevel` (the global `LogLevel` variable).
- Rename `nearbyLogCallback` → `blueyLogCallback`.
- Inside `blueyLogCallback`: log-line category prefix `'NEARBY][...'` → `'BLUEY][...'`; `developer.log` name `'gossip.nearby.${level.name}'` → `'gossip.bluey.${level.name}'`.
- Class doc: "logging metrics, events, and errors from gossip and gossip_nearby" → "from gossip and gossip_bluey".

### `examples/gossip_chat/lib/presentation/controllers/chat_controller.dart`
Single-line import swap. The types it consumes (`PeerEvent`, `PeerConnected`, `PeerDisconnected`) are exported under the same names from gossip_bluey.

### `examples/gossip_chat/lib/infrastructure/services/permission_service.dart`
- Rename `requestNearbyPermissions` → `requestBluetoothPermissions`.
- Rename `hasNearbyPermissions` → `hasBluetoothPermissions`.
- Drop `Permission.nearbyWifiDevices` from the Android list (BLE doesn't need Wi-Fi-Direct).
- Drop the corresponding status check in `hasBluetoothPermissions`.
- Update class doc: "for Nearby Connections" → "for Bluetooth Low Energy".
- Callsites in `chat_controller.dart` updated to the renamed methods.

### `examples/gossip_chat/lib/application/services/metrics_service.dart` and `lib/application/services/sync_service.dart`
**No changes required.** They read `transport.metrics.totalBytesSent` / `totalBytesReceived` and per-peer counts via `_syncService.getPeerMetrics`. Both fields exist on `BlueyMetrics` with identical semantics.

### `examples/gossip_chat/android/app/src/main/AndroidManifest.xml`
- Replace the comment `"Nearby Connections permissions"` with `"Bluetooth LE permissions"`.
- Drop `<uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />`.
- Drop `<uses-permission android:name="android.permission.CHANGE_WIFI_STATE" />`.
- Drop `<uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" .../>`.
- Keep all `BLUETOOTH*` entries and both `ACCESS_*_LOCATION` (the latter still needed on pre-Android-12 BLE scanning).

### `examples/gossip_chat/ios/Runner/Info.plist`
- `NSBluetoothAlwaysUsageDescription` and `NSBluetoothPeripheralUsageDescription` are already present. Optionally tighten the description text from "discover and connect with nearby devices" to "discover and connect with nearby devices over Bluetooth Low Energy". Cosmetic.

## Permission and Bluetooth-state flow at startup

The current app calls `_permissionService.requestNearbyPermissions()` before `transport.startAdvertising()`. The migration keeps that pattern (renamed) and adds one explicit Bluetooth-state check:

```dart
// In ChatController.startNetworking, after permission grant:
final granted = await _permissionService.requestBluetoothPermissions();
if (!granted) { ... }

// Verify BT is on / supported / authorized at the OS layer.
try {
  await Bluey.shared.ensureReady();
} on BluetoothDisabledException {
  // Surface to UI: "Please enable Bluetooth"
} on PermissionDeniedException {
  // Surface to UI: "Bluetooth permission denied"
} on BluetoothUnavailableException {
  // Surface to UI: "Bluetooth not supported"
}

await _connectionService.startAdvertising();
await _connectionService.startDiscovery();
```

Note the use of `Bluey.shared` (not the transport's internal Bluey instance). `ensureReady()` checks platform state — it doesn't need the per-instance local identity. This avoids growing `BlueyTransport`'s API surface to expose its inner Bluey instance.

`Bluey.shared` is safe to call from the app even though `BlueyPortImpl` constructs its own instance — they coexist; the platform layer is shared. Document this in a comment.

## Risks and what to watch for during first-device runs

- **Dual roles on real chips.** The app advertises and discovers simultaneously. Some Android chipsets misbehave under that load — symptoms include scan results dropping, advertising silently failing, or burst-y connection failures. Watch `transport.errors` for a string of `ConnectFailedError`.
- **iOS GATT cache staleness.** Cold-launched peripherals may not surface their gossip service immediately to a central that already finished discovery. `BlueyPortImpl.connect` throws "gossip service missing" in that case. The transport's per-NodeId backoff retries automatically; visible on the metrics dashboard as elevated `totalConnectionsFailed`.
- **MTU negotiation timing.** `BlueyPortImpl` requests the platform-max MTU on central-role connect, but the negotiation is async and the first few writes after connect may use the BLE-default 20-byte chunk size before the request completes. Symptom: a brief slow window at the start of each new connection, then full throughput. Not a correctness issue.
- **iOS background.** Out of scope per gossip_bluey's spec — the example app discovery only works while the app is foregrounded.

## Verification

Before merging the migration branch:
- `cd examples/gossip_chat && flutter analyze` — clean.
- `cd examples/gossip_chat && flutter pub get` — succeeds, no missing platform plugins.
- `flutter build apk --debug` — succeeds.
- `flutter build ios --debug --no-codesign` — succeeds.
- Optional, real-device: install on two phones (one Android, one iOS), grant permissions, verify they discover each other, exchange a message.

## Out of scope (explicit)

- MTU negotiation work.
- Removing or modifying `gossip_nearby`.
- Real-device CI.
- New transport-specific UI in the chat app.
- gossip_nearby's pre-existing analyzer warnings.
