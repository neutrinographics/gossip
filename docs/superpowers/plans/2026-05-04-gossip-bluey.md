# gossip_bluey Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a new `gossip_bluey` Flutter package — a BLE transport for `gossip` built on top of the `bluey` library — that mirrors `gossip_nearby`'s public surface, supports both mesh and star topologies, and survives an 8-device fully connected mesh on real BLE hardware. Then delete the broken `gossip_ble` package.

**Architecture:** DDD layered (facade → application → domain → infrastructure), parallel to `gossip_nearby`. Identity model: gossip's `NodeId` value *is* bluey's `ServerId` value (no handshake protocol). Wire format: one bidirectional GATT characteristic per service, length-prefixed framing chunked at MTU. Connection management adds soft `targetConnections`, per-`NodeId` exponential backoff, adaptive discovery, and a `discoveryFilter` predicate for pinning to a specific peer.

**Tech Stack:** Dart 3.10+, Flutter, `bluey` (path/git dep), `gossip` (path workspace dep), `mocktail` for mocking, `dart test` runner, `melos` for monorepo orchestration.

**Spec:** `docs/superpowers/specs/2026-05-04-gossip-bluey-design.md` — read this before starting any task.

**Source patterns to mirror:** Read `packages/gossip_nearby/` end-to-end before starting. The existing `gossip_nearby` is the closest production analog. Mirror its layering, naming conventions (e.g., `*_test.dart`, `domain/aggregates/`, etc.), and test style (`mocktail`, `group`/`test` structure).

**TDD discipline:** Every task that produces production code is a Red-Green-Refactor cycle: write the failing test first, run it, write the minimum code to pass, run again, refactor if needed, then commit. Do not skip the "run the failing test" step — confirming the test fails for the *right reason* is part of the cycle. After every task, `dart analyze` must pass with zero issues in the package.

---

## File structure

The package layout under `packages/gossip_bluey/`:

```
pubspec.yaml
analysis_options.yaml
lib/
  gossip_bluey.dart                              # Public exports
  src/
    facade/
      bluey_transport.dart                       # BlueyTransport, PeerEvent
    application/
      services/
        connection_service.dart                  # Lifecycle orchestrator
      observability/
        log_level.dart                           # Re-export gossip's LogLevel/LogCallback
        bluey_metrics.dart                       # Counters
    domain/
      aggregates/
        connection_registry.dart                 # NodeId ↔ ConnectionHandle
      entities/
        connection_handle.dart                   # Uniform send + recv stream over peer/client
      value_objects/
        service_uuid.dart                        # Validated 128-bit UUID
        gossip_characteristic_uuids.dart         # Derives char UUID from service UUID
        discovered_peer.dart                     # NodeId (from ServerId) result of discovery
      events/
        connection_event.dart                    # PeerOpened / PeerClosed
      errors/
        connection_error.dart                    # Sealed error hierarchy
      interfaces/
        bluey_port.dart                          # Port interface + BlueyPortEvent types
    infrastructure/
      adapters/
        bluey_port_impl.dart                     # Wraps the real Bluey instance
        gossip_gatt_service.dart                 # HostedService factory
      codec/
        frame_codec.dart                         # Length-prefix framing + chunking
      ports/
        bluey_message_port.dart                  # Implements gossip's MessagePort
test/
  facade/
    bluey_transport_test.dart
  application/
    services/
      connection_service_test.dart
    observability/
      bluey_metrics_test.dart
  domain/
    aggregates/
      connection_registry_test.dart
    entities/
      connection_handle_test.dart
    value_objects/
      service_uuid_test.dart
      gossip_characteristic_uuids_test.dart
    events/
      connection_event_test.dart
    errors/
      connection_error_test.dart
  infrastructure/
    codec/
      frame_codec_test.dart
    ports/
      bluey_message_port_test.dart
  integration/
    mesh_two_node_test.dart
    star_three_node_test.dart
    capacity_behavior_test.dart
  fakes/
    fake_bluey_port.dart                         # Shared in-memory BlueyPort for tests
```

Phases are gated by working software at the end of each phase.

---

## Phase 1: Package skeleton + value objects

### Task 1: Create the package skeleton

**Files:**
- Create: `packages/gossip_bluey/pubspec.yaml`
- Create: `packages/gossip_bluey/analysis_options.yaml`
- Create: `packages/gossip_bluey/lib/gossip_bluey.dart`
- Create: `packages/gossip_bluey/test/.gitkeep`
- Modify: root `pubspec.yaml` (the workspace `workspace:` list lives here in this repo)

- [ ] **Step 1: Create `pubspec.yaml`**

```yaml
name: gossip_bluey
description: BLE transport for gossip, built on the bluey library. Supports mesh and star topologies.
version: 0.1.0
repository: https://github.com/neutrinographics/gossip/tree/main/packages/gossip_bluey
publish_to: none
resolution: workspace

environment:
  sdk: ^3.10.4
  flutter: ">=3.10.0"

dependencies:
  flutter:
    sdk: flutter
  gossip:
    path: ../gossip
  bluey:
    git:
      url: https://github.com/neutrinographics/bluey.git
      path: bluey
  meta: ^1.11.0
  uuid: ^4.0.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  lints: ^6.0.0
  mocktail: ^1.0.4
```

- [ ] **Step 2: Create `analysis_options.yaml`**

Copy from `packages/gossip_nearby/analysis_options.yaml`. If the analyzer flags any rules in that file as deprecated/unrecognized for the current SDK, drop those lines (e.g. `avoid_returning_null_for_future` is deprecated under sound null safety) — note the deviation in the commit message.

- [ ] **Step 3: Create `lib/gossip_bluey.dart` with placeholder library directive**

```dart
/// BLE transport for gossip, built on the bluey library.
///
/// See `docs/superpowers/specs/2026-05-04-gossip-bluey-design.md` for the
/// full design rationale. Public exports are added incrementally as the
/// package is built up.
library;
```

- [ ] **Step 4: Add `packages/gossip_bluey` to the root `pubspec.yaml` `workspace:` list**

This repo uses Dart 3 native workspaces — the workspace member list lives in the root `pubspec.yaml`, not a separate `melos.yaml`. Add `- packages/gossip_bluey` to that list (keep `- packages/gossip_ble` for now; it gets removed in Phase 6).

- [ ] **Step 5: Verify the workspace bootstraps**

Run from repo root: `dart pub get && melos bootstrap`
Expected: succeeds with no errors. New package appears in `melos list`.

- [ ] **Step 6: Verify analyzer is clean**

Run: `cd packages/gossip_bluey && dart analyze`
Expected: `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add packages/gossip_bluey melos.yaml
git commit -m "feat(gossip_bluey): scaffold package skeleton"
```

---

### Task 2: ServiceUuid value object

**Files:**
- Create: `packages/gossip_bluey/lib/src/domain/value_objects/service_uuid.dart`
- Create: `packages/gossip_bluey/test/domain/value_objects/service_uuid_test.dart`

- [ ] **Step 1: Write the failing test**

`test/domain/value_objects/service_uuid_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/src/domain/value_objects/service_uuid.dart';

void main() {
  group('ServiceUuid', () {
    test('accepts a well-formed lowercase 128-bit UUID', () {
      final uuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');
      expect(uuid.value, equals('f0000000-0000-0000-0000-000000000000'));
    });

    test('lowercases mixed-case input', () {
      final uuid = ServiceUuid('F0000000-0000-0000-0000-000000000000');
      expect(uuid.value, equals('f0000000-0000-0000-0000-000000000000'));
    });

    test('throws ArgumentError on a malformed UUID', () {
      expect(() => ServiceUuid('not-a-uuid'), throwsArgumentError);
      expect(() => ServiceUuid(''), throwsArgumentError);
      expect(
        () => ServiceUuid('zzzzzzzz-0000-0000-0000-000000000000'),
        throwsArgumentError,
      );
    });

    test('compares by value', () {
      expect(
        ServiceUuid('f0000000-0000-0000-0000-000000000000'),
        equals(ServiceUuid('f0000000-0000-0000-0000-000000000000')),
      );
      expect(
        ServiceUuid('f0000000-0000-0000-0000-000000000000') ==
            ServiceUuid('f0000001-0000-0000-0000-000000000000'),
        isFalse,
      );
    });

    test('hashCode is consistent with equality', () {
      final a = ServiceUuid('f0000000-0000-0000-0000-000000000000');
      final b = ServiceUuid('f0000000-0000-0000-0000-000000000000');
      expect(a.hashCode, equals(b.hashCode));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/gossip_bluey && dart test test/domain/value_objects/service_uuid_test.dart`
Expected: FAIL — file `service_uuid.dart` does not exist.

- [ ] **Step 3: Write the implementation**

`lib/src/domain/value_objects/service_uuid.dart`:
```dart
/// 128-bit BLE service UUID, validated at construction.
class ServiceUuid {
  static final RegExp _pattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  final String value;

  ServiceUuid(String input) : value = input.toLowerCase() {
    if (!_pattern.hasMatch(value)) {
      throw ArgumentError.value(
        input,
        'value',
        'not a well-formed 128-bit UUID',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is ServiceUuid && other.value == value);

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ServiceUuid($value)';
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/gossip_bluey && dart test test/domain/value_objects/service_uuid_test.dart`
Expected: all five tests pass.

- [ ] **Step 5: Run analyzer**

Run: `cd packages/gossip_bluey && dart analyze`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add packages/gossip_bluey/lib/src/domain/value_objects/service_uuid.dart packages/gossip_bluey/test/domain/value_objects/service_uuid_test.dart
git commit -m "feat(gossip_bluey): add ServiceUuid value object"
```

---

### Task 3: GossipCharacteristicUuids derivation

The gossip data characteristic's UUID is deterministically derived from the user-provided service UUID by XORing the last byte with `0x01`. This avoids requiring the user to pick two UUIDs and prevents collisions across services.

**Files:**
- Create: `packages/gossip_bluey/lib/src/domain/value_objects/gossip_characteristic_uuids.dart`
- Create: `packages/gossip_bluey/test/domain/value_objects/gossip_characteristic_uuids_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/src/domain/value_objects/gossip_characteristic_uuids.dart';
import 'package:gossip_bluey/src/domain/value_objects/service_uuid.dart';

