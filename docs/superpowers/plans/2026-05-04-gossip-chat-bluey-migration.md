# gossip_chat → gossip_bluey Migration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate `examples/gossip_chat` from `gossip_nearby` (Android-only Nearby Connections) to `gossip_bluey` (cross-platform BLE), preserving every existing UI/UX feature.

**Architecture:** The example app's structure stays. The `ConnectionService` wrapper, `DebugLogger`, and `PermissionService` are renamed/retyped to use bluey symbols. `main.dart` swaps the transport constructor and adds an explicit `Bluey.shared.ensureReady()` check between permission grant and `startAdvertising`. Manifests drop Wi-Fi-Direct entries. The `gossip_nearby` package itself stays in the repo.

**Tech Stack:** Dart 3.10+, Flutter, `gossip_bluey` (path), `bluey` (git), `permission_handler`. The branch is `feat/gossip-chat-bluey` off `main`.

**Spec:** `docs/superpowers/specs/2026-05-04-gossip-chat-bluey-migration-design.md` — read this before starting.

**Test runner:** `examples/gossip_chat` is a Flutter app — use `flutter test` and `flutter analyze` (not `dart test` / `dart analyze`).

**Verification gate after every commit:** `flutter analyze` must report `No issues found!` and `flutter pub get` must succeed.

---

## File structure (touched files only)

```
examples/gossip_chat/
  pubspec.yaml                                     # Task 1
  lib/main.dart                                    # Task 2
  lib/application/services/connection_service.dart # Task 3
  lib/application/observability/debug_logger.dart  # Task 4
  lib/presentation/controllers/chat_controller.dart # Task 5 (import) + Task 6 (permission/state)
  lib/infrastructure/services/permission_service.dart # Task 6
  android/app/src/main/AndroidManifest.xml         # Task 7
  ios/Runner/Info.plist                            # Task 7 (optional cosmetic)
```

No new files. Files deliberately unchanged: `chat_service.dart`, `sync_service.dart`, `metrics_service.dart`, `indirect_peer_service.dart`, all view-models and screens, the signal-strength manager.