void main() {
  group('GossipCharacteristicUuids', () {
    test('derives the data characteristic UUID by XORing the last byte with 0x01', () {
      final service = ServiceUuid('f0000000-0000-0000-0000-000000000000');
      final uuids = GossipCharacteristicUuids.derive(service);
      expect(uuids.dataCharacteristic, equals('f0000000-0000-0000-0000-000000000001'));
    });

    test('handles a non-zero last byte cleanly', () {
      final service = ServiceUuid('f0000000-0000-0000-0000-0000000000ab');
      final uuids = GossipCharacteristicUuids.derive(service);
      expect(uuids.dataCharacteristic, equals('f0000000-0000-0000-0000-0000000000aa'));
    });

    test('is stable across calls', () {
      final service = ServiceUuid('f0000000-0000-0000-0000-000000000000');
      final a = GossipCharacteristicUuids.derive(service);
      final b = GossipCharacteristicUuids.derive(service);
      expect(a.dataCharacteristic, equals(b.dataCharacteristic));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/domain/value_objects/gossip_characteristic_uuids_test.dart`
Expected: FAIL — file does not exist.

- [ ] **Step 3: Write the implementation**

```dart
import 'service_uuid.dart';

/// Bundle of BLE characteristic UUIDs used by `gossip_bluey`.
///
/// Currently only the data characteristic. Derived deterministically from
/// the user's service UUID so the application doesn't have to pick two.
class GossipCharacteristicUuids {
  final String dataCharacteristic;

  const GossipCharacteristicUuids._({required this.dataCharacteristic});

  factory GossipCharacteristicUuids.derive(ServiceUuid serviceUuid) {
    final hex = serviceUuid.value.replaceAll('-', '');
    final lastByte = int.parse(hex.substring(30), radix: 16);
    final xored = (lastByte ^ 0x01).toRadixString(16).padLeft(2, '0');
    final mutatedHex = hex.substring(0, 30) + xored;
    final formatted =
        '${mutatedHex.substring(0, 8)}-${mutatedHex.substring(8, 12)}-'
        '${mutatedHex.substring(12, 16)}-${mutatedHex.substring(16, 20)}-'
        '${mutatedHex.substring(20, 32)}';
    return GossipCharacteristicUuids._(dataCharacteristic: formatted);
  }
}
```

- [ ] **Step 4: Run test, expect pass**

Run: `dart test test/domain/value_objects/gossip_characteristic_uuids_test.dart`
Expected: all three pass.

- [ ] **Step 5: Run analyzer**

Run: `dart analyze`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add packages/gossip_bluey/lib/src/domain/value_objects/gossip_characteristic_uuids.dart packages/gossip_bluey/test/domain/value_objects/gossip_characteristic_uuids_test.dart
git commit -m "feat(gossip_bluey): derive gossip data characteristic UUID from service UUID"
```

---

### Task 4: ConnectionEvent sealed hierarchy

**Files:**
- Create: `packages/gossip_bluey/lib/src/domain/events/connection_event.dart`
- Create: `packages/gossip_bluey/test/domain/events/connection_event_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/domain/events/connection_event.dart';

void main() {
  group('ConnectionEvent', () {
    final nodeId = NodeId('11111111-1111-1111-1111-111111111111');

    test('PeerOpened carries nodeId and displayName', () {
      final event = PeerOpened(nodeId: nodeId, displayName: 'Phone-A');
      expect(event.nodeId, equals(nodeId));
      expect(event.displayName, equals('Phone-A'));
    });

    test('PeerOpened equality', () {
      final a = PeerOpened(nodeId: nodeId, displayName: 'Phone-A');
      final b = PeerOpened(nodeId: nodeId, displayName: 'Phone-A');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('PeerClosed carries nodeId and reason', () {
      final event = PeerClosed(nodeId: nodeId, reason: 'silent peer');
      expect(event.nodeId, equals(nodeId));
      expect(event.reason, equals('silent peer'));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — file does not exist.

- [ ] **Step 3: Write the implementation**

```dart
import 'package:gossip/gossip.dart';

/// Domain events emitted by `ConnectionService` as connections come and go.
sealed class ConnectionEvent {
  const ConnectionEvent();
}

/// Emitted when a peer connection has been established and is ready for
/// gossip traffic.
final class PeerOpened extends ConnectionEvent {
  final NodeId nodeId;
  final String? displayName;

  const PeerOpened({required this.nodeId, this.displayName});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PeerOpened &&
          other.nodeId == nodeId &&
          other.displayName == displayName);

  @override
  int get hashCode => Object.hash(nodeId, displayName);
}

/// Emitted when a peer connection has been torn down.
final class PeerClosed extends ConnectionEvent {
  final NodeId nodeId;
  final String reason;

  const PeerClosed({required this.nodeId, required this.reason});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PeerClosed &&
          other.nodeId == nodeId &&
          other.reason == reason);

  @override
  int get hashCode => Object.hash(nodeId, reason);
}
```

- [ ] **Step 4: Run test, expect pass**

Run: `dart test test/domain/events/connection_event_test.dart`
Expected: pass.

- [ ] **Step 5: Run analyzer**

Run: `dart analyze` — clean.

- [ ] **Step 6: Commit**

```bash
git add packages/gossip_bluey/lib/src/domain/events packages/gossip_bluey/test/domain/events
git commit -m "feat(gossip_bluey): add PeerOpened/PeerClosed connection events"
```

---

### Task 5: ConnectionError sealed hierarchy

**Files:**
- Create: `packages/gossip_bluey/lib/src/domain/errors/connection_error.dart`
- Create: `packages/gossip_bluey/test/domain/errors/connection_error_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/domain/errors/connection_error.dart';

void main() {
  final nodeId = NodeId('11111111-1111-1111-1111-111111111111');

  group('ConnectionError', () {
    test('ConnectionNotFoundError carries nodeId and type', () {
      final err = ConnectionNotFoundError(
        message: 'no connection to peer',
        occurredAt: DateTime(2026, 5, 4),
        nodeId: nodeId,
      );
      expect(err.type, equals(ConnectionErrorType.connectionNotFound));
      expect(err.nodeId, equals(nodeId));
      expect(err.message, contains('no connection'));
    });

    test('SendFailedError preserves the underlying cause', () {
      final cause = StateError('write timeout');
      final err = SendFailedError(
        message: 'send failed',
        occurredAt: DateTime(2026, 5, 4),
        nodeId: nodeId,
        cause: cause,
      );
      expect(err.cause, same(cause));
      expect(err.type, equals(ConnectionErrorType.sendFailed));
    });

    test('ConnectionLostError type', () {
      final err = ConnectionLostError(
        message: 'lost',
        occurredAt: DateTime(2026, 5, 4),
        nodeId: nodeId,
      );
      expect(err.type, equals(ConnectionErrorType.connectionLost));
    });

    test('ConnectionLimitReachedError type', () {
      final err = ConnectionLimitReachedError(
        message: 'at capacity',
        occurredAt: DateTime(2026, 5, 4),
        nodeId: nodeId,
      );
      expect(err.type, equals(ConnectionErrorType.connectionLimitReached));
    });

    test('ConnectFailedError type', () {
      final err = ConnectFailedError(
        message: 'connect failed',
        occurredAt: DateTime(2026, 5, 4),
        nodeId: nodeId,
      );
      expect(err.type, equals(ConnectionErrorType.connectFailed));
    });

    test('FrameDecodeError type', () {
      final err = FrameDecodeError(
        message: 'oversize frame',
        occurredAt: DateTime(2026, 5, 4),
        nodeId: nodeId,
      );
      expect(err.type, equals(ConnectionErrorType.frameDecode));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — file does not exist.

- [ ] **Step 3: Write the implementation**

```dart
import 'package:gossip/gossip.dart';

enum ConnectionErrorType {
  connectionNotFound,
  connectionLost,
  connectFailed,
  sendFailed,
  connectionLimitReached,
  frameDecode,
}

/// Sealed base class for errors emitted on `BlueyTransport.errors`.
sealed class ConnectionError {
  final String message;
  final DateTime occurredAt;
  final ConnectionErrorType type;
  final Object? cause;

  const ConnectionError({
    required this.message,
    required this.occurredAt,
    required this.type,
    this.cause,
  });

  @override
  String toString() => '${type.name}: $message';
}

final class ConnectionNotFoundError extends ConnectionError {
  final NodeId nodeId;
  const ConnectionNotFoundError({
    required super.message,
    required super.occurredAt,
    required this.nodeId,
    super.cause,
  }) : super(type: ConnectionErrorType.connectionNotFound);
}

final class ConnectionLostError extends ConnectionError {
  final NodeId nodeId;
  const ConnectionLostError({
    required super.message,
    required super.occurredAt,
    required this.nodeId,
    super.cause,
  }) : super(type: ConnectionErrorType.connectionLost);
}

final class ConnectFailedError extends ConnectionError {
  final NodeId nodeId;
  const ConnectFailedError({
    required super.message,
    required super.occurredAt,
    required this.nodeId,
    super.cause,
  }) : super(type: ConnectionErrorType.connectFailed);
}

final class SendFailedError extends ConnectionError {
  final NodeId nodeId;
  const SendFailedError({
    required super.message,
    required super.occurredAt,
    required this.nodeId,
    super.cause,
  }) : super(type: ConnectionErrorType.sendFailed);
}

final class ConnectionLimitReachedError extends ConnectionError {
  final NodeId nodeId;
  const ConnectionLimitReachedError({
    required super.message,
    required super.occurredAt,
    required this.nodeId,
    super.cause,
  }) : super(type: ConnectionErrorType.connectionLimitReached);
}

final class FrameDecodeError extends ConnectionError {
  final NodeId nodeId;
  const FrameDecodeError({
    required super.message,
    required super.occurredAt,
    required this.nodeId,
    super.cause,
  }) : super(type: ConnectionErrorType.frameDecode);
}
```

- [ ] **Step 4: Run test, expect pass; analyze, expect clean**

```
dart test test/domain/errors/connection_error_test.dart
dart analyze
```

- [ ] **Step 5: Commit**

```bash
git add packages/gossip_bluey/lib/src/domain/errors packages/gossip_bluey/test/domain/errors
git commit -m "feat(gossip_bluey): add ConnectionError hierarchy"
```

---

### Task 6: BlueyMetrics

**Files:**
- Create: `packages/gossip_bluey/lib/src/application/observability/bluey_metrics.dart`
- Create: `packages/gossip_bluey/test/application/observability/bluey_metrics_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/src/application/observability/bluey_metrics.dart';

void main() {
  group('BlueyMetrics', () {
    test('starts with all counters at zero', () {
      final m = BlueyMetrics();
      expect(m.connectedPeerCount, equals(0));
      expect(m.totalConnectionsEstablished, equals(0));
      expect(m.totalConnectionsFailed, equals(0));
      expect(m.totalBytesSent, equals(0));
      expect(m.totalBytesReceived, equals(0));
      expect(m.totalMessagesSent, equals(0));
      expect(m.totalMessagesReceived, equals(0));
      expect(m.totalFramesSent, equals(0));
      expect(m.totalFramesReceived, equals(0));
    });

    test('record* methods increment the corresponding counter', () {
      final m = BlueyMetrics();
      m.recordConnectionEstablished();
      m.recordConnectionFailed();
      m.recordBytesSent(100);
      m.recordBytesReceived(200);
      m.recordMessageSent();
      m.recordMessageReceived();
      m.recordFrameSent();
      m.recordFrameReceived();
      m.setConnectedPeerCount(3);

      expect(m.totalConnectionsEstablished, equals(1));
      expect(m.totalConnectionsFailed, equals(1));
      expect(m.totalBytesSent, equals(100));
      expect(m.totalBytesReceived, equals(200));
      expect(m.totalMessagesSent, equals(1));
      expect(m.totalMessagesReceived, equals(1));
      expect(m.totalFramesSent, equals(1));
      expect(m.totalFramesReceived, equals(1));
      expect(m.connectedPeerCount, equals(3));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — file does not exist.

- [ ] **Step 3: Write the implementation**

```dart
/// Counters for monitoring `BlueyTransport` health and throughput.
class BlueyMetrics {
  int _connectedPeerCount = 0;
  int _totalConnectionsEstablished = 0;
  int _totalConnectionsFailed = 0;
  int _totalBytesSent = 0;
  int _totalBytesReceived = 0;
  int _totalMessagesSent = 0;
  int _totalMessagesReceived = 0;
  int _totalFramesSent = 0;
  int _totalFramesReceived = 0;

  int get connectedPeerCount => _connectedPeerCount;
  int get totalConnectionsEstablished => _totalConnectionsEstablished;
  int get totalConnectionsFailed => _totalConnectionsFailed;
  int get totalBytesSent => _totalBytesSent;
  int get totalBytesReceived => _totalBytesReceived;
  int get totalMessagesSent => _totalMessagesSent;
  int get totalMessagesReceived => _totalMessagesReceived;
  int get totalFramesSent => _totalFramesSent;
  int get totalFramesReceived => _totalFramesReceived;

  void setConnectedPeerCount(int n) => _connectedPeerCount = n;
  void recordConnectionEstablished() => _totalConnectionsEstablished++;
  void recordConnectionFailed() => _totalConnectionsFailed++;
  void recordBytesSent(int n) => _totalBytesSent += n;
  void recordBytesReceived(int n) => _totalBytesReceived += n;
  void recordMessageSent() => _totalMessagesSent++;
  void recordMessageReceived() => _totalMessagesReceived++;
  void recordFrameSent() => _totalFramesSent++;
  void recordFrameReceived() => _totalFramesReceived++;
}
```

- [ ] **Step 4: Run test, expect pass; analyze, expect clean**

- [ ] **Step 5: Commit**

```bash
git add packages/gossip_bluey/lib/src/application/observability packages/gossip_bluey/test/application/observability
git commit -m "feat(gossip_bluey): add BlueyMetrics counters"
```

---

### Task 7: LogLevel re-export

**Files:**
- Create: `packages/gossip_bluey/lib/src/application/observability/log_level.dart`

- [ ] **Step 1: Create the re-export**

```dart
/// Unified logging surface — re-export gossip's [LogLevel] and
/// [LogCallback] so applications get the same logging API regardless of
/// which transport they use.
library;

export 'package:gossip/gossip.dart' show LogLevel, LogCallback;
```

- [ ] **Step 2: Verify it compiles**

Run: `dart analyze` — expect clean.

- [ ] **Step 3: Commit**

```bash
git add packages/gossip_bluey/lib/src/application/observability/log_level.dart
git commit -m "feat(gossip_bluey): re-export LogLevel/LogCallback from gossip"
```

---

## Phase 2: Frame codec

### Task 8: FrameEncoder — chunking output

`FrameEncoder` takes a payload and an MTU, returns a list of MTU-sized chunks ready to write. The first chunk includes a 4-byte big-endian length prefix.

**Files:**
- Create: `packages/gossip_bluey/lib/src/infrastructure/codec/frame_codec.dart`
- Create: `packages/gossip_bluey/test/infrastructure/codec/frame_codec_test.dart`

- [ ] **Step 1: Write failing tests for the encoder**

```dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/src/infrastructure/codec/frame_codec.dart';

void main() {
  group('FrameEncoder', () {
    test('emits a single chunk when payload + length prefix fits the MTU', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final chunks = FrameEncoder.encode(payload, mtuPayloadSize: 100);
      expect(chunks, hasLength(1));
      expect(chunks.first, hasLength(4 + 5));
      // length prefix: big-endian 5
      expect(chunks.first.sublist(0, 4), equals([0, 0, 0, 5]));
      expect(chunks.first.sublist(4), equals([1, 2, 3, 4, 5]));
    });

    test('splits across multiple chunks when payload exceeds MTU', () {
      // mtuPayloadSize = 8. Length prefix takes 4 bytes of the first chunk.
      // Payload = 20 bytes. First chunk carries 4 prefix bytes + 4 payload bytes;
      // remaining 16 payload bytes need ceil(16/8) = 2 chunks.
      final payload = Uint8List.fromList(List.generate(20, (i) => i));
      final chunks = FrameEncoder.encode(payload, mtuPayloadSize: 8);
      expect(chunks, hasLength(3));
      expect(chunks[0], hasLength(8));
      expect(chunks[0].sublist(0, 4), equals([0, 0, 0, 20]));
      expect(chunks[0].sublist(4), equals([0, 1, 2, 3]));
      expect(chunks[1], hasLength(8));
      expect(chunks[1], equals([4, 5, 6, 7, 8, 9, 10, 11]));
      expect(chunks[2], hasLength(8));
      expect(chunks[2], equals([12, 13, 14, 15, 16, 17, 18, 19]));
    });

    test('throws on empty payload', () {
      expect(
        () => FrameEncoder.encode(Uint8List(0), mtuPayloadSize: 20),
        throwsArgumentError,
      );
    });

    test('throws when mtuPayloadSize is too small to hold the prefix', () {
      // length prefix is 4 bytes; if the chunk can't hold even that, encoding
      // is impossible.
      expect(
        () => FrameEncoder.encode(
          Uint8List.fromList([1]),
          mtuPayloadSize: 3,
        ),
        throwsArgumentError,
      );
    });

    test('rejects payloads larger than 32KB', () {
      final payload = Uint8List(32 * 1024 + 1);
      expect(
        () => FrameEncoder.encode(payload, mtuPayloadSize: 200),
        throwsArgumentError,
      );
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — file does not exist.

- [ ] **Step 3: Implement the encoder**

```dart
import 'dart:typed_data';

/// Maximum gossip message payload. Anything larger is rejected.
const int kMaxFramePayload = 32 * 1024;

/// Length prefix size in bytes (big-endian uint32).
const int kLengthPrefixSize = 4;

/// Encodes a gossip payload into MTU-sized chunks for sequential writes.
abstract final class FrameEncoder {
  /// Returns the chunks to write, in order.
  ///
  /// [mtuPayloadSize] is the per-chunk byte budget — i.e. the negotiated
  /// MTU minus 3 for the ATT header (and any safety margin the caller wants
  /// to subtract). Must be at least [kLengthPrefixSize] + 1.
  ///
  /// Throws [ArgumentError] if [payload] is empty, larger than
  /// [kMaxFramePayload], or [mtuPayloadSize] is too small.
  static List<Uint8List> encode(
    Uint8List payload, {
    required int mtuPayloadSize,
  }) {
    if (payload.isEmpty) {
      throw ArgumentError.value(payload, 'payload', 'must be non-empty');
    }
    if (payload.length > kMaxFramePayload) {
      throw ArgumentError.value(
        payload.length,
        'payload.length',
        'exceeds 32KB max',
      );
    }
    if (mtuPayloadSize <= kLengthPrefixSize) {
      throw ArgumentError.value(
        mtuPayloadSize,
        'mtuPayloadSize',
        'must exceed length prefix size ($kLengthPrefixSize)',
      );
    }

    final framed = Uint8List(kLengthPrefixSize + payload.length);
    final view = ByteData.view(framed.buffer);
    view.setUint32(0, payload.length, Endian.big);
    framed.setRange(kLengthPrefixSize, framed.length, payload);

    final chunks = <Uint8List>[];
    var offset = 0;
    while (offset < framed.length) {
      final end = (offset + mtuPayloadSize).clamp(0, framed.length);
      chunks.add(framed.sublist(offset, end));
      offset = end;
    }
    return chunks;
  }
}
```

- [ ] **Step 4: Run tests, expect pass; analyze, expect clean**

- [ ] **Step 5: Commit**

```bash
git add packages/gossip_bluey/lib/src/infrastructure/codec/frame_codec.dart packages/gossip_bluey/test/infrastructure/codec/frame_codec_test.dart
git commit -m "feat(gossip_bluey): FrameEncoder splits payload into MTU-sized chunks"
```

---

### Task 9: FrameDecoder — buffering reassembly

**Files:**
- Modify: `packages/gossip_bluey/lib/src/infrastructure/codec/frame_codec.dart`
- Modify: `packages/gossip_bluey/test/infrastructure/codec/frame_codec_test.dart`

- [ ] **Step 1: Append decoder tests**

Add a new `group` to the existing test file:

```dart
  group('FrameDecoder', () {
    test('round-trips a small payload through encode → decode', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final chunks = FrameEncoder.encode(payload, mtuPayloadSize: 100);
      final decoder = FrameDecoder();
      final decoded = <Uint8List>[];
      for (final chunk in chunks) {
        decoded.addAll(decoder.feed(chunk));
      }
      expect(decoded, hasLength(1));
      expect(decoded.first, equals(payload));
    });

    test('round-trips a chunked payload', () {
      final payload = Uint8List.fromList(List.generate(20, (i) => i));
      final chunks = FrameEncoder.encode(payload, mtuPayloadSize: 8);
      final decoder = FrameDecoder();
      final decoded = <Uint8List>[];
      for (final chunk in chunks) {
        decoded.addAll(decoder.feed(chunk));
      }
      expect(decoded, hasLength(1));
      expect(decoded.first, equals(payload));
    });

    test('emits multiple complete frames when bytes arrive together', () {
      final p1 = Uint8List.fromList([1, 2, 3]);
      final p2 = Uint8List.fromList([10, 20, 30, 40]);
      final chunks1 = FrameEncoder.encode(p1, mtuPayloadSize: 100);
      final chunks2 = FrameEncoder.encode(p2, mtuPayloadSize: 100);
      final combined = Uint8List.fromList(
        chunks1.expand((c) => c).followedBy(chunks2.expand((c) => c)).toList(),
      );

      final decoder = FrameDecoder();
      final decoded = decoder.feed(combined);
      expect(decoded, hasLength(2));
      expect(decoded[0], equals(p1));
      expect(decoded[1], equals(p2));
    });

    test('emits no frame until the length prefix is complete', () {
      final decoder = FrameDecoder();
      // Only 2 bytes of the 4-byte length prefix.
      final partial = decoder.feed(Uint8List.fromList([0, 0]));
      expect(partial, isEmpty);
      // Two more length bytes + payload.
      final rest = decoder.feed(Uint8List.fromList([0, 3, 1, 2, 3]));
      expect(rest, hasLength(1));
      expect(rest.first, equals([1, 2, 3]));
    });

    test('rejects an oversize length prefix', () {
      final decoder = FrameDecoder();
      // 33 KB
      final tooBig = (32 * 1024) + 1;
      final view = ByteData(4)..setUint32(0, tooBig, Endian.big);
      expect(
        () => decoder.feed(view.buffer.asUint8List()),
        throwsA(isA<FormatException>()),
      );
    });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `FrameDecoder` does not exist.

- [ ] **Step 3: Append `FrameDecoder` to `frame_codec.dart`**

```dart
/// Reassembles framed bytes (4-byte BE length prefix + payload) arriving
/// in arbitrary chunk sizes.
///
/// Stateful: keep one decoder per connection. Surplus bytes from one frame
/// remain buffered for the next.
class FrameDecoder {
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  int? _expectedLength;

  /// Feeds [chunk] into the decoder and returns any complete payloads
  /// available now. Throws [FormatException] if the length prefix
  /// exceeds [kMaxFramePayload].
  List<Uint8List> feed(Uint8List chunk) {
    _buffer.add(chunk);
    final out = <Uint8List>[];

    while (true) {
      if (_expectedLength == null) {
        if (_buffer.length < kLengthPrefixSize) break;
        final all = _buffer.takeBytes();
        final view = ByteData.view(all.buffer, all.offsetInBytes);
        final len = view.getUint32(0, Endian.big);
        if (len > kMaxFramePayload) {
          throw FormatException(
            'frame length $len exceeds max $kMaxFramePayload',
          );
        }
        _expectedLength = len;
        // Re-add bytes after the prefix.
        if (all.length > kLengthPrefixSize) {
          _buffer.add(all.sublist(kLengthPrefixSize));
        }
        continue;
      }

      if (_buffer.length < _expectedLength!) break;
      final all = _buffer.takeBytes();
      final payload = Uint8List.sublistView(all, 0, _expectedLength!);
      out.add(Uint8List.fromList(payload));
      final remainder = all.sublist(_expectedLength!);
      _expectedLength = null;
      if (remainder.isNotEmpty) {
        _buffer.add(remainder);
      }
    }

    return out;
  }
}
```

- [ ] **Step 4: Run tests, expect pass; analyze, expect clean**

- [ ] **Step 5: Commit**

```bash
git add packages/gossip_bluey/lib/src/infrastructure/codec/frame_codec.dart packages/gossip_bluey/test/infrastructure/codec/frame_codec_test.dart
git commit -m "feat(gossip_bluey): FrameDecoder reassembles framed bytes from arbitrary chunks"
```

---

## Phase 3: Domain port + ConnectionRegistry

### Task 10: BlueyPort interface and event types

The port abstracts over bluey's API. It speaks only in domain types (`NodeId`, `Uint8List`). Bluey-specific types (`BlueyPeer`, `Server`, `PeerClient`, `PeerConnection`) are internal to the impl.

**Files:**
- Create: `packages/gossip_bluey/lib/src/domain/value_objects/discovered_peer.dart`
- Create: `packages/gossip_bluey/lib/src/domain/interfaces/bluey_port.dart`

- [ ] **Step 1: Create `discovered_peer.dart`**

```dart
import 'package:gossip/gossip.dart';

/// Result of a discovery round: a peer found over BLE that hosts the
/// gossip service.
class DiscoveredPeer {
  final NodeId nodeId;
  const DiscoveredPeer({required this.nodeId});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DiscoveredPeer && other.nodeId == nodeId);

  @override
  int get hashCode => nodeId.hashCode;
}
```

- [ ] **Step 2: Create `bluey_port.dart`**

```dart
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

import '../value_objects/discovered_peer.dart';
import '../value_objects/service_uuid.dart';

/// Domain abstraction over the bluey library. Speaks only in domain types
/// — bluey's `BlueyPeer`/`PeerConnection`/`Server`/`PeerClient` are
/// internal to the infrastructure adapter.
///
/// Tests substitute an in-memory implementation; production wires
/// [BlueyPortImpl] (which holds a real `Bluey` instance).
abstract interface class BlueyPort {
  /// Begin advertising as a gossip-speaking peripheral.
  ///
  /// Constructs the GATT server (with [localNodeId] embedded as the
  /// bluey `ServerId`), registers the gossip service, and starts
  /// advertising with the bluey lifecycle control service in the payload
  /// so other devices can find us via discovery.
  Future<void> startAdvertising({
    required ServiceUuid serviceUuid,
    required String displayName,
    required NodeId localNodeId,
  });

  Future<void> stopAdvertising();

  /// Run a single discovery round. Returns peers that advertised our
  /// gossip service, deduplicated by `NodeId`.
  Future<List<DiscoveredPeer>> discoverPeers({
    required ServiceUuid serviceUuid,
    Duration timeout = const Duration(seconds: 5),
  });

  /// Initiate a central-role connection to [target]. Completes when the
  /// connection has been established and the gossip characteristic
  /// subscribed; throws on failure.
  Future<void> connect(NodeId target);

  /// Disconnect [nodeId] (whichever role we hold for that peer).
  Future<void> disconnect(NodeId nodeId);

  /// Send [data] to [nodeId]. Internally selects write (central role) or
  /// notify (peripheral role) based on the held connection. Throws on
  /// failure (transient or permanent).
  Future<void> sendData(NodeId nodeId, Uint8List data);

  /// Stream of role-agnostic transport events.
  Stream<BlueyPortEvent> get events;

  Future<void> dispose();
}

/// Sealed event hierarchy emitted by [BlueyPort.events].
sealed class BlueyPortEvent {
  const BlueyPortEvent();
}

/// A bluey-confirmed peer is now connected (either we initiated or they
/// did). [role] tells the consumer which API to use for sends — but
/// [BlueyPort.sendData] hides that detail anyway.
final class PortPeerConnected extends BlueyPortEvent {
  final NodeId nodeId;
  final ConnectionRole role;
  final String? displayName;
  const PortPeerConnected({
    required this.nodeId,
    required this.role,
    this.displayName,
  });
}

final class PortPeerDisconnected extends BlueyPortEvent {
  final NodeId nodeId;
  final String reason;
  const PortPeerDisconnected({required this.nodeId, required this.reason});
}

/// Bytes received from a peer (already extracted from notification or
/// write request — pre-framing).
final class PortPeerData extends BlueyPortEvent {
  final NodeId nodeId;
  final Uint8List data;
  const PortPeerData({required this.nodeId, required this.data});
}

/// A central-role connect attempt failed.
final class PortConnectFailed extends BlueyPortEvent {
  final NodeId nodeId;
  final String reason;
  const PortConnectFailed({required this.nodeId, required this.reason});
}

enum ConnectionRole { central, peripheral }
```

- [ ] **Step 3: Run analyzer, expect clean**

Run: `dart analyze`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add packages/gossip_bluey/lib/src/domain/value_objects/discovered_peer.dart packages/gossip_bluey/lib/src/domain/interfaces/bluey_port.dart
git commit -m "feat(gossip_bluey): define BlueyPort interface and event types"
```

---

### Task 11: ConnectionHandle entity

`ConnectionHandle` is a value-bag that the registry stores per `NodeId`. Its only responsibility is to remember the role so the port (or future code) can route sends correctly. It does *not* hold bluey types — those live in `BlueyPortImpl`.

**Files:**
- Create: `packages/gossip_bluey/lib/src/domain/entities/connection_handle.dart`
- Create: `packages/gossip_bluey/test/domain/entities/connection_handle_test.dart`

- [ ] **Step 1: Write failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/domain/entities/connection_handle.dart';
import 'package:gossip_bluey/src/domain/interfaces/bluey_port.dart';

void main() {
  final nodeId = NodeId('11111111-1111-1111-1111-111111111111');
  final t0 = DateTime(2026, 5, 4);

  group('ConnectionHandle', () {
    test('exposes nodeId, role, displayName, connectedAt', () {
      final h = ConnectionHandle(
        nodeId: nodeId,
        role: ConnectionRole.central,
        displayName: 'Phone-A',
        connectedAt: t0,
      );
      expect(h.nodeId, equals(nodeId));
      expect(h.role, equals(ConnectionRole.central));
      expect(h.displayName, equals('Phone-A'));
      expect(h.connectedAt, equals(t0));
    });

    test('equality by nodeId only', () {
      final a = ConnectionHandle(
        nodeId: nodeId,
        role: ConnectionRole.central,
        connectedAt: t0,
      );
      final b = ConnectionHandle(
        nodeId: nodeId,
        role: ConnectionRole.peripheral,
        connectedAt: DateTime(2026, 6, 1),
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });
}
```

- [ ] **Step 2: Run, expect fail**

Expected: FAIL — file does not exist.

- [ ] **Step 3: Implement**

```dart
import 'package:gossip/gossip.dart';

import '../interfaces/bluey_port.dart';

/// Per-peer connection metadata held in [ConnectionRegistry].
///
/// Equality is by [nodeId] only — at most one handle per NodeId can exist
/// in the registry.
class ConnectionHandle {
  final NodeId nodeId;
  final ConnectionRole role;
  final String? displayName;
  final DateTime connectedAt;

  const ConnectionHandle({
    required this.nodeId,
    required this.role,
    required this.connectedAt,
    this.displayName,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConnectionHandle && other.nodeId == nodeId);

  @override
  int get hashCode => nodeId.hashCode;
}
```

- [ ] **Step 4: Run, expect pass; analyze, expect clean**

- [ ] **Step 5: Commit**

```bash
git add packages/gossip_bluey/lib/src/domain/entities/connection_handle.dart packages/gossip_bluey/test/domain/entities/connection_handle_test.dart
git commit -m "feat(gossip_bluey): add ConnectionHandle entity"
```

---

### Task 12: ConnectionRegistry

**Files:**
- Create: `packages/gossip_bluey/lib/src/domain/aggregates/connection_registry.dart`
- Create: `packages/gossip_bluey/test/domain/aggregates/connection_registry_test.dart`

- [ ] **Step 1: Write failing tests**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/domain/aggregates/connection_registry.dart';
import 'package:gossip_bluey/src/domain/entities/connection_handle.dart';
import 'package:gossip_bluey/src/domain/interfaces/bluey_port.dart';

void main() {
  final nodeIdA = NodeId('11111111-1111-1111-1111-111111111111');
  final nodeIdB = NodeId('22222222-2222-2222-2222-222222222222');
  final t0 = DateTime(2026, 5, 4);

  ConnectionHandle handle(NodeId id, [ConnectionRole role = ConnectionRole.central]) =>
      ConnectionHandle(nodeId: id, role: role, connectedAt: t0);

  group('ConnectionRegistry', () {
    test('starts empty', () {
      final r = ConnectionRegistry();
      expect(r.connectionCount, equals(0));
      expect(r.connections, isEmpty);
      expect(r.contains(nodeIdA), isFalse);
    });

    test('add stores a handle and contains/get find it', () {
      final r = ConnectionRegistry();
      r.add(handle(nodeIdA));
      expect(r.contains(nodeIdA), isTrue);
      expect(r.get(nodeIdA), equals(handle(nodeIdA)));
      expect(r.connectionCount, equals(1));
    });

    test('add returns the previous handle if a duplicate exists', () {
      final r = ConnectionRegistry();
      final first = handle(nodeIdA, ConnectionRole.central);
      final second = handle(nodeIdA, ConnectionRole.peripheral);
      expect(r.add(first), isNull);
      final replaced = r.add(second);
      expect(replaced, equals(first));
      // The new handle is now stored.
      expect(r.get(nodeIdA)?.role, equals(ConnectionRole.peripheral));
    });

    test('remove returns the removed handle', () {
      final r = ConnectionRegistry();
      r.add(handle(nodeIdA));
      final removed = r.remove(nodeIdA);
      expect(removed, isNotNull);
      expect(r.contains(nodeIdA), isFalse);
      expect(r.connectionCount, equals(0));
    });

    test('remove of an absent NodeId returns null', () {
      final r = ConnectionRegistry();
      expect(r.remove(nodeIdA), isNull);
    });

    test('connections returns all handles', () {
      final r = ConnectionRegistry()
        ..add(handle(nodeIdA))
        ..add(handle(nodeIdB));
      expect(r.connections.map((h) => h.nodeId), containsAll([nodeIdA, nodeIdB]));
    });
  });
}
```

- [ ] **Step 2: Run, expect fail**

- [ ] **Step 3: Implement**

```dart
import 'package:gossip/gossip.dart';

import '../entities/connection_handle.dart';

/// Tracks active connections, keyed by [NodeId]. Enforces NodeId-uniqueness
/// — adding a second handle for the same NodeId returns the previous handle
/// so the caller can tear it down.
class ConnectionRegistry {
  final Map<NodeId, ConnectionHandle> _byNodeId = {};

  int get connectionCount => _byNodeId.length;

  Iterable<ConnectionHandle> get connections => _byNodeId.values;

  bool contains(NodeId nodeId) => _byNodeId.containsKey(nodeId);

  ConnectionHandle? get(NodeId nodeId) => _byNodeId[nodeId];

  /// Adds [handle]. Returns the previous handle for the same NodeId if
  /// one existed (caller is responsible for tearing it down), or `null`
  /// if this is a fresh registration.
  ConnectionHandle? add(ConnectionHandle handle) {
    final previous = _byNodeId[handle.nodeId];
    _byNodeId[handle.nodeId] = handle;
    return previous;
  }

  /// Removes the handle for [nodeId]. Returns it, or `null` if absent.
  ConnectionHandle? remove(NodeId nodeId) => _byNodeId.remove(nodeId);
}
```

- [ ] **Step 4: Run, expect pass; analyze, expect clean**

- [ ] **Step 5: Commit**

```bash
git add packages/gossip_bluey/lib/src/domain/aggregates/connection_registry.dart packages/gossip_bluey/test/domain/aggregates/connection_registry_test.dart
git commit -m "feat(gossip_bluey): add ConnectionRegistry aggregate"
```

---

## Phase 4: BlueyMessagePort + FakeBlueyPort

### Task 13: BlueyMessagePort

`BlueyMessagePort` implements gossip's `MessagePort` by delegating to `ConnectionService`. Since `ConnectionService` doesn't exist yet, we'll bind via a small interface that `ConnectionService` will satisfy in Task 16.

**Files:**
- Create: `packages/gossip_bluey/lib/src/infrastructure/ports/bluey_message_port.dart`
- Create: `packages/gossip_bluey/test/infrastructure/ports/bluey_message_port_test.dart`

- [ ] **Step 1: Write failing test**

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/infrastructure/ports/bluey_message_port.dart';

class _FakeService implements MessageDispatcher {
  final List<(NodeId, Uint8List, MessagePriority)> sent = [];
  final StreamController<IncomingMessage> incoming =
      StreamController<IncomingMessage>.broadcast();
  bool closed = false;

  @override
  Future<void> sendGossipMessage(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  }) async {
    sent.add((destination, bytes, priority));
  }

  @override
  Stream<IncomingMessage> get incomingMessages => incoming.stream;

  @override
  int pendingSendCount(NodeId peer) => 0;

  @override
  int get totalPendingSendCount => 0;

  @override
  Future<void> close() async {
    closed = true;
    await incoming.close();
  }
}

void main() {
  group('BlueyMessagePort', () {
    test('forwards send to the dispatcher', () async {
      final svc = _FakeService();
      final port = BlueyMessagePort(svc);
      final destination = NodeId('11111111-1111-1111-1111-111111111111');
      final bytes = Uint8List.fromList([1, 2, 3]);
      await port.send(destination, bytes, priority: MessagePriority.high);
      expect(svc.sent, hasLength(1));
      expect(svc.sent.first.$1, equals(destination));
      expect(svc.sent.first.$2, equals(bytes));
      expect(svc.sent.first.$3, equals(MessagePriority.high));
    });

    test('exposes incoming messages from the dispatcher', () async {
      final svc = _FakeService();
      final port = BlueyMessagePort(svc);
      final destination = NodeId('11111111-1111-1111-1111-111111111111');
      final received = <IncomingMessage>[];
      final sub = port.incoming.listen(received.add);
      svc.incoming.add(IncomingMessage(
        sender: destination,
        bytes: Uint8List.fromList([9]),
        receivedAt: DateTime(2026, 5, 4),
      ));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(received, hasLength(1));
      expect(received.first.sender, equals(destination));
    });

    test('close closes the dispatcher', () async {
      final svc = _FakeService();
      final port = BlueyMessagePort(svc);
      await port.close();
      expect(svc.closed, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run, expect fail**

Expected: FAIL — file does not exist.

- [ ] **Step 3: Implement**

```dart
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

/// Minimal interface that [BlueyMessagePort] needs from the connection
/// service. Lets the message port and connection service be tested
/// independently.
abstract interface class MessageDispatcher {
  Future<void> sendGossipMessage(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  });

  Stream<IncomingMessage> get incomingMessages;

  int pendingSendCount(NodeId peer);
  int get totalPendingSendCount;

  Future<void> close();
}

/// Implements gossip's [MessagePort] by delegating to a [MessageDispatcher].
class BlueyMessagePort implements MessagePort {
  final MessageDispatcher _dispatcher;

  BlueyMessagePort(this._dispatcher);

  @override
  Future<void> send(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  }) {
    return _dispatcher.sendGossipMessage(
      destination,
      bytes,
      priority: priority,
    );
  }

  @override
  Stream<IncomingMessage> get incoming => _dispatcher.incomingMessages;

  @override
  int pendingSendCount(NodeId peer) => _dispatcher.pendingSendCount(peer);

  @override
  int get totalPendingSendCount => _dispatcher.totalPendingSendCount;

  @override
  Future<void> close() => _dispatcher.close();
}
```

- [ ] **Step 4: Run, expect pass; analyze, expect clean**

- [ ] **Step 5: Commit**

```bash
git add packages/gossip_bluey/lib/src/infrastructure/ports packages/gossip_bluey/test/infrastructure/ports
git commit -m "feat(gossip_bluey): add BlueyMessagePort and MessageDispatcher seam"
```

---

### Task 14: FakeBlueyPort (test fixture)

Build the in-memory `BlueyPort` used by `ConnectionService` tests and integration tests. Built incrementally — start with the operations the discovery/connect test needs; expand as later tests demand more.

**Files:**
- Create: `packages/gossip_bluey/test/fakes/fake_bluey_port.dart`

- [ ] **Step 1: Implement an in-memory shared registry of fakes**

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/domain/interfaces/bluey_port.dart';
import 'package:gossip_bluey/src/domain/value_objects/discovered_peer.dart';
import 'package:gossip_bluey/src/domain/value_objects/service_uuid.dart';

/// In-memory shared bus that lets multiple [FakeBlueyPort]s find,
/// connect to, and exchange data with each other in tests.
class FakeBlueyNetwork {
  final Map<NodeId, FakeBlueyPort> _ports = {};

  void register(FakeBlueyPort port) {
    _ports[port.localNodeId] = port;
  }

  void unregister(NodeId nodeId) {
    _ports.remove(nodeId);
  }

  Iterable<FakeBlueyPort> advertisingPeersFor(ServiceUuid serviceUuid) sync* {
    for (final p in _ports.values) {
      if (p._isAdvertising && p._advertisedServiceUuid == serviceUuid) {
        yield p;
      }
    }
  }

  FakeBlueyPort? lookup(NodeId nodeId) => _ports[nodeId];
}

class FakeBlueyPort implements BlueyPort {
  FakeBlueyPort({required this.localNodeId, required this.network}) {
    network.register(this);
  }

  final NodeId localNodeId;
  final FakeBlueyNetwork network;

  final StreamController<BlueyPortEvent> _events =
      StreamController<BlueyPortEvent>.broadcast();
  bool _isAdvertising = false;
  ServiceUuid? _advertisedServiceUuid;
  String? _advertisedDisplayName;
  final Set<NodeId> _connectedAsCentral = {};
  final Set<NodeId> _connectedAsPeripheral = {};

  /// Test hook: inject a connect failure for [target].
  bool Function(NodeId target)? connectFailureInjector;

  /// Test hook: latency added to discovery.
  Duration discoveryLatency = Duration.zero;

  @override
  Stream<BlueyPortEvent> get events => _events.stream;

  @override
  Future<void> startAdvertising({
    required ServiceUuid serviceUuid,
    required String displayName,
    required NodeId localNodeId,
  }) async {
    _isAdvertising = true;
    _advertisedServiceUuid = serviceUuid;
    _advertisedDisplayName = displayName;
  }

  @override
  Future<void> stopAdvertising() async {
    _isAdvertising = false;
  }

  @override
  Future<List<DiscoveredPeer>> discoverPeers({
    required ServiceUuid serviceUuid,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (discoveryLatency > Duration.zero) {
      await Future<void>.delayed(discoveryLatency);
    }
    return network
        .advertisingPeersFor(serviceUuid)
        .where((p) => p.localNodeId != localNodeId)
        .map((p) => DiscoveredPeer(nodeId: p.localNodeId))
        .toList();
  }

  @override
  Future<void> connect(NodeId target) async {
    if (connectFailureInjector?.call(target) ?? false) {
      _events.add(PortConnectFailed(
        nodeId: target,
        reason: 'test injected failure',
      ));
      throw StateError('connect failed for $target');
    }
    final remote = network.lookup(target);
    if (remote == null) {
      throw StateError('no fake port for $target');
    }
    _connectedAsCentral.add(target);
    remote._connectedAsPeripheral.add(localNodeId);
    _events.add(PortPeerConnected(
      nodeId: target,
      role: ConnectionRole.central,
      displayName: remote._advertisedDisplayName,
    ));
    remote._events.add(PortPeerConnected(
      nodeId: localNodeId,
      role: ConnectionRole.peripheral,
      displayName: _advertisedDisplayName,
    ));
  }

  @override
  Future<void> disconnect(NodeId nodeId) async {
    final remote = network.lookup(nodeId);
    final wasCentral = _connectedAsCentral.remove(nodeId);
    final wasPeripheral = _connectedAsPeripheral.remove(nodeId);
    if (!wasCentral && !wasPeripheral) return;
    _events.add(PortPeerDisconnected(nodeId: nodeId, reason: 'local request'));
    remote?._connectedAsCentral.remove(localNodeId);
    remote?._connectedAsPeripheral.remove(localNodeId);
    remote?._events.add(
      PortPeerDisconnected(nodeId: localNodeId, reason: 'peer disconnected'),
    );
  }

  @override
  Future<void> sendData(NodeId nodeId, Uint8List data) async {
    final remote = network.lookup(nodeId);
    if (remote == null ||
        (!_connectedAsCentral.contains(nodeId) &&
            !_connectedAsPeripheral.contains(nodeId))) {
      throw StateError('no connection to $nodeId');
    }
    remote._events.add(PortPeerData(nodeId: localNodeId, data: data));
  }

  @override
  Future<void> dispose() async {
    network.unregister(localNodeId);
    await _events.close();
  }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `dart analyze`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add packages/gossip_bluey/test/fakes/fake_bluey_port.dart
git commit -m "test(gossip_bluey): add FakeBlueyPort + FakeBlueyNetwork shared fixture"
```

---

## Phase 5: ConnectionService (the orchestrator)

`ConnectionService` is the largest component. We build it up one behavior at a time, with each task adding one capability and one or two tests. Constructor signature stays stable from Task 15 onward; later tasks add fields without changing it.

### Task 15: ConnectionService skeleton — accepts inbound peers from port

**Files:**
- Create: `packages/gossip_bluey/lib/src/application/services/connection_service.dart`
- Create: `packages/gossip_bluey/test/application/services/connection_service_test.dart`

- [ ] **Step 1: Write the failing test**

> **Imports grow with the file.** This is the initial test file. Subsequent tasks (16, 17, 18, …) append `test(...)` blocks to the same `group`. When a later task references a symbol that isn't already imported (e.g. `FrameEncoder` in Task 17, `ConnectionLimitReachedError` in Task 20, `_ManualClock` and `Clock` in Task 24), add the corresponding `import` to the top of the file at that time. Don't try to anticipate every import up front.

```dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/application/observability/bluey_metrics.dart';
import 'package:gossip_bluey/src/application/services/connection_service.dart';
import 'package:gossip_bluey/src/domain/aggregates/connection_registry.dart';
import 'package:gossip_bluey/src/domain/events/connection_event.dart';
import 'package:gossip_bluey/src/domain/interfaces/bluey_port.dart';
import 'package:gossip_bluey/src/domain/value_objects/service_uuid.dart';
import '../../fakes/fake_bluey_port.dart';

void main() {
  group('ConnectionService', () {
    final localId = NodeId('11111111-1111-1111-1111-111111111111');
    final remoteId = NodeId('22222222-2222-2222-2222-222222222222');
    final serviceUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');

    test('emits PeerOpened on PortPeerConnected (peripheral role)', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      // Pretend the remote (we don't add it to network) has connected.
      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );
      final events = <ConnectionEvent>[];
      final sub = svc.events.listen(events.add);

      // Inject the event by simulating an inbound peripheral-role connection.
      // Since the FakePort emits these via connect(), we simulate by adding
      // an entry to the network and calling connect() from the remote side.
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);
      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Local',
        localNodeId: localId,
      );
      await remotePort.connect(localId);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.first, isA<PeerOpened>());
      expect((events.first as PeerOpened).nodeId, equals(remoteId));

      await sub.cancel();
      await svc.dispose();
      await remotePort.dispose();
    });
  });
}
```

- [ ] **Step 2: Run, expect fail**

Expected: FAIL — `ConnectionService` does not exist.

- [ ] **Step 3: Implement minimal `ConnectionService`**

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

import '../../domain/aggregates/connection_registry.dart';
import '../../domain/entities/connection_handle.dart';
import '../../domain/errors/connection_error.dart';
import '../../domain/events/connection_event.dart';
import '../../domain/interfaces/bluey_port.dart';
import '../../domain/value_objects/service_uuid.dart';
import '../../infrastructure/codec/frame_codec.dart';
import '../../infrastructure/ports/bluey_message_port.dart';
import '../observability/bluey_metrics.dart';

class ConnectionService implements MessageDispatcher {
  ConnectionService({
    required this.localNodeId,
    required this.port,
    required this.registry,
    required this.metrics,
    required this.serviceUuid,
    this.maxConnections,
    int? targetConnections,
    this.onLog,
    bool Function(NodeId)? discoveryFilter,
    Clock? clock,
  })  : targetConnections = targetConnections ?? maxConnections,
        _discoveryFilter = discoveryFilter,
        _clock = clock ?? const Clock() {
    _portSub = port.events.listen(_onPortEvent);
  }

  final NodeId localNodeId;
  final BlueyPort port;
  final ConnectionRegistry registry;
  final BlueyMetrics metrics;
  final ServiceUuid serviceUuid;
  final int? maxConnections;
  final int? targetConnections;
  final LogCallback? onLog;
  bool Function(NodeId)? _discoveryFilter;
  final Clock _clock;

  late final StreamSubscription<BlueyPortEvent> _portSub;
  final StreamController<ConnectionEvent> _events =
      StreamController<ConnectionEvent>.broadcast();
  final StreamController<ConnectionError> _errors =
      StreamController<ConnectionError>.broadcast();
  final StreamController<IncomingMessage> _incoming =
      StreamController<IncomingMessage>.broadcast();
  final Map<NodeId, FrameDecoder> _decoders = {};

  Stream<ConnectionEvent> get events => _events.stream;
  Stream<ConnectionError> get errors => _errors.stream;

  @override
  Stream<IncomingMessage> get incomingMessages => _incoming.stream;

  void _onPortEvent(BlueyPortEvent event) {
    switch (event) {
      case PortPeerConnected(:final nodeId, :final role, :final displayName):
        final handle = ConnectionHandle(
          nodeId: nodeId,
          role: role,
          displayName: displayName,
          connectedAt: _clock.now(),
        );
        registry.add(handle);
        _decoders[nodeId] = FrameDecoder();
        metrics.recordConnectionEstablished();
        metrics.setConnectedPeerCount(registry.connectionCount);
        _events.add(PeerOpened(nodeId: nodeId, displayName: displayName));
      case PortPeerDisconnected():
        // handled in a later task
        break;
      case PortPeerData():
        // handled in a later task
        break;
      case PortConnectFailed():
        // handled in a later task
        break;
    }
  }

  @override
  Future<void> sendGossipMessage(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  }) async {
    // Filled in later task.
    throw UnimplementedError();
  }

  @override
  int pendingSendCount(NodeId peer) => 0;

  @override
  int get totalPendingSendCount => 0;

  @override
  Future<void> close() async => dispose();

  Future<void> dispose() async {
    await _portSub.cancel();
    await _events.close();
    await _errors.close();
    await _incoming.close();
  }
}

/// Trivial clock seam for tests.
class Clock {
  const Clock();
  DateTime now() => DateTime.now();
}
```

- [ ] **Step 4: Run, expect pass; analyze, expect clean**

- [ ] **Step 5: Commit**

```bash
git add packages/gossip_bluey/lib/src/application/services packages/gossip_bluey/test/application/services
git commit -m "feat(gossip_bluey): ConnectionService accepts inbound peers and emits PeerOpened"
```

---

### Task 16: PeerClosed on PortPeerDisconnected

- [ ] **Step 1: Append a failing test**

```dart
    test('emits PeerClosed on PortPeerDisconnected', () async {
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
      await remotePort.connect(localId);
      await Future<void>.delayed(Duration.zero);
      final events = <ConnectionEvent>[];
      final sub = svc.events.listen(events.add);

      await remotePort.disconnect(localId);
      await Future<void>.delayed(Duration.zero);

      final closed = events.whereType<PeerClosed>().toList();
      expect(closed, hasLength(1));
      expect(closed.first.nodeId, equals(remoteId));
      expect(svc.registry.connectionCount, equals(0));

      await sub.cancel();
      await svc.dispose();
      await remotePort.dispose();
    });
```

(Note: the test references `svc.registry.connectionCount`. Add a `registry` getter to `ConnectionService` if not already public.)

- [ ] **Step 2: Run, expect fail**

The disconnect path is currently a no-op in `_onPortEvent`.

- [ ] **Step 3: Implement disconnection handling**

In `_onPortEvent`, replace the `PortPeerDisconnected` branch with:

```dart
      case PortPeerDisconnected(:final nodeId, :final reason):
        final removed = registry.remove(nodeId);
        _decoders.remove(nodeId);
        metrics.setConnectedPeerCount(registry.connectionCount);
        if (removed != null) {
          _events.add(PeerClosed(nodeId: nodeId, reason: reason));
        }
```

Also expose the registry as a getter:

```dart
  ConnectionRegistry get registryView => registry;  // already public via field
```

(The test will compile if `registry` is `final ConnectionRegistry registry;`. Make it public.)

- [ ] **Step 4: Run, expect pass; analyze, expect clean**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(gossip_bluey): ConnectionService emits PeerClosed on disconnect"
```

---

### Task 17: Receive path — incoming bytes are decoded and surfaced

- [ ] **Step 1: Append a failing test**

```dart
    test('PortPeerData feeds the FrameDecoder and emits IncomingMessage', () async {
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
      await remotePort.connect(localId);
      await Future<void>.delayed(Duration.zero);

      final received = <IncomingMessage>[];
      final sub = svc.incomingMessages.listen(received.add);

      // Encode a payload at the wire layer and inject as if remote sent it.
      final payload = Uint8List.fromList([10, 20, 30]);
      final chunks = FrameEncoder.encode(payload, mtuPayloadSize: 100);
      for (final c in chunks) {
        await remotePort.sendData(localId, c);
      }
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(received.first.sender, equals(remoteId));
      expect(received.first.bytes, equals(payload));

      await sub.cancel();
      await svc.dispose();
      await remotePort.dispose();
    });
```

(`FrameEncoder` import already present in test or add: `import 'package:gossip_bluey/src/infrastructure/codec/frame_codec.dart';`.)

- [ ] **Step 2: Run, expect fail**

The `PortPeerData` branch is a no-op.

- [ ] **Step 3: Implement the receive path**

Replace the `PortPeerData` branch in `_onPortEvent`:

```dart
      case PortPeerData(:final nodeId, :final data):
        final decoder = _decoders[nodeId];
        if (decoder == null) {
          // Data from a peer we don't know about — ignore.
          return;
        }
        metrics.recordFrameReceived();
        metrics.recordBytesReceived(data.length);
        try {
          final messages = decoder.feed(data);
          for (final m in messages) {
            metrics.recordMessageReceived();
            _incoming.add(IncomingMessage(
              sender: nodeId,
              bytes: m,
              receivedAt: _clock.now(),
            ));
          }
        } on FormatException catch (e) {
          _errors.add(FrameDecodeError(
            message: e.message,
            occurredAt: _clock.now(),
            nodeId: nodeId,
          ));
          // Tear down the connection on decode failure.
          unawaited(port.disconnect(nodeId));
        }
```

Add `import 'dart:async';` if not present (for `unawaited`).

- [ ] **Step 4: Run, expect pass; analyze, expect clean**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(gossip_bluey): ConnectionService decodes incoming frames into IncomingMessage"
```

---

### Task 18: Send path — encode and write via port

- [ ] **Step 1: Append a failing test**

```dart
    test('sendGossipMessage encodes and writes chunks to the port', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);

      // Create both services BEFORE the connect call so neither subscribes
      // to its port's broadcast stream after the PortPeerConnected event
      // has already fired.
      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );
      final remoteSvc = ConnectionService(
        localNodeId: remoteId,
        port: remotePort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );

      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Local',
        localNodeId: localId,
      );
      await remotePort.connect(localId);
      await Future<void>.delayed(Duration.zero);

      final received = <IncomingMessage>[];
      final sub = remoteSvc.incomingMessages.listen(received.add);

      final payload = Uint8List.fromList(List.generate(50, (i) => i));
      await svc.sendGossipMessage(remoteId, payload);
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(received.first.bytes, equals(payload));

      await sub.cancel();
      await svc.dispose();
      await remoteSvc.dispose();
      await remotePort.dispose();
    });
```

- [ ] **Step 2: Run, expect fail**

`sendGossipMessage` currently throws.

- [ ] **Step 3: Implement send**

Replace the body of `sendGossipMessage`:

```dart
  @override
  Future<void> sendGossipMessage(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  }) async {
    if (!registry.contains(destination)) {
      _errors.add(ConnectionNotFoundError(
        message: 'no active connection to $destination',
        occurredAt: _clock.now(),
        nodeId: destination,
      ));
      return;
    }
    final chunks = FrameEncoder.encode(bytes, mtuPayloadSize: _effectiveMtu);
    for (final chunk in chunks) {
      try {
        await port.sendData(destination, chunk);
        metrics.recordFrameSent();
        metrics.recordBytesSent(chunk.length);
      } catch (e, st) {
        _errors.add(SendFailedError(
          message: 'send failed to $destination',
          occurredAt: _clock.now(),
          nodeId: destination,
          cause: e,
        ));
        onLog?.call(LogLevel.warning, 'send failed', e, st);
        unawaited(port.disconnect(destination));
        return;
      }
    }
    metrics.recordMessageSent();
  }

  /// Effective per-chunk MTU. Conservative default of 20 bytes (default
  /// BLE MTU 23 minus 3-byte ATT header). Real port impl can override.
  int get _effectiveMtu => 20;
```

(Note: `_effectiveMtu` is conservatively hardcoded for v1; real MTU lookup can be added in a follow-up.)

- [ ] **Step 4: Run, expect pass; analyze, expect clean**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(gossip_bluey): ConnectionService encodes and sends gossip messages"
```

---

### Task 19: Discovery loop, tie-break, and connect

The discovery loop runs in a `Timer.periodic` once `start()` is called. Each tick calls `port.discoverPeers`, applies the tie-break and discovery filter, and initiates connect for eligible peers.

- [ ] **Step 1: Append a failing test**

```dart
    test('discovery initiates connect to peers with greater NodeId', () async {
      final network = FakeBlueyNetwork();
      // localId < remoteId, so local should initiate.
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remotePort = FakeBlueyPort(localNodeId: remoteId, network: network);
      await remotePort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Remote',
        localNodeId: remoteId,
      );
      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Local',
        localNodeId: localId,
      );

      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );
      final events = <ConnectionEvent>[];
      final sub = svc.events.listen(events.add);

      await svc.startDiscovery();
      await svc.runDiscoveryRoundForTest();   // synchronously trigger one round
      await Future<void>.delayed(Duration.zero);

      final opened = events.whereType<PeerOpened>().toList();
      expect(opened.map((e) => e.nodeId), contains(remoteId));

      await sub.cancel();
      await svc.dispose();
      await remotePort.dispose();
    });

    test('tie-break: peer with greater NodeId does not initiate', () async {
      final network = FakeBlueyNetwork();
      // remote will be local-side; we run service for remoteId (higher)
      final remoteAsLocal =
          FakeBlueyPort(localNodeId: remoteId, network: network);
      final localAsRemote =
          FakeBlueyPort(localNodeId: localId, network: network);
      await localAsRemote.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Local',
        localNodeId: localId,
      );
      await remoteAsLocal.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Remote',
        localNodeId: remoteId,
      );

      final svc = ConnectionService(
        localNodeId: remoteId,
        port: remoteAsLocal,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );
      final events = <ConnectionEvent>[];
      final sub = svc.events.listen(events.add);

      await svc.startDiscovery();
      await svc.runDiscoveryRoundForTest();
      await Future<void>.delayed(Duration.zero);

      final opened = events.whereType<PeerOpened>().toList();
      expect(opened, isEmpty);   // tie-break said don't initiate

      await sub.cancel();
      await svc.dispose();
      await localAsRemote.dispose();
    });
```

- [ ] **Step 2: Run, expect fail**

Methods don't exist yet.

- [ ] **Step 3: Implement startDiscovery, stopDiscovery, runDiscoveryRoundForTest, and the discovery loop**

Add to `ConnectionService`:

```dart
  bool _discoveryEnabled = false;
  Timer? _discoveryTimer;
  final Duration discoveryInterval;

  // ... (constructor accepts: Duration? discoveryInterval, default 5s)
```

Update the constructor signature and field initializers:

```dart
  ConnectionService({
    required this.localNodeId,
    required this.port,
    required this.registry,
    required this.metrics,
    required this.serviceUuid,
    this.maxConnections,
    int? targetConnections,
    this.onLog,
    bool Function(NodeId)? discoveryFilter,
    Clock? clock,
    Duration discoveryInterval = const Duration(seconds: 5),
  })  : targetConnections = targetConnections ?? maxConnections,
        _discoveryFilter = discoveryFilter,
        _clock = clock ?? const Clock(),
        discoveryInterval = discoveryInterval {
    _portSub = port.events.listen(_onPortEvent);
  }

  Future<void> startDiscovery({bool Function(NodeId)? filter}) async {
    if (filter != null) {
      _discoveryFilter = filter;
    }
    _discoveryEnabled = true;
    _scheduleDiscovery();
  }

  Future<void> stopDiscovery() async {
    _discoveryEnabled = false;
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
  }

  void _scheduleDiscovery() {
    _discoveryTimer?.cancel();
    if (!_discoveryEnabled) return;
    _discoveryTimer = Timer(discoveryInterval, () {
      _runDiscoveryRound();
      _scheduleDiscovery();
    });
  }

  /// Synchronously triggers one discovery round. Test-only.
  Future<void> runDiscoveryRoundForTest() => _runDiscoveryRound();

  Future<void> _runDiscoveryRound() async {
    if (!_discoveryEnabled) return;
    final List<DiscoveredPeer> peers;
    try {
      peers = await port.discoverPeers(serviceUuid: serviceUuid);
    } catch (e, st) {
      onLog?.call(LogLevel.warning, 'discoverPeers failed', e, st);
      return;
    }
    for (final p in peers) {
      if (registry.contains(p.nodeId)) continue;
      if (_discoveryFilter != null && !_discoveryFilter!(p.nodeId)) continue;
      // Tie-break: only initiate if our nodeId < remote.
      if (localNodeId.value.compareTo(p.nodeId.value) >= 0) continue;
      try {
        await port.connect(p.nodeId);
      } catch (e, st) {
        onLog?.call(LogLevel.info, 'connect failed', e, st);
        // Backoff bookkeeping is a later task.
      }
    }
  }
```

Add `import '../../domain/value_objects/discovered_peer.dart';` if not present.

Also update `dispose` to cancel the timer:

```dart
  Future<void> dispose() async {
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    _discoveryEnabled = false;
    await _portSub.cancel();
    // ... existing closes
  }
```

- [ ] **Step 4: Run, expect pass; analyze, expect clean**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(gossip_bluey): discovery loop with NodeId-based tie-break"
```

---

### Task 20: maxConnections — initiator and responder enforcement

- [ ] **Step 1: Append two failing tests**

```dart
    test('initiator skips connect when at maxConnections', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final remoteId2 = NodeId('33333333-3333-3333-3333-333333333333');
      final remoteId3 = NodeId('44444444-4444-4444-4444-444444444444');
      final r2 = FakeBlueyPort(localNodeId: remoteId2, network: network);
      final r3 = FakeBlueyPort(localNodeId: remoteId3, network: network);
      await r2.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'r2',
        localNodeId: remoteId2,
      );
      await r3.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'r3',
        localNodeId: remoteId3,
      );
      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Local',
        localNodeId: localId,
      );

      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
        maxConnections: 1,
      );
      await svc.startDiscovery();
      await svc.runDiscoveryRoundForTest();
      await Future<void>.delayed(Duration.zero);

      expect(svc.registry.connectionCount, equals(1));

      await svc.dispose();
      await r2.dispose();
      await r3.dispose();
    });

    test('responder disconnects extra inbound past maxConnections', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final r2 =
          FakeBlueyPort(localNodeId: NodeId('33333333-3333-3333-3333-333333333333'), network: network);
      final r3 =
          FakeBlueyPort(localNodeId: NodeId('44444444-4444-4444-4444-444444444444'), network: network);

      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
        maxConnections: 1,
      );
      final errs = <ConnectionError>[];
      final sub = svc.errors.listen(errs.add);
      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Local',
        localNodeId: localId,
      );

      await r2.connect(localId);
      await Future<void>.delayed(Duration.zero);
      await r3.connect(localId);
      await Future<void>.delayed(Duration.zero);

      expect(svc.registry.connectionCount, equals(1));
      expect(
        errs.whereType<ConnectionLimitReachedError>(),
        isNotEmpty,
      );

      await sub.cancel();
      await svc.dispose();
      await r2.dispose();
      await r3.dispose();
    });
```

- [ ] **Step 2: Run, expect fail**

- [ ] **Step 3: Implement enforcement**

In `_runDiscoveryRound`, before `port.connect(p.nodeId)`:

```dart
      if (maxConnections != null &&
          registry.connectionCount >= maxConnections!) {
        return;
      }
```

In `_onPortEvent`, modify the `PortPeerConnected` case to reject above `maxConnections`:

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
        // ... existing behavior
```

- [ ] **Step 4: Run, expect pass; analyze, expect clean**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(gossip_bluey): enforce maxConnections on initiator and responder"
```

---

### Task 21: targetConnections — soft cap on initiation

- [ ] **Step 1: Append failing test**

```dart
    test('initiator stops at targetConnections but accepts more inbound', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final r2id = NodeId('33333333-3333-3333-3333-333333333333');
      final r3id = NodeId('44444444-4444-4444-4444-444444444444');
      final r2 = FakeBlueyPort(localNodeId: r2id, network: network);
      final r3 = FakeBlueyPort(localNodeId: r3id, network: network);
      await r2.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'r2',
        localNodeId: r2id,
      );
      await r3.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'r3',
        localNodeId: r3id,
      );
      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'Local',
        localNodeId: localId,
      );

      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
        maxConnections: 2,
        targetConnections: 1,
      );
      await svc.startDiscovery();
      await svc.runDiscoveryRoundForTest();
      await Future<void>.delayed(Duration.zero);

      // Soft cap: only one initiated.
      expect(svc.registry.connectionCount, equals(1));

      // Inbound still accepted up to maxConnections.
      // (find which one we already connected to, then connect from the other.)
      final connectedTo = svc.registry.connections.first.nodeId;
      final remaining = connectedTo == r2id ? r3 : r2;
      await remaining.connect(localId);
      await Future<void>.delayed(Duration.zero);

      expect(svc.registry.connectionCount, equals(2));

      await svc.dispose();
      await r2.dispose();
      await r3.dispose();
    });
```

- [ ] **Step 2: Run, expect fail**

- [ ] **Step 3: Implement soft cap**

In `_runDiscoveryRound`, replace the maxConnections check with the target check:

```dart
      if (targetConnections != null &&
          registry.connectionCount >= targetConnections!) {
        return;
      }
```

(Leave the `maxConnections` check in `PortPeerConnected` for the responder side — that's the hard cap.)

- [ ] **Step 4: Run, expect pass; analyze, expect clean**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(gossip_bluey): targetConnections soft-caps initiation independent of maxConnections"
```

---

### Task 22: Adaptive discovery (pause when at target)

- [ ] **Step 1: Append failing test**

```dart
    test('does not run discovery rounds while at targetConnections', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final r2id = NodeId('33333333-3333-3333-3333-333333333333');
      final r2 = FakeBlueyPort(localNodeId: r2id, network: network);
      await r2.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'r2',
        localNodeId: r2id,
      );

      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
        maxConnections: 1,
      );
      await svc.startDiscovery();
      await svc.runDiscoveryRoundForTest();   // round 1: connects to r2
      await Future<void>.delayed(Duration.zero);
      expect(svc.registry.connectionCount, equals(1));

      // Inject a counter into the fake to verify discoverPeers is NOT called now.
      var calls = 0;
      localPort.onDiscoverPeers = (svc) => calls++;
      await svc.runDiscoveryRoundForTest();
      expect(calls, equals(0));

      await svc.dispose();
      await r2.dispose();
    });
```

**Fixture extension:** before running this test, add a counter hook to `FakeBlueyPort`. In `test/fakes/fake_bluey_port.dart`:

1. Add a field at the top of the class: `void Function(BlueyPort port)? onDiscoverPeers;`
2. In `discoverPeers`, as the first line of the method body, call `onDiscoverPeers?.call(this);`

- [ ] **Step 2: Run, expect fail**

- [ ] **Step 3: Add adaptive gate to `_runDiscoveryRound`**

```dart
  Future<void> _runDiscoveryRound() async {
    if (!_discoveryEnabled) return;
    if (targetConnections != null &&
        registry.connectionCount >= targetConnections!) {
      return;
    }
    // ... existing body
  }
```

(That's actually already in place from Task 21's check. Move it to be the first thing inside `_runDiscoveryRound`, before `port.discoverPeers` is called.)

Update `FakeBlueyPort.discoverPeers` to call the optional `onDiscoverPeers` hook.

- [ ] **Step 4: Run, expect pass; analyze, expect clean**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(gossip_bluey): adaptive discovery pauses scan when at targetConnections"
```

---

### Task 23: Discovery filter

The filter was already wired in Task 19. This task adds a dedicated test to lock it in.

- [ ] **Step 1: Append failing test**

```dart
    test('discovery filter rejects peers that do not match', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final r2id = NodeId('33333333-3333-3333-3333-333333333333');
      final r3id = NodeId('44444444-4444-4444-4444-444444444444');
      final r2 = FakeBlueyPort(localNodeId: r2id, network: network);
      final r3 = FakeBlueyPort(localNodeId: r3id, network: network);
      await r2.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'r2',
        localNodeId: r2id,
      );
      await r3.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'r3',
        localNodeId: r3id,
      );

      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );
      await svc.startDiscovery(filter: (id) => id == r3id);
      await svc.runDiscoveryRoundForTest();
      await Future<void>.delayed(Duration.zero);

      expect(svc.registry.connectionCount, equals(1));
      expect(svc.registry.contains(r3id), isTrue);
      expect(svc.registry.contains(r2id), isFalse);

      await svc.dispose();
      await r2.dispose();
      await r3.dispose();
    });
```

- [ ] **Step 2: Run, expect pass**

(The behavior already works from Task 19. This is a regression-lock test.)

- [ ] **Step 3: Run, analyze**

- [ ] **Step 4: Commit**

```bash
git commit -am "test(gossip_bluey): lock in discovery filter behavior"
```

---

### Task 24: Connection backoff per NodeId

- [ ] **Step 1: Append failing tests**

```dart
    test('skips reconnect within backoff window after a connect failure', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final r2id = NodeId('33333333-3333-3333-3333-333333333333');
      final r2 = FakeBlueyPort(localNodeId: r2id, network: network);
      await r2.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'r2',
        localNodeId: r2id,
      );
      localPort.connectFailureInjector = (_) => true;

      final fakeClock = _ManualClock(DateTime(2026, 5, 4));
      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
        clock: fakeClock,
      );
      await svc.startDiscovery();
      await svc.runDiscoveryRoundForTest();   // fails, sets backoff
      await Future<void>.delayed(Duration.zero);
      expect(svc.registry.connectionCount, equals(0));

      // Within backoff window (1s) — discovery should skip the peer.
      fakeClock.advance(const Duration(milliseconds: 500));
      await svc.runDiscoveryRoundForTest();
      // No connect attempt happened (FakePort would have thrown again,
      // but we'd also see another error). We assert via metrics.
      expect(svc.registry.connectionCount, equals(0));

      // After backoff expires, discovery retries.
      localPort.connectFailureInjector = null;
      fakeClock.advance(const Duration(seconds: 2));
      await svc.runDiscoveryRoundForTest();
      await Future<void>.delayed(Duration.zero);
      expect(svc.registry.connectionCount, equals(1));

      await svc.dispose();
      await r2.dispose();
    });
```

(Add a `_ManualClock` helper at the top of the test file: `class _ManualClock extends Clock { _ManualClock(this._now); DateTime _now; @override DateTime now() => _now; void advance(Duration d) => _now = _now.add(d); }`.)

- [ ] **Step 2: Run, expect fail**

- [ ] **Step 3: Implement backoff**

Add to `ConnectionService`:

```dart
  static const _initialBackoff = Duration(seconds: 1);
  static const _maxBackoff = Duration(seconds: 30);
  final Map<NodeId, ({Duration delay, DateTime nextAttempt})> _backoff = {};
```

In `_runDiscoveryRound`, before `port.connect(p.nodeId)`:

```dart
      final entry = _backoff[p.nodeId];
      if (entry != null && _clock.now().isBefore(entry.nextAttempt)) {
        continue;
      }
```

In the catch block of `port.connect`:

```dart
      } catch (e, st) {
        final prev = _backoff[p.nodeId]?.delay ?? Duration.zero;
        final next = prev == Duration.zero
            ? _initialBackoff
            : Duration(milliseconds: (prev.inMilliseconds * 2)
                .clamp(_initialBackoff.inMilliseconds, _maxBackoff.inMilliseconds));
        _backoff[p.nodeId] = (
          delay: next,
          nextAttempt: _clock.now().add(next),
        );
        metrics.recordConnectionFailed();
        _errors.add(ConnectFailedError(
          message: 'connect to ${p.nodeId} failed',
          occurredAt: _clock.now(),
          nodeId: p.nodeId,
          cause: e,
        ));
        onLog?.call(LogLevel.info, 'connect failed', e, st);
      }
```

In `_onPortEvent` `PortPeerConnected` (after success), clear backoff:

```dart
        _backoff.remove(nodeId);
```

In `dispose`, clear the map:

```dart
    _backoff.clear();
```

- [ ] **Step 4: Run, expect pass; analyze, expect clean**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(gossip_bluey): per-NodeId exponential backoff on connect failure"
```

---

### Task 25: disconnectAll

- [ ] **Step 1: Append failing test**

```dart
    test('disconnectAll calls port.disconnect for every active peer', () async {
      final network = FakeBlueyNetwork();
      final localPort = FakeBlueyPort(localNodeId: localId, network: network);
      final r2id = NodeId('33333333-3333-3333-3333-333333333333');
      final r2 = FakeBlueyPort(localNodeId: r2id, network: network);
      await localPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'L',
        localNodeId: localId,
      );
      final svc = ConnectionService(
        localNodeId: localId,
        port: localPort,
        registry: ConnectionRegistry(),
        metrics: BlueyMetrics(),
        serviceUuid: serviceUuid,
      );
      await r2.connect(localId);
      await Future<void>.delayed(Duration.zero);
      expect(svc.registry.connectionCount, equals(1));

      await svc.disconnectAll();
      await Future<void>.delayed(Duration.zero);

      expect(svc.registry.connectionCount, equals(0));

      await svc.dispose();
      await r2.dispose();
    });
```

- [ ] **Step 2: Run, expect fail**

- [ ] **Step 3: Implement**

```dart
  Future<void> disconnectAll() async {
    final ids = registry.connections.map((h) => h.nodeId).toList();
    for (final id in ids) {
      try {
        await port.disconnect(id);
      } catch (e, st) {
        onLog?.call(LogLevel.warning, 'disconnect failed for $id', e, st);
      }
    }
  }
```

- [ ] **Step 4: Run, expect pass; analyze, expect clean**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(gossip_bluey): ConnectionService.disconnectAll"
```

---

## Phase 6: Facade and infrastructure adapter

### Task 26: BlueyTransport facade — create + lifecycle

**Files:**
- Create: `packages/gossip_bluey/lib/src/facade/bluey_transport.dart`
- Create: `packages/gossip_bluey/test/facade/bluey_transport_test.dart`

- [ ] **Step 1: Write failing tests**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/facade/bluey_transport.dart';
import 'package:gossip_bluey/src/domain/value_objects/service_uuid.dart';
import '../fakes/fake_bluey_port.dart';

void main() {
  group('BlueyTransport', () {
    final localId = NodeId('11111111-1111-1111-1111-111111111111');
    final serviceUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');

    test('create rejects a non-UUID NodeId', () async {
      final repo = InMemoryLocalNodeRepository(nodeId: NodeId('not-a-uuid'));
      expect(
        () => BlueyTransport.create(
          localNodeRepository: repo,
          serviceUuid: serviceUuid,
          displayName: 'phone',
        ),
        throwsArgumentError,
      );
    });

    test('startAdvertising / stopAdvertising flip isAdvertising', () async {
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      final transport = BlueyTransport.testing(
        localNodeId: localId,
        serviceUuid: serviceUuid,
        displayName: 'phone',
        port: port,
      );
      expect(transport.isAdvertising, isFalse);
      await transport.startAdvertising();
      expect(transport.isAdvertising, isTrue);
      await transport.stopAdvertising();
      expect(transport.isAdvertising, isFalse);
      await transport.dispose();
    });

    test('peerEvents fires PeerConnected/PeerDisconnected', () async {
      final remoteId = NodeId('22222222-2222-2222-2222-222222222222');
      final network = FakeBlueyNetwork();
      final port = FakeBlueyPort(localNodeId: localId, network: network);
      final remote = FakeBlueyPort(localNodeId: remoteId, network: network);
      final transport = BlueyTransport.testing(
        localNodeId: localId,
        serviceUuid: serviceUuid,
        displayName: 'phone',
        port: port,
      );
      await transport.startAdvertising();
      final events = <PeerEvent>[];
      final sub = transport.peerEvents.listen(events.add);

      await remote.connect(localId);
      await Future<void>.delayed(Duration.zero);
      await remote.disconnect(localId);
      await Future<void>.delayed(Duration.zero);

      expect(events.whereType<PeerConnected>().map((e) => e.nodeId), contains(remoteId));
      expect(events.whereType<PeerDisconnected>().map((e) => e.nodeId), contains(remoteId));

      await sub.cancel();
      await transport.dispose();
      await remote.dispose();
    });
  });
}
```

- [ ] **Step 2: Run, expect fail**

- [ ] **Step 3: Implement `BlueyTransport`**

```dart
import 'dart:async';

import 'package:gossip/gossip.dart';

import '../application/observability/bluey_metrics.dart';
import '../application/services/connection_service.dart';
import '../domain/aggregates/connection_registry.dart';
import '../domain/errors/connection_error.dart';
import '../domain/events/connection_event.dart';
import '../domain/interfaces/bluey_port.dart';
import '../domain/value_objects/service_uuid.dart';
import '../infrastructure/ports/bluey_message_port.dart';

sealed class PeerEvent {
  const PeerEvent();
}

final class PeerConnected extends PeerEvent {
  final NodeId nodeId;
  final String? displayName;
  const PeerConnected(this.nodeId, {this.displayName});
}

final class PeerDisconnected extends PeerEvent {
  final NodeId nodeId;
  const PeerDisconnected(this.nodeId);
}

class BlueyTransport {
  BlueyTransport._({
    required this.localNodeId,
    required ServiceUuid serviceUuid,
    required String displayName,
    required BlueyPort port,
    required ConnectionService service,
    required BlueyMessagePort messagePort,
    LogCallback? onLog,
  })  : _serviceUuid = serviceUuid,
        _displayName = displayName,
        _port = port,
        _service = service,
        _messagePort = messagePort,
        _onLog = onLog {
    _eventSub = service.events.listen(_onEvent);
  }

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  static Future<BlueyTransport> create({
    required LocalNodeRepository localNodeRepository,
    required ServiceUuid serviceUuid,
    required String displayName,
    int? maxConnections,
    int? targetConnections,
    LogCallback? onLog,
  }) async {
    final nodeId = await localNodeRepository.resolveNodeId();
    if (!_uuidPattern.hasMatch(nodeId.value.toLowerCase())) {
      throw ArgumentError.value(
        nodeId.value,
        'localNodeId',
        'gossip_bluey requires NodeId to be a well-formed UUID',
      );
    }
    // Real adapter binding lives in Task 28; for now this throws.
    throw UnimplementedError(
      'create() requires BlueyPortImpl, added in Phase 6',
    );
  }

  /// Test-only constructor that wires a [BlueyPort] directly.
  factory BlueyTransport.testing({
    required NodeId localNodeId,
    required ServiceUuid serviceUuid,
    required String displayName,
    required BlueyPort port,
    int? maxConnections,
    int? targetConnections,
    LogCallback? onLog,
  }) {
    final registry = ConnectionRegistry();
    final metrics = BlueyMetrics();
    final service = ConnectionService(
      localNodeId: localNodeId,
      port: port,
      registry: registry,
      metrics: metrics,
      serviceUuid: serviceUuid,
      maxConnections: maxConnections,
      targetConnections: targetConnections,
      onLog: onLog,
    );
    final mp = BlueyMessagePort(service);
    return BlueyTransport._(
      localNodeId: localNodeId,
      serviceUuid: serviceUuid,
      displayName: displayName,
      port: port,
      service: service,
      messagePort: mp,
      onLog: onLog,
    );
  }

  final NodeId localNodeId;
  final ServiceUuid _serviceUuid;
  final String _displayName;
  final BlueyPort _port;
  final ConnectionService _service;
  final BlueyMessagePort _messagePort;
  final LogCallback? _onLog;

  late final StreamSubscription<ConnectionEvent> _eventSub;
  final StreamController<PeerEvent> _peers =
      StreamController<PeerEvent>.broadcast();

  bool _isAdvertising = false;
  bool _isDiscovering = false;

  bool get isAdvertising => _isAdvertising;
  bool get isDiscovering => _isDiscovering;
  MessagePort get messagePort => _messagePort;
  Stream<PeerEvent> get peerEvents => _peers.stream;
  Stream<ConnectionError> get errors => _service.errors;
  Set<NodeId> get connectedPeers =>
      _service.registry.connections.map((h) => h.nodeId).toSet();
  int get connectedPeerCount => _service.registry.connectionCount;
  BlueyMetrics get metrics => _service.metrics;

  Future<void> startAdvertising() async {
    if (_isAdvertising) return;
    await _port.startAdvertising(
      serviceUuid: _serviceUuid,
      displayName: _displayName,
      localNodeId: localNodeId,
    );
    _isAdvertising = true;
  }

  Future<void> stopAdvertising() async {
    if (!_isAdvertising) return;
    await _port.stopAdvertising();
    _isAdvertising = false;
  }

  Future<void> startDiscovery({bool Function(NodeId)? filter}) async {
    await _service.startDiscovery(filter: filter);
    _isDiscovering = true;
  }

  Future<void> stopDiscovery() async {
    await _service.stopDiscovery();
    _isDiscovering = false;
  }

  Future<void> disconnectAll() => _service.disconnectAll();

  Future<void> dispose() async {
    await _eventSub.cancel();
    await _peers.close();
    await _service.dispose();
    await _port.dispose();
  }

  void _onEvent(ConnectionEvent event) {
    switch (event) {
      case PeerOpened(:final nodeId, :final displayName):
        _peers.add(PeerConnected(nodeId, displayName: displayName));
      case PeerClosed(:final nodeId):
        _peers.add(PeerDisconnected(nodeId));
    }
  }
}
```

- [ ] **Step 4: Run, expect pass; analyze, expect clean**

- [ ] **Step 5: Commit**

```bash
git add packages/gossip_bluey/lib/src/facade packages/gossip_bluey/test/facade
git commit -m "feat(gossip_bluey): BlueyTransport facade with create/start/stop/dispose"
```

---

### Task 27: Public exports

**Files:**
- Modify: `packages/gossip_bluey/lib/gossip_bluey.dart`

- [ ] **Step 1: Replace placeholder with full export list**

```dart
/// BLE transport for gossip, built on the bluey library.
library;

// Facade
export 'src/facade/bluey_transport.dart'
    show BlueyTransport, PeerEvent, PeerConnected, PeerDisconnected;

// Domain value objects
export 'src/domain/value_objects/service_uuid.dart' show ServiceUuid;

// Domain events
export 'src/domain/events/connection_event.dart'
    show ConnectionEvent, PeerOpened, PeerClosed;

// Domain errors
export 'src/domain/errors/connection_error.dart'
    show
        ConnectionError,
        ConnectionErrorType,
        ConnectionNotFoundError,
        ConnectionLostError,
        ConnectFailedError,
        SendFailedError,
        ConnectionLimitReachedError,
        FrameDecodeError;

// Observability
export 'src/application/observability/log_level.dart' show LogLevel, LogCallback;
export 'src/application/observability/bluey_metrics.dart' show BlueyMetrics;
```

- [ ] **Step 2: Verify analyzer**

Run: `dart analyze`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git commit -am "feat(gossip_bluey): public exports"
```

---

### Task 28: BlueyPortImpl — wraps real Bluey instance

This is the only task that touches real `bluey` types. Glue layer between bluey's API (surveyed in detail in the spec process) and our `BlueyPort` abstraction.

**Verify the bluey API first.** Before writing code, open these files in the local bluey checkout (or via `gh api`) and confirm signatures match the code below. The bluey package is unpublished and may have evolved.

- `bluey/lib/bluey.dart` (public exports)
- `bluey/lib/src/bluey.dart` (`Bluey.server(...)`, `discoverPeers(...)`, `peer(...)`, `connect(...)`)
- `bluey/lib/src/gatt_server/server.dart` (`Server`, `HostedService`, `HostedCharacteristic`, `CharacteristicProperties`, `writeRequests`, `notifyTo`, `peerConnections`, `disconnections`)
- `bluey/lib/src/peer/peer_connection.dart` (`PeerConnection.connection`, `services()`)
- `bluey/lib/src/gatt_client/gatt.dart` (`RemoteService`, `RemoteCharacteristic`, `notifications`, `write`)
- `bluey/lib/src/peer/peer_client.dart` (`PeerClient.serverId`, `PeerClient.id`)

If a signature differs (e.g. `HostedCharacteristic(uuid: ..., properties: ...)` is `HostedCharacteristic.readable(...)` in the real API), adapt the code below to match the real API. Do not invent methods. If the real API doesn't expose something this plan needs (e.g. `Server.disconnect(client)`), fall back to a graceful no-op + log a warning rather than calling fictional methods.

**Files:**
- Create: `packages/gossip_bluey/lib/src/infrastructure/adapters/gossip_gatt_service.dart`
- Create: `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart`

- [ ] **Step 1: Implement `gossip_gatt_service.dart`**

```dart
import 'package:bluey/bluey.dart';

import '../../domain/value_objects/gossip_characteristic_uuids.dart';
import '../../domain/value_objects/service_uuid.dart';

/// Builds the [HostedService] that registers the gossip data
/// characteristic with bluey's GATT server.
class GossipGattService {
  static HostedService build(ServiceUuid serviceUuid) {
    final uuids = GossipCharacteristicUuids.derive(serviceUuid);
    return HostedService(
      uuid: UUID(serviceUuid.value),
      characteristics: [
        HostedCharacteristic(
          uuid: UUID(uuids.dataCharacteristic),
          properties: const CharacteristicProperties(
            writeWithoutResponse: true,
            notify: true,
          ),
        ),
      ],
    );
  }
}
```

- [ ] **Step 2: Implement `bluey_port_impl.dart` — top of file, fields, constructor**

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:bluey/bluey.dart' as bluey;
import 'package:gossip/gossip.dart';

import '../../domain/interfaces/bluey_port.dart';
import '../../domain/value_objects/discovered_peer.dart';
import '../../domain/value_objects/gossip_characteristic_uuids.dart';
import '../../domain/value_objects/service_uuid.dart';
import 'gossip_gatt_service.dart';

class BlueyPortImpl implements BlueyPort {
  BlueyPortImpl({bluey.Bluey? blueyInstance})
      : _bluey = blueyInstance ?? bluey.Bluey.shared;

  final bluey.Bluey _bluey;
  bluey.Server? _server;
  ServiceUuid? _serviceUuid;
  String? _localNodeIdValue;

  /// Central-role connections — we initiated, peer is the GATT server.
  final Map<NodeId, bluey.PeerConnection> _centralConnections = {};
  final Map<NodeId, StreamSubscription<Uint8List>> _centralNotifSubs = {};

  /// Peripheral-role clients — they initiated, we are the GATT server.
  final Map<NodeId, bluey.PeerClient> _peripheralClients = {};

  final StreamController<BlueyPortEvent> _events =
      StreamController<BlueyPortEvent>.broadcast();
  final List<StreamSubscription<dynamic>> _serverSubs = [];

  @override
  Stream<BlueyPortEvent> get events => _events.stream;
}
```

- [ ] **Step 3: Implement `startAdvertising`**

```dart
  @override
  Future<void> startAdvertising({
    required ServiceUuid serviceUuid,
    required String displayName,
    required NodeId localNodeId,
  }) async {
    _serviceUuid = serviceUuid;
    _localNodeIdValue = localNodeId.value;
    final server = _bluey.server(
      identity: bluey.ServerId(localNodeId.value),
    );
    if (server == null) {
      throw StateError(
        'peripheral role not supported on this platform — '
        'gossip_bluey requires both central and peripheral roles',
      );
    }
    _server = server;
    await server.addService(GossipGattService.build(serviceUuid));

    final charUuid = GossipCharacteristicUuids.derive(serviceUuid)
        .dataCharacteristic;

    _serverSubs.add(server.peerConnections.listen((peerClient) {
      final nodeId = NodeId(peerClient.serverId.value);
      _peripheralClients[nodeId] = peerClient;
      _events.add(PortPeerConnected(
        nodeId: nodeId,
        role: ConnectionRole.peripheral,
      ));
    }));

    _serverSubs.add(server.disconnections.listen((clientId) {
      // Server.disconnections emits the bluey client id (string). Find the
      // matching NodeId entry — `PeerClient.id` is a UUID exposed by bluey.
      NodeId? matchedNodeId;
      for (final entry in _peripheralClients.entries) {
        if (entry.value.id.toString() == clientId) {
          matchedNodeId = entry.key;
          break;
        }
      }
      if (matchedNodeId != null) {
        _peripheralClients.remove(matchedNodeId);
        _events.add(PortPeerDisconnected(
          nodeId: matchedNodeId,
          reason: 'peer disconnected',
        ));
      }
    }));

    _serverSubs.add(server.writeRequests.listen((req) {
      if (req.characteristicUuid.toString().toLowerCase() != charUuid) {
        return;
      }
      final senderNodeId = NodeId(req.client.serverId.value);
      _events.add(PortPeerData(nodeId: senderNodeId, data: req.value));
      if (req.responseNeeded) {
        unawaited(server.respondToWrite(
          req,
          status: bluey.GattResponseStatus.success,
        ));
      }
    }));

    await server.startAdvertising(
      name: displayName,
      services: [bluey.UUID(serviceUuid.value)],
      peerDiscoverable: true,
    );
  }
```

- [ ] **Step 4: Implement `stopAdvertising`, `discoverPeers`**

```dart
  @override
  Future<void> stopAdvertising() async {
    await _server?.stopAdvertising();
  }

  @override
  Future<List<DiscoveredPeer>> discoverPeers({
    required ServiceUuid serviceUuid,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final peers = await _bluey.discoverPeers(timeout: timeout);
    final out = <DiscoveredPeer>[];
    for (final p in peers) {
      final nodeId = NodeId(p.serverId.value);
      // Skip ourselves — bluey may surface our own server in its scan.
      if (nodeId.value == _localNodeIdValue) continue;
      out.add(DiscoveredPeer(nodeId: nodeId));
    }
    return out;
  }
```

- [ ] **Step 5: Implement `connect`**

```dart
  @override
  Future<void> connect(NodeId target) async {
    final serviceUuid = _serviceUuid;
    if (serviceUuid == null) {
      throw StateError('connect requires startAdvertising to have been called first '
          '(serviceUuid not set)');
    }
    final blueyPeer = _bluey.peer(bluey.ServerId(target.value));
    final peerConnection = await blueyPeer.connect();
    _centralConnections[target] = peerConnection;

    // Subscribe to notifications on the gossip characteristic.
    final charUuid = GossipCharacteristicUuids.derive(serviceUuid)
        .dataCharacteristic;
    final services = await peerConnection.services();
    final gossipService = services.firstWhere(
      (s) => s.uuid.toString().toLowerCase() == serviceUuid.value,
      orElse: () => throw StateError(
        'connected peer $target does not host the gossip service',
      ),
    );
    final dataChar = gossipService.characteristics().firstWhere(
      (c) => c.uuid.toString().toLowerCase() == charUuid,
      orElse: () => throw StateError(
        'connected peer $target does not host the gossip data characteristic',
      ),
    );
    final sub = dataChar.notifications.listen((bytes) {
      _events.add(PortPeerData(nodeId: target, data: bytes));
    });
    _centralNotifSubs[target] = sub;

    // Watch for connection drop and clean up.
    final raw = peerConnection.connection;
    raw.stateChanges.listen((state) {
      if (state == bluey.ConnectionState.disconnected &&
          _centralConnections.containsKey(target)) {
        _cleanupCentral(target, reason: 'connection dropped');
      }
    });

    _events.add(PortPeerConnected(
      nodeId: target,
      role: ConnectionRole.central,
    ));
  }

  void _cleanupCentral(NodeId target, {required String reason}) {
    _centralConnections.remove(target);
    final sub = _centralNotifSubs.remove(target);
    sub?.cancel();
    _events.add(PortPeerDisconnected(nodeId: target, reason: reason));
  }
```

- [ ] **Step 6: Implement `disconnect`, `sendData`, `dispose`**

```dart
  @override
  Future<void> disconnect(NodeId nodeId) async {
    final central = _centralConnections[nodeId];
    if (central != null) {
      try {
        await central.disconnect();
      } finally {
        _cleanupCentral(nodeId, reason: 'local request');
      }
      return;
    }
    final peripheral = _peripheralClients.remove(nodeId);
    if (peripheral != null) {
      // bluey.Server does not expose a per-client disconnect on every
      // platform. Best-effort: drop our local reference; the lifecycle
      // heartbeat will eventually surface the disconnect on both sides.
      _events.add(PortPeerDisconnected(
        nodeId: nodeId,
        reason: 'local request',
      ));
    }
  }

  @override
  Future<void> sendData(NodeId nodeId, Uint8List data) async {
    final serviceUuid = _serviceUuid;
    if (serviceUuid == null) {
      throw StateError('sendData requires startAdvertising to have been called first');
    }
    final charUuid = GossipCharacteristicUuids.derive(serviceUuid)
        .dataCharacteristic;

    final central = _centralConnections[nodeId];
    if (central != null) {
      final services = await central.services(cache: true);
      final gossipService = services.firstWhere(
        (s) => s.uuid.toString().toLowerCase() == serviceUuid.value,
        orElse: () => throw StateError('gossip service missing on $nodeId'),
      );
      final dataChar = gossipService.characteristics().firstWhere(
        (c) => c.uuid.toString().toLowerCase() == charUuid,
        orElse: () =>
            throw StateError('gossip data characteristic missing on $nodeId'),
      );
      await dataChar.write(data, withResponse: false);
      return;
    }

    final peripheralClient = _peripheralClients[nodeId];
    if (peripheralClient != null) {
      final server = _server;
      if (server == null) {
        throw StateError('no server — startAdvertising not called?');
      }
      await server.notifyTo(
        peripheralClient,
        bluey.UUID(charUuid),
        data: data,
      );
      return;
    }

    throw StateError('no connection to $nodeId');
  }

  @override
  Future<void> dispose() async {
    for (final s in _serverSubs) {
      await s.cancel();
    }
    _serverSubs.clear();
    for (final s in _centralNotifSubs.values) {
      await s.cancel();
    }
    _centralNotifSubs.clear();
    for (final c in _centralConnections.values) {
      try {
        await c.disconnect();
      } catch (_) {/* best-effort */}
    }
    _centralConnections.clear();
    _peripheralClients.clear();
    await _server?.dispose();
    _server = null;
    await _events.close();
  }
```

- [ ] **Step 7: Run analyzer**

Run: `cd packages/gossip_bluey && dart analyze`

If issues are reported, they typically mean the bluey API differs from the surveyed signatures. Read the actual bluey file the analyzer points at, find the real method/field, and update the code accordingly. The structure of this adapter — the field map, the event flow, the per-method responsibilities — should not change; only the leaf calls need adjusting.

- [ ] **Step 8: Wire `BlueyPortImpl` into `BlueyTransport.create`**

Open `lib/src/facade/bluey_transport.dart`. Replace the `throw UnimplementedError` body of `BlueyTransport.create` with:

```dart
    final port = BlueyPortImpl();
    final registry = ConnectionRegistry();
    final metrics = BlueyMetrics();
    final service = ConnectionService(
      localNodeId: nodeId,
      port: port,
      registry: registry,
      metrics: metrics,
      serviceUuid: serviceUuid,
      maxConnections: maxConnections,
      targetConnections: targetConnections,
      onLog: onLog,
    );
    return BlueyTransport._(
      localNodeId: nodeId,
      serviceUuid: serviceUuid,
      displayName: displayName,
      port: port,
      service: service,
      messagePort: BlueyMessagePort(service),
      onLog: onLog,
    );
```

Add the corresponding import: `import '../infrastructure/adapters/bluey_port_impl.dart';`

- [ ] **Step 9: Run analyzer once more, expect clean**

- [ ] **Step 10: Commit**

```bash
git add packages/gossip_bluey/lib/src/infrastructure/adapters packages/gossip_bluey/lib/src/facade/bluey_transport.dart
git commit -m "feat(gossip_bluey): BlueyPortImpl wraps the real Bluey instance"
```

---

## Phase 7: Integration tests

### Task 29: Two-node mesh sync

**Files:**
- Create: `packages/gossip_bluey/test/integration/mesh_two_node_test.dart`
- Create: `packages/gossip_bluey/test/integration/_coordinator_helpers.dart`

- [ ] **Step 1: Create the coordinator helper**

`test/integration/_coordinator_helpers.dart`:

```dart
import 'package:gossip/gossip.dart';

/// Builds a [Coordinator] backed by in-memory repositories, wired to the
/// supplied [messagePort]. Used by all integration tests in this package.
Future<Coordinator> spawnCoordinator({
  required NodeId nodeId,
  required MessagePort messagePort,
}) async {
  return Coordinator.create(
    localNodeRepository: InMemoryLocalNodeRepository(nodeId: nodeId),
    channelRepository: InMemoryChannelRepository(),
    peerRepository: InMemoryPeerRepository(),
    entryRepository: InMemoryEntryRepository(),
    messagePort: messagePort,
  );
}

/// Polls [predicate] every [interval] until it returns true or [timeout]
/// elapses. Throws [TimeoutException] if the deadline is missed.
Future<void> waitFor(
  Future<bool> Function() predicate, {
  Duration interval = const Duration(milliseconds: 50),
  Duration timeout = const Duration(seconds: 5),
  String? what,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) return;
    await Future<void>.delayed(interval);
  }
  throw TimeoutException(
    'waitFor(${what ?? 'condition'}) timed out after ${timeout.inSeconds}s',
  );
}
```

- [ ] **Step 2: Write the failing test**

`test/integration/mesh_two_node_test.dart`:

```dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/gossip_bluey.dart';
import 'package:gossip_bluey/src/facade/bluey_transport.dart';

import '../fakes/fake_bluey_port.dart';
import '_coordinator_helpers.dart';

void main() {
  test('two-node mesh converges on a shared channel', () async {
    final network = FakeBlueyNetwork();
    final idA = NodeId('11111111-1111-1111-1111-111111111111');
    final idB = NodeId('22222222-2222-2222-2222-222222222222');
    final serviceUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');

    final portA = FakeBlueyPort(localNodeId: idA, network: network);
    final portB = FakeBlueyPort(localNodeId: idB, network: network);

    final transportA = BlueyTransport.testing(
      localNodeId: idA,
      serviceUuid: serviceUuid,
      displayName: 'A',
      port: portA,
    );
    final transportB = BlueyTransport.testing(
      localNodeId: idB,
      serviceUuid: serviceUuid,
      displayName: 'B',
      port: portB,
    );

    final coordA = await spawnCoordinator(
      nodeId: idA,
      messagePort: transportA.messagePort,
    );
    final coordB = await spawnCoordinator(
      nodeId: idB,
      messagePort: transportB.messagePort,
    );

    await transportA.startAdvertising();
    await transportB.startAdvertising();
    await transportA.startDiscovery();
    await transportB.startDiscovery();

    // Trigger discovery on A (the lower NodeId, so it initiates).
    await transportA.serviceForTest.runDiscoveryRoundForTest();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(transportA.connectedPeerCount, equals(1));
    expect(transportB.connectedPeerCount, equals(1));

    // Wire gossip-level peer membership.
    await coordA.addPeer(idB);
    await coordB.addPeer(idA);

    // Create a shared channel and stream.
    final channelId = ChannelId('demo');
    final streamId = StreamId('messages');
    await coordA.createChannel(channelId);
    await coordB.createChannel(channelId);

    // Append an entry on A; expect it to converge on B.
    final payload = Uint8List.fromList([1, 2, 3]);
    await coordA.append(channelId, streamId, payload);

    await waitFor(
      () async {
        final entries = await coordB.entries(channelId, streamId);
        return entries.length == 1;
      },
      what: 'entry to converge to B',
      timeout: const Duration(seconds: 5),
    );

    final entriesB = await coordB.entries(channelId, streamId);
    expect(entriesB.first.payload, equals(payload));

    await transportA.dispose();
    await transportB.dispose();
    await coordA.dispose();
    await coordB.dispose();
  });
}
```

> **Note on `transportA.serviceForTest`:** Add `ConnectionService get serviceForTest => _service;` to `BlueyTransport` (visibleForTesting) so integration tests can drive a discovery round synchronously. Alternative: lower `discoveryInterval` and rely on the timer; explicit triggering is more deterministic.

> **Note on `coordA.entries(...)`:** Verify this is the correct API by reading `packages/gossip/lib/src/facade/coordinator.dart`. If the method is named differently (e.g. `getEntries`, `streamEntries`, or a channel-facade-level call), update the test accordingly. Same goes for `append(channelId, streamId, payload)` — the gossip coordinator API is stable but the exact method names should be confirmed against the source.

- [ ] **Step 3: Run, expect fail**

Run: `dart test test/integration/mesh_two_node_test.dart`
Expected: fails — either compilation (if `serviceForTest` not yet exposed) or assertion (if convergence times out).

- [ ] **Step 4: Add `serviceForTest` to `BlueyTransport`**

In `lib/src/facade/bluey_transport.dart`:

```dart
import 'package:meta/meta.dart';
// ...
  @visibleForTesting
  ConnectionService get serviceForTest => _service;
```

- [ ] **Step 5: Run, expect pass**

Run: `dart test test/integration/mesh_two_node_test.dart`
Expected: pass within 5 seconds.

If convergence is unreliable, add an `await coordA.runGossipRound()` (or equivalent) call in the test after `append`. Inspect the gossip Coordinator API for the right method to flush a gossip round.

- [ ] **Step 6: Run analyzer, commit**

```bash
dart analyze
git add packages/gossip_bluey/test/integration packages/gossip_bluey/lib/src/facade/bluey_transport.dart
git commit -m "test(gossip_bluey): two-node mesh integration test"
```

---

### Task 30: Three-node star

**Files:**
- Create: `packages/gossip_bluey/test/integration/star_three_node_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/gossip_bluey.dart';
import 'package:gossip_bluey/src/facade/bluey_transport.dart';

import '../fakes/fake_bluey_port.dart';
import '_coordinator_helpers.dart';

void main() {
  test('three-node star: spokes converge through hub', () async {
    final network = FakeBlueyNetwork();
    final hubId = NodeId('99999999-9999-9999-9999-999999999999');   // greatest
    final spokeAId = NodeId('11111111-1111-1111-1111-111111111111');
    final spokeBId = NodeId('22222222-2222-2222-2222-222222222222');
    final serviceUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');

    final hubPort = FakeBlueyPort(localNodeId: hubId, network: network);
    final aPort = FakeBlueyPort(localNodeId: spokeAId, network: network);
    final bPort = FakeBlueyPort(localNodeId: spokeBId, network: network);

    // Hub advertises only.
    final hub = BlueyTransport.testing(
      localNodeId: hubId,
      serviceUuid: serviceUuid,
      displayName: 'Hub',
      port: hubPort,
      maxConnections: 7,
    );
    // Spokes discover only, pinned to hub.
    final spokeA = BlueyTransport.testing(
      localNodeId: spokeAId,
      serviceUuid: serviceUuid,
      displayName: 'Spoke-A',
      port: aPort,
      maxConnections: 1,
      targetConnections: 1,
    );
    final spokeB = BlueyTransport.testing(
      localNodeId: spokeBId,
      serviceUuid: serviceUuid,
      displayName: 'Spoke-B',
      port: bPort,
      maxConnections: 1,
      targetConnections: 1,
    );

    final hubCoord = await spawnCoordinator(
      nodeId: hubId,
      messagePort: hub.messagePort,
    );
    final aCoord = await spawnCoordinator(
      nodeId: spokeAId,
      messagePort: spokeA.messagePort,
    );
    final bCoord = await spawnCoordinator(
      nodeId: spokeBId,
      messagePort: spokeB.messagePort,
    );

    await hub.startAdvertising();
    // Note: spokes do NOT call startAdvertising.
    await spokeA.startDiscovery(filter: (id) => id == hubId);
    await spokeB.startDiscovery(filter: (id) => id == hubId);

    await spokeA.serviceForTest.runDiscoveryRoundForTest();
    await spokeB.serviceForTest.runDiscoveryRoundForTest();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(hub.connectedPeerCount, equals(2));
    expect(spokeA.connectedPeerCount, equals(1));
    expect(spokeB.connectedPeerCount, equals(1));

    // Gossip-level peer wiring: spokes only know hub; hub knows both.
    await aCoord.addPeer(hubId);
    await bCoord.addPeer(hubId);
    await hubCoord.addPeer(spokeAId);
    await hubCoord.addPeer(spokeBId);

    final channelId = ChannelId('star');
    final streamId = StreamId('msg');
    await hubCoord.createChannel(channelId);
    await aCoord.createChannel(channelId);
    await bCoord.createChannel(channelId);

    final payload = Uint8List.fromList([42, 43, 44]);
    await aCoord.append(channelId, streamId, payload);

    await waitFor(
      () async => (await bCoord.entries(channelId, streamId)).length == 1,
      what: 'entry from A to converge to B via hub',
      timeout: const Duration(seconds: 8),
    );

    final entriesOnB = await bCoord.entries(channelId, streamId);
    expect(entriesOnB.first.payload, equals(payload));

    await hub.dispose();
    await spokeA.dispose();
    await spokeB.dispose();
    await hubCoord.dispose();
    await aCoord.dispose();
    await bCoord.dispose();
  });
}
```

- [ ] **Step 2: Run, expect fail (initially) / pass (once everything is wired)**

Run: `dart test test/integration/star_three_node_test.dart`
Expected: pass within 8 seconds.

- [ ] **Step 3: Run analyzer, commit**

```bash
dart analyze
git add packages/gossip_bluey/test/integration/star_three_node_test.dart
git commit -m "test(gossip_bluey): three-node star integration test"
```

---

### Task 31: Capacity behavior integration test

**Files:**
- Create: `packages/gossip_bluey/test/integration/capacity_behavior_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/gossip_bluey.dart';
import 'package:gossip_bluey/src/facade/bluey_transport.dart';
import 'package:gossip_bluey/src/domain/errors/connection_error.dart';

import '../fakes/fake_bluey_port.dart';

void main() {
  group('capacity behavior', () {
    final serviceUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');
    final aId = NodeId('11111111-1111-1111-1111-111111111111');
    final bId = NodeId('22222222-2222-2222-2222-222222222222');
    final cId = NodeId('33333333-3333-3333-3333-333333333333');
    final dId = NodeId('44444444-4444-4444-4444-444444444444');

    test('maxConnections rejects extra incoming, targetConnections allows fewer initiations', () async {
      final network = FakeBlueyNetwork();
      final aPort = FakeBlueyPort(localNodeId: aId, network: network);
      final bPort = FakeBlueyPort(localNodeId: bId, network: network);
      final cPort = FakeBlueyPort(localNodeId: cId, network: network);
      final dPort = FakeBlueyPort(localNodeId: dId, network: network);

      final transportA = BlueyTransport.testing(
        localNodeId: aId,
        serviceUuid: serviceUuid,
        displayName: 'A',
        port: aPort,
        maxConnections: 2,
        targetConnections: 1,
      );
      // Other peers advertise so A can see them in discovery.
      await bPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'B',
        localNodeId: bId,
      );
      await cPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'C',
        localNodeId: cId,
      );
      await dPort.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: 'D',
        localNodeId: dId,
      );
      await transportA.startAdvertising();
      await transportA.startDiscovery();

      final errors = <ConnectionError>[];
      transportA.errors.listen(errors.add);

      // 1) Discovery round: A initiates only one connection (targetConnections=1).
      await transportA.serviceForTest.runDiscoveryRoundForTest();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(transportA.connectedPeerCount, equals(1));

      // 2) C connects inbound — A is below maxConnections=2 so it's accepted.
      await cPort.connect(aId);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(transportA.connectedPeerCount, equals(2));

      // 3) D connects inbound — A is at maxConnections=2 so it's rejected.
      await dPort.connect(aId);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(transportA.connectedPeerCount, equals(2));   // still 2
      expect(
        errors.whereType<ConnectionLimitReachedError>(),
        isNotEmpty,
      );

      // 4) Disconnect one — A's discovery resumes (targetConnections=1
      //    is back to satisfied... actually wait, we'd be at 1, target is
      //    1, so no new initiations expected).
      final firstConnectedNodeId =
          transportA.connectedPeers.firstWhere((id) => id != cId);
      // Disconnect the discovered peer — A drops to 1 connected.
      // (cPort still connected, count stays >= 1.)
      // Use disconnectAll then verify discovery doesn't blow past target.
      await transportA.disconnectAll();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(transportA.connectedPeerCount, equals(0));

      // After disconnecting, discovery resumes; A should reach
      // targetConnections=1 again on the next round.
      await transportA.serviceForTest.runDiscoveryRoundForTest();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(transportA.connectedPeerCount, equals(1));

      await transportA.dispose();
      await bPort.dispose();
      await cPort.dispose();
      await dPort.dispose();
    });
  });
}
```

- [ ] **Step 2: Run, expect pass**

Run: `dart test test/integration/capacity_behavior_test.dart`
Expected: pass within a few seconds.

- [ ] **Step 3: Run analyzer, commit**

```bash
dart analyze
git add packages/gossip_bluey/test/integration/capacity_behavior_test.dart
git commit -m "test(gossip_bluey): capacity-behavior integration test"
```

---

## Phase 8: Migration — remove gossip_ble

### Task 32: Verify gossip_bluey ships green standalone

- [ ] **Step 1: Run the full test suite for gossip_bluey**

```
cd packages/gossip_bluey && dart test
```

Expected: all green.

- [ ] **Step 2: Run analyzer**

```
cd packages/gossip_bluey && dart analyze
```

Expected: clean.

- [ ] **Step 3: Run melos workspace-wide**

```
cd ../.. && melos run test
melos run analyze
```

Expected: all green (apart from any pre-existing `gossip_ble` issues, which we're about to remove).

- [ ] **Step 4: No commit needed; this is a verification gate.**

If anything fails, stop and fix before proceeding.

---

### Task 33: Remove gossip_ble

**Files:**
- Delete: `packages/gossip_ble/` (entire directory)
- Modify: `melos.yaml` (remove `- packages/gossip_ble`)

- [ ] **Step 1: Remove the package**

```
git rm -r packages/gossip_ble
```

- [ ] **Step 2: Update `melos.yaml`**

Remove the `- packages/gossip_ble` line from the `workspace:` list.

- [ ] **Step 3: Re-bootstrap**

```
melos bootstrap
```

Expected: succeeds.

- [ ] **Step 4: Run full test suite**

```
melos run test
melos run analyze
```

Expected: all green; no references to `gossip_ble` remain.

- [ ] **Step 5: Search for any stale references**

Run: `git grep gossip_ble`
Expected: zero results outside of git history. Fix any found.

- [ ] **Step 6: Commit**

```
git add -A
git commit -m "chore: remove gossip_ble package, replaced by gossip_bluey"
```

---

### Task 34: Update root README

**Files:**
- Modify: `README.md` (root, if present) and any other docs that mention `gossip_ble`.

- [ ] **Step 1: Find references to gossip_ble in docs**

Run: `git grep -i gossip_ble -- '*.md' ':!docs/superpowers/'`

- [ ] **Step 2: Replace with `gossip_bluey` references**

Update package descriptions, install instructions, etc. Mention that `gossip_bluey` supports both Android and iOS via the bluey library.

- [ ] **Step 3: Run analyzer once more** — should still be clean.

- [ ] **Step 4: Commit**

```
git commit -am "docs: update package references from gossip_ble to gossip_bluey"
```

---

## Self-review checklist (run before declaring done)

- [ ] All `dart test` commands across the workspace pass.
- [ ] All `dart analyze` commands report `No issues found!`.
- [ ] `git grep gossip_ble` returns nothing outside git history.
- [ ] `git grep TODO\|FIXME\|XXX` in `packages/gossip_bluey/` returns nothing.
- [ ] The public exports in `lib/gossip_bluey.dart` match the spec's "Public API" section.
- [ ] Both topologies (mesh and star) have integration tests that pass.
- [ ] `BlueyTransport.create` validates the NodeId UUID format.
- [ ] `targetConnections`, `maxConnections`, adaptive discovery, discovery filter, and per-NodeId backoff all have test coverage.

---

## Spec ↔ plan coverage

| Spec section | Implemented by |
|---|---|
| Public API | Task 26 (facade), Task 27 (exports) |
| Identity model (`NodeId == ServerId`) | Task 26 (UUID validation), Task 28 (`bluey.server(identity:)`) |
| Layered structure | All Phase 1–6 tasks; the file layout table at the top of this plan locks it in. |
| `BlueyPort` interface | Task 10 |
| Connection lifecycle (server role) | Tasks 26 (advertising flag), 28 (real adapter) |
| Connection lifecycle (client role) | Task 19 (discovery + tie-break) |
| Tie-break and duplicate handling | Task 19 (tie-break), Task 12 (registry duplicate detection) |
| Disconnect | Tasks 16, 25 |
| `maxConnections` / `targetConnections` | Tasks 20, 21 |
| Adaptive discovery | Task 22 |
| Discovery filter | Tasks 19, 23 |
| Connection backoff | Task 24 |
| GATT structure | Task 28 (gossip_gatt_service.dart) |
| Framing | Tasks 8, 9 |
| Send/receive paths | Tasks 17, 18 |
| Errors | Task 5 (types), all later tasks (emission) |
| Topologies (mesh/star) | Tasks 29, 30 |
| Testing strategy | Phase 1–7 tests; Phase 7 integration |
| Migration | Tasks 33, 34 |