The migration produces 5 commits (Tasks 1-7 below; Task 7 bundles platform manifests since they're tiny).

---

## Task 1: Swap pubspec dependencies

**Files:**
- Modify: `examples/gossip_chat/pubspec.yaml`

- [ ] **Step 1: Replace `gossip_nearby` and `nearby_connections` deps**

Open `examples/gossip_chat/pubspec.yaml`. Replace the description and dependency block. Current state:

```yaml
description: "Demo app for gossip and gossip_nearby packages"
```

…and inside `dependencies:`:

```yaml
  # Gossip packages (path dependencies)
  gossip:
    path: ../../packages/gossip
  gossip_nearby:
    path: ../../packages/gossip_nearby
```

…and lower:

```yaml
  # Nearby Connections
  nearby_connections: ^4.0.0
```

Change to:

```yaml
description: "Demo app for gossip and gossip_bluey packages"
```

…and:

```yaml
  # Gossip packages (path dependencies)
  gossip:
    path: ../../packages/gossip
  gossip_bluey:
    path: ../../packages/gossip_bluey
  bluey:
    git:
      url: https://github.com/neutrinographics/bluey.git
      path: bluey
```

Delete the `nearby_connections: ^4.0.0` line entirely (no replacement — gossip_bluey reaches bluey through its own pubspec).

- [ ] **Step 2: Run pub get**

Run from `examples/gossip_chat`:
```
flutter pub get
```
Expected: succeeds. The `bluey` git package may need to be re-fetched.

- [ ] **Step 3: Verify no stale imports break compilation**

Run:
```
flutter analyze
```
Expected: errors. The example imports `package:gossip_nearby/gossip_nearby.dart` in 4 files; those imports now fail. That's the trigger for Task 2.

(Don't fix them yet — they're addressed in Tasks 2-5.)

- [ ] **Step 4: Commit**

```bash
git add examples/gossip_chat/pubspec.yaml examples/gossip_chat/pubspec.lock
git commit -m "build(gossip_chat): swap gossip_nearby + nearby_connections for gossip_bluey + bluey"
```

(`pubspec.lock` may or may not be regenerated automatically. If it changed, include it. If not, just commit the yaml.)

---

## Task 2: Migrate `main.dart`

**Files:**
- Modify: `examples/gossip_chat/lib/main.dart`

- [ ] **Step 1: Replace import**

Change line 4 from:
```dart
import 'package:gossip_nearby/gossip_nearby.dart';
```
to:
```dart
import 'package:gossip_bluey/gossip_bluey.dart';
```

- [ ] **Step 2: Add the service UUID constant**

Just before the `void main() async {` line (around line 14, after the `late final DebugLogger debugLogger;` declaration), insert:

```dart
/// gossip service UUID for the chat demo. Pick your own UUID for your
/// app — collisions across unrelated apps would have all instances
/// visible to each other at the BLE layer. The trailing 8 hex bytes
/// are arbitrary; the prefix is fixed across all gossip_chat installs.
final _serviceUuid = ServiceUuid('f0000000-0000-0000-0000-67c155b1ea7c');
```

- [ ] **Step 3: Replace the transport creation block**

Find the existing block at lines 19-32:
```dart
  // Configure log levels
  nearbyMinLogLevel = _verboseLogging ? LogLevel.trace : LogLevel.warning;

  // Generate or load device identity
  final localNodeRepo = InMemoryLocalNodeRepository();
  final deviceName = await _getDeviceName();

  // Create NearbyTransport for Android Nearby Connections
  final transport = await NearbyTransport.create(
    localNodeRepository: localNodeRepo,
    serviceId: ServiceId('gossipchat'),
    displayName: deviceName,
    onLog: nearbyLogCallback,
  );
```

Replace with:
```dart
  // Configure log levels
  blueyMinLogLevel = _verboseLogging ? LogLevel.trace : LogLevel.warning;

  // Generate or load device identity
  final localNodeRepo = InMemoryLocalNodeRepository();
  final deviceName = await _getDeviceName();

  // Create BlueyTransport for cross-platform BLE.
  final transport = await BlueyTransport.create(
    localNodeRepository: localNodeRepo,
    serviceUuid: _serviceUuid,
    displayName: deviceName,
    onLog: blueyLogCallback,
  );
```

- [ ] **Step 4: Run analyze on main.dart**

```
flutter analyze lib/main.dart
```
Expected: still some errors because `nearbyMinLogLevel`/`nearbyLogCallback` are renamed in `debug_logger.dart` in Task 4, and `connection_service.dart` still references `NearbyTransport` (Task 3). That's fine — keep going.

- [ ] **Step 5: Commit**

```bash
git add examples/gossip_chat/lib/main.dart
git commit -m "feat(gossip_chat): swap NearbyTransport for BlueyTransport in main.dart"
```

---

## Task 3: Migrate `connection_service.dart` wrapper

**Files:**
- Modify: `examples/gossip_chat/lib/application/services/connection_service.dart`

This task is a pure type rename. The file's logic is unchanged.

- [ ] **Step 1: Replace import**

Line 4:
```dart
import 'package:gossip_nearby/gossip_nearby.dart';
```
becomes:
```dart
import 'package:gossip_bluey/gossip_bluey.dart';
```

- [ ] **Step 2: Rename type references**

In the same file, replace every occurrence of `NearbyTransport` with `BlueyTransport`. Specifically:

- Line 8 docstring: "bridges the NearbyTransport" → "bridges the BlueyTransport"
- Line 11 field: `final NearbyTransport _transport;` → `final BlueyTransport _transport;`
- Line 17 constructor parameter: `required NearbyTransport transport,` → `required BlueyTransport transport,`

Replace `NearbyMetrics` with `BlueyMetrics`:

- Line 76 getter return type: `NearbyMetrics get metrics => _transport.metrics;` → `BlueyMetrics get metrics => _transport.metrics;`

- [ ] **Step 3: Run analyze on this file**

```
flutter analyze lib/application/services/connection_service.dart
```
Expected: clean. The transport's public methods (`startAdvertising`, `stopAdvertising`, `startDiscovery`, `stopDiscovery`, `peerEvents`, `errors`, `metrics`, `disconnectAll`, `isAdvertising`, `isDiscovering`, `connectedPeerCount`) are exported under the same names from gossip_bluey, so no body changes are needed.

- [ ] **Step 4: Commit**

```bash
git add examples/gossip_chat/lib/application/services/connection_service.dart
git commit -m "feat(gossip_chat): rename NearbyTransport/NearbyMetrics to Bluey* in ConnectionService"
```

---

## Task 4: Migrate `debug_logger.dart`

**Files:**
- Modify: `examples/gossip_chat/lib/application/observability/debug_logger.dart`

- [ ] **Step 1: Replace import**

Line 8:
```dart
import 'package:gossip_nearby/gossip_nearby.dart';
```
becomes:
```dart
import 'package:gossip_bluey/gossip_bluey.dart';
```

- [ ] **Step 2: Update class doc**

Line 31:
```dart
/// Service for logging metrics, events, and errors from gossip and gossip_nearby.
```
becomes:
```dart
/// Service for logging metrics, events, and errors from gossip and gossip_bluey.
```

- [ ] **Step 3: Rename the global logger variable**

Line 659-662:
```dart
/// Minimum log level for [nearbyLogCallback].
///
/// Set this before starting the transport to control verbosity.
LogLevel nearbyMinLogLevel = LogLevel.info;
```
becomes:
```dart
/// Minimum log level for [blueyLogCallback].
///
/// Set this before starting the transport to control verbosity.
LogLevel blueyMinLogLevel = LogLevel.info;
```

- [ ] **Step 4: Rename the callback function and its body**

Lines 669-702 (the `nearbyLogCallback` definition). Replace the entire function with:

```dart
/// LogCallback implementation for BlueyTransport that prints to console.
///
/// Only logs messages at or above [blueyMinLogLevel].
void blueyLogCallback(
  LogLevel level,
  String message, [
  Object? error,
  StackTrace? stackTrace,
]) {
  if (level.index < blueyMinLogLevel.index) return;

  final levelStr = level.name.toUpperCase().padRight(7);
  final category = 'BLUEY][$levelStr';
  var fullMessage = message;

  if (error != null) {
    fullMessage += ' | Error: $error';
  }

  // Store in global buffer for export
  globalLogStorage?.append(category, fullMessage);

  // Print to console
  final logLine = LogFormat.logLine(category, fullMessage);
  // ignore: avoid_print
  print(logLine);

  developer.log(
    message,
    name: 'gossip.bluey.${level.name}',
    error: error,
    stackTrace: stackTrace,
  );
}
```

The only changes are: name `nearbyLogCallback` → `blueyLogCallback`, dartdoc reference `nearbyMinLogLevel` → `blueyMinLogLevel`, prefix `'NEARBY][...'` → `'BLUEY][...'`, developer-log name `'gossip.nearby.${level.name}'` → `'gossip.bluey.${level.name}'`, and class-doc `NearbyTransport` → `BlueyTransport`.

- [ ] **Step 5: Run analyze on this file**

```
flutter analyze lib/application/observability/debug_logger.dart
```
Expected: clean. (`main.dart` is also clean now since both `blueyMinLogLevel` and `blueyLogCallback` exist.)

- [ ] **Step 6: Commit**

```bash
git add examples/gossip_chat/lib/application/observability/debug_logger.dart
git commit -m "feat(gossip_chat): rename nearby* logger symbols to bluey* in DebugLogger"
```

---

## Task 5: Update `chat_controller.dart` import

**Files:**
- Modify: `examples/gossip_chat/lib/presentation/controllers/chat_controller.dart`

- [ ] **Step 1: Replace import**

Line 5:
```dart
import 'package:gossip_nearby/gossip_nearby.dart';
```
becomes:
```dart
import 'package:gossip_bluey/gossip_bluey.dart';
```

The types it consumes from this import (`PeerEvent`, `PeerConnected`, `PeerDisconnected`) are exported under the same names from gossip_bluey. No other changes in this task — `requestNearbyPermissions` rename happens in Task 6.

- [ ] **Step 2: Run analyze on this file**

```
flutter analyze lib/presentation/controllers/chat_controller.dart
```
Expected: one remaining error around line 562 — `_permissionService.requestNearbyPermissions()` will be renamed in Task 6. That's the only remaining issue.

- [ ] **Step 3: Commit**

```bash
git add examples/gossip_chat/lib/presentation/controllers/chat_controller.dart
git commit -m "feat(gossip_chat): import gossip_bluey for PeerEvent types in ChatController"
```

---

## Task 6: Migrate permissions and add Bluetooth-state check

**Files:**
- Modify: `examples/gossip_chat/lib/infrastructure/services/permission_service.dart`
- Modify: `examples/gossip_chat/lib/presentation/controllers/chat_controller.dart`
- Modify: `examples/gossip_chat/lib/main.dart` (add `bluey` import for `Bluey.shared`)

This task does three things at once because they're tightly coupled: the permission method rename, the call-site update, and the new `ensureReady()` check.

- [ ] **Step 1: Replace `permission_service.dart`**

Open `examples/gossip_chat/lib/infrastructure/services/permission_service.dart` and replace the entire file with:

```dart
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Service for handling runtime permissions for Bluetooth Low Energy.
class PermissionService {
  /// Requests all permissions needed for Bluetooth Low Energy.
  ///
  /// Returns true if all permissions are granted, false otherwise.
  Future<bool> requestBluetoothPermissions() async {
    // iOS and Android have different permission requirements
    // Note: On Android 12+ with BLUETOOTH_SCAN declared with neverForLocation,
    // location permission is not required for BLE scanning.
    final permissions = Platform.isIOS
        ? [Permission.bluetooth, Permission.locationWhenInUse]
        : [
            Permission.bluetoothAdvertise,
            Permission.bluetoothConnect,
            Permission.bluetoothScan,
          ];

    // Request all required permissions for BLE.
    final statuses = await permissions.request();

    // Log each permission status for debugging
    for (final entry in statuses.entries) {
      debugPrint('Permission ${entry.key}: ${entry.value}');
    }

    // Check if all permissions are granted
    final allGranted = statuses.values.every(
      (status) => status.isGranted || status.isLimited,
    );

    debugPrint('All permissions granted: $allGranted');
    return allGranted;
  }

  /// Checks if all necessary permissions are already granted.
  Future<bool> hasBluetoothPermissions() async {
    if (Platform.isIOS) {
      final bluetooth = await Permission.bluetooth.status;
      final location = await Permission.locationWhenInUse.status;
      return (bluetooth.isGranted || bluetooth.isLimited) &&
          (location.isGranted || location.isLimited);
    } else {
      final bluetoothAdvertise = await Permission.bluetoothAdvertise.status;
      final bluetoothConnect = await Permission.bluetoothConnect.status;
      final bluetoothScan = await Permission.bluetoothScan.status;

      return (bluetoothAdvertise.isGranted || bluetoothAdvertise.isLimited) &&
          (bluetoothConnect.isGranted || bluetoothConnect.isLimited) &&
          (bluetoothScan.isGranted || bluetoothScan.isLimited);
    }
  }

  /// Opens app settings if permissions were permanently denied.
  Future<void> openSettings() async {
    await openAppSettings();
  }

  /// Requests camera permission for QR code scanning.
  ///
  /// Returns true if permission is granted, false otherwise.
  Future<bool> requestCameraPermission() async {
    final status = await Permission.camera.request();
    debugPrint('Permission camera: $status');
    return status.isGranted || status.isLimited;
  }

  /// Checks if camera permission is already granted.
  Future<bool> hasCameraPermission() async {
    final status = await Permission.camera.status;
    return status.isGranted || status.isLimited;
  }
}
```

Differences from the original: `requestNearbyPermissions` → `requestBluetoothPermissions`; `hasNearbyPermissions` → `hasBluetoothPermissions`; class doc; `Permission.nearbyWifiDevices` removed from the Android list AND from the `hasBluetoothPermissions` Android branch.

- [ ] **Step 2: Update the call-site in `chat_controller.dart`**

In `examples/gossip_chat/lib/presentation/controllers/chat_controller.dart`, find this block at line 560-576:

```dart
  Future<bool> startNetworking() async {
    // Request permissions first
    final hasPermissions = await _permissionService.requestNearbyPermissions();
    if (!hasPermissions) {
      return false;
    }

    try {
      await _connectionService.startAdvertising();
      await _connectionService.startDiscovery();
      _updateConnectionStatus();
      return true;
    } catch (e) {
      _onError?.call('startNetworking', e);
      return false;
    }
  }
```

Replace with:

```dart
  Future<bool> startNetworking() async {
    // Request OS-level permissions first.
    final hasPermissions = await _permissionService.requestBluetoothPermissions();
    if (!hasPermissions) {
      return false;
    }

    // Verify BT is on / supported / authorized at the OS layer. We use
    // `Bluey.shared` because `ensureReady` only checks platform state
    // and doesn't need our per-instance local identity. This catches the
    // case where the user grants permissions but Bluetooth itself is off.
    try {
      await Bluey.shared.ensureReady();
    } catch (e) {
      _onError?.call('startNetworking.ensureReady', e);
      return false;
    }

    try {
      await _connectionService.startAdvertising();
      await _connectionService.startDiscovery();
      _updateConnectionStatus();
      return true;
    } catch (e) {
      _onError?.call('startNetworking', e);
      return false;
    }
  }
```

- [ ] **Step 3: Add the `bluey` import to `chat_controller.dart`**

Near the top of the file, alongside the existing imports, add:

```dart
import 'package:bluey/bluey.dart';
```

(Place it in alphabetical order with the other `package:` imports.)

- [ ] **Step 4: Run analyze**

```
flutter analyze
```

Expected: clean. (Run from `examples/gossip_chat/` so all files get analyzed together.)

- [ ] **Step 5: Commit**

```bash
git add examples/gossip_chat/lib/infrastructure/services/permission_service.dart \
        examples/gossip_chat/lib/presentation/controllers/chat_controller.dart
git commit -m "feat(gossip_chat): rename nearby permissions to bluetooth + ensureReady"
```

---

## Task 7: Update Android manifest and iOS Info.plist

**Files:**
- Modify: `examples/gossip_chat/android/app/src/main/AndroidManifest.xml`
- Modify: `examples/gossip_chat/ios/Runner/Info.plist` (cosmetic)

- [ ] **Step 1: Update `AndroidManifest.xml`**

Open `examples/gossip_chat/android/app/src/main/AndroidManifest.xml`. Find lines 4-14:

```xml
    <!-- Nearby Connections permissions -->
    <uses-permission android:name="android.permission.BLUETOOTH" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
    <uses-permission android:name="android.permission.CHANGE_WIFI_STATE" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    <uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" android:usesPermissionFlags="neverForLocation" />
```

Replace with:

```xml
    <!-- Bluetooth LE permissions -->
    <uses-permission android:name="android.permission.BLUETOOTH" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
```

Differences: comment text changed; three Wi-Fi permissions removed (`ACCESS_WIFI_STATE`, `CHANGE_WIFI_STATE`, `NEARBY_WIFI_DEVICES`).

- [ ] **Step 2: Update `Info.plist` (optional cosmetic tweak)**

Open `examples/gossip_chat/ios/Runner/Info.plist`. Find lines 29-32:

```xml
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>This app uses Bluetooth to discover and connect with nearby devices for peer-to-peer chat.</string>
	<key>NSBluetoothPeripheralUsageDescription</key>
	<string>This app uses Bluetooth to discover and connect with nearby devices for peer-to-peer chat.</string>
```

Replace the strings with:

```xml
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>This app uses Bluetooth Low Energy to discover and connect with nearby devices for peer-to-peer chat.</string>
	<key>NSBluetoothPeripheralUsageDescription</key>
	<string>This app uses Bluetooth Low Energy to discover and connect with nearby devices for peer-to-peer chat.</string>
```

(Optional — if you'd rather skip this, leave Info.plist untouched and just commit the Android changes.)

- [ ] **Step 3: Verify the app still builds**

Run from `examples/gossip_chat`:
```
flutter analyze
```
Expected: `No issues found!`

```
flutter build apk --debug
```
Expected: succeeds. (Skip if no Android SDK available locally — CI will catch it.)

- [ ] **Step 4: Commit**

```bash
git add examples/gossip_chat/android/app/src/main/AndroidManifest.xml \
        examples/gossip_chat/ios/Runner/Info.plist
git commit -m "build(gossip_chat): drop Wi-Fi permissions from Android manifest, tighten iOS BT description"
```

---

## Self-review checklist (run before declaring done)

- [ ] `flutter analyze` in `examples/gossip_chat` returns `No issues found!`
- [ ] `flutter pub get` in `examples/gossip_chat` succeeds without warnings about `gossip_nearby` or `nearby_connections` being missing
- [ ] `git grep -i 'gossip_nearby\|nearby_connections\|NearbyTransport\|NearbyMetrics\|nearbyMinLogLevel\|nearbyLogCallback\|requestNearbyPermissions\|hasNearbyPermissions' examples/gossip_chat/` returns nothing
- [ ] `git grep -i 'NEARBY_WIFI_DEVICES\|ACCESS_WIFI_STATE' examples/gossip_chat/` returns nothing
- [ ] All new symbols (`BlueyTransport`, `BlueyMetrics`, `blueyMinLogLevel`, `blueyLogCallback`, `requestBluetoothPermissions`) resolve cleanly across the example app
- [ ] `Bluey.shared.ensureReady()` is called in `ChatController.startNetworking` between permission grant and `transport.startAdvertising`
- [ ] `_serviceUuid` is defined in `main.dart` with the explanatory comment

## Optional real-device verification (out of scope per spec)

If you have two devices handy:
- Install on Android + iOS (or two of either).
- Grant Bluetooth permissions when prompted.
- Verify the peers screen finds the other device within ~5 seconds.
- Send a chat message and verify it appears on the other device.
- Watch the metrics dashboard: `totalConnectionsEstablished` should be > 0; `totalBytesSent`/`Received` should grow.

If discovery fails: check `transport.errors` in the debug logger output. The most common failure mode is iOS GATT cache staleness on cold-launched peripherals — the per-NodeId backoff in gossip_bluey will retry automatically.

---

## Spec ↔ plan coverage

| Spec section | Implemented by |
|---|---|
| Branch and commit shape (~5 commits off main) | All 7 tasks across `feat/gossip-chat-bluey` |
| Service UUID + comment | Task 2 step 2 |
| pubspec.yaml swap | Task 1 |
| main.dart transport swap | Task 2 |
| connection_service.dart wrapper rename | Task 3 |
| debug_logger.dart symbol rename | Task 4 |
| chat_controller.dart import + permission callsite | Tasks 5 + 6 |
| permission_service.dart rename + drop nearbyWifiDevices | Task 6 |
| AndroidManifest.xml Wi-Fi permission cleanup | Task 7 |
| Info.plist text tweak | Task 7 step 2 |
| `Bluey.shared.ensureReady()` flow | Task 6 step 2 |
| metrics_service.dart unchanged | Confirmed in Task 3 (no edits required) |
| sync_service.dart unchanged | Confirmed in Task 3 (no edits required) |
