# Gossip Sync Library — Architecture Documentation

**Version:** 1.0.0 (Implementation Status)  
**Last Updated:** 2026-01-27

A pure Dart library for synchronizing event streams across devices using gossip protocols. Designed for mobile-first, offline-capable applications with sub-second convergence.

> **Note:** This document reflects the **current implementation status**. For unimplemented components, see `ARCHITECTURE_DEVIATIONS.md`. The original v7 specification is archived at `architecture7_original.md`.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture Layers](#architecture-layers)
3. [Domain Layer](#domain-layer)
4. [Application Services Layer](#application-services-layer)
5. [Protocol Layer](#protocol-layer)
6. [Infrastructure Layer](#infrastructure-layer)
7. [Facade Layer](#facade-layer) ⚠️ *Not yet implemented*
8. [Threading Model](#threading-model)
9. [Error Handling](#error-handling)

---

## Overview

### Design Principles

- **Pure Domain**: Domain layer has no infrastructure dependencies, no `DateTime.now()`, no side effects
- **Strict DDD**: Clean separation of concerns across 5 architectural layers
- **Payload-agnostic**: Library syncs opaque bytes; application defines semantics
- **Transport-external**: Library defines `MessagePort` interface; application provides implementation
- **Discovery-external**: Library doesn't find peers; application tells library about peers
- **Memory-efficient**: Entry storage is separate from aggregate state
- **Single-isolate**: All operations run in one isolate; no internal synchronization needed
- **Observable**: Error emission via `ErrorCallback` pattern, domain events for state changes

### Target Constraints

- Up to 8 devices per channel (configurable)
- 32KB payload limit (Android Nearby Connections compatibility)
- Sub-second convergence (~150ms typical)
- Persistent streams with long history supported

---

## Architecture Layers

The library follows strict DDD with five layers:

```
┌─────────────────────────────────────────────────────────┐
│  Facade Layer (NOT YET IMPLEMENTED)                     │
│  - Coordinator (main entry point)                       │
│  - ChannelFacade (channel operations)                   │
│  - EventStreamFacade (stream read/write)                │
├─────────────────────────────────────────────────────────┤
│  Application Services Layer ✅ IMPLEMENTED              │
│  - ChannelService (coordinates Channel + persistence)   │
│  - PeerService (coordinates PeerRegistry + persistence) │
├─────────────────────────────────────────────────────────┤
│  Protocol Layer ✅ IMPLEMENTED                          │
│  - GossipEngine (anti-entropy sync)                     │
│  - FailureDetector (SWIM liveness detection)            │
│  - ProtocolCodec (message serialization)                │
│  - Protocol messages (Ping, Ack, Digest*, Delta*)       │
├─────────────────────────────────────────────────────────┤
│  Domain Layer ✅ IMPLEMENTED                            │
│  - Aggregates (PeerRegistry, Channel)                   │
│  - Entities (Peer, PeerMetrics, StreamConfig)           │
│  - Value Objects (NodeId, LogEntry, Hlc, etc.)          │
│  - Domain Events, Errors, Services                      │
│  - Repository/Store Interfaces                          │
├─────────────────────────────────────────────────────────┤
│  Infrastructure Layer ✅ IMPLEMENTED                    │
│  - InMemoryPeerRepository                               │
│  - InMemoryChannelRepository                            │
│  - InMemoryentryRepository                                   │
│  - InMemoryMessagePort, InMemoryTimePort               │
└─────────────────────────────────────────────────────────┘
```

---

## Domain Layer

**Location:** `lib/src/domain/`

Pure business logic with no external dependencies. All types are immutable or have controlled mutation through explicit methods.

### Aggregates

#### PeerRegistry

**File:** `lib/src/domain/aggregates/peer_registry.dart`

Manages the cluster of known peers with SWIM protocol state.

```dart
class PeerRegistry {
  final NodeId localNode;
  
  // Query
  bool isKnown(NodeId id);
  bool isReachable(NodeId id);
  Peer? getPeer(NodeId id);
  List<Peer> get allPeers;
  List<Peer> get reachablePeers;
  int get peerCount;
  int get localIncarnation;
  PeerMetrics? getMetrics(NodeId id);
  
  // Commands
  void addPeer(NodeId id, {required int nowMs, int? incarnation});
  void removePeer(NodeId id, {required DateTime occurredAt});
  void updatePeerStatus(NodeId id, PeerStatus status, {required DateTime occurredAt});
  void updatePeerContact(NodeId id, {required int nowMs});
  void updatePeerAntiEntropy(NodeId id, {required int nowMs});
  void updatePeerIncarnation(NodeId id, int incarnation, {required DateTime occurredAt});
  void incrementFailedProbeCount(NodeId id, {required DateTime occurredAt});
  void incrementLocalIncarnation({required DateTime occurredAt});
  
  // Metrics
  void recordMessageReceived(NodeId id, int bytes, {required int nowMs});
  void recordMessageSent(NodeId id, int bytes, {required int nowMs});
  
  // Events
  List<DomainEvent> get uncommittedEvents;
  void clearEvents();
}
```

**Emitted Events:**
- `PeerAdded(peerId)`
- `PeerRemoved(peerId)`
- `PeerStatusChanged(peerId, oldStatus, newStatus)`
- `PeerOperationSkipped(peerId, operation)` - when operation on unknown peer

#### Channel

**File:** `lib/src/domain/aggregates/channel.dart`

Manages channel membership and stream metadata (not entries themselves).

```dart
class Channel {
  final ChannelId id;
  final NodeId localNode;
  final StreamConfig streamConfig;
  
  // Query
  Set<NodeId> get memberIds;
  bool hasMember(NodeId id);
  Set<StreamId> get streamIds;
  bool hasStream(StreamId id);
  VersionVector getVersion(StreamId stream);
  int get streamCount;
  int get outOfOrderBufferSize;
  
  // Read (requires EntryStore)
  List<LogEntry> getEntries(StreamId stream, EntryStore store);
  int totalEntries(StreamId stream, EntryStore store);
  int totalSizeBytes(StreamId stream, EntryStore store);
  
  // Commands
  void addMember(NodeId member, {required DateTime occurredAt});
  void removeMember(NodeId member, {required DateTime occurredAt});
  void createStream(StreamId stream, {RetentionPolicy? retention, required DateTime occurredAt});
  
  // Entry operations (requires EntryStore)
  LogEntry appendEntry(StreamId stream, Uint8List payload, Hlc timestamp, EntryStore store);
  MergeResult mergeEntries(StreamId stream, List<LogEntry> entries, EntryStore store);
  CompactionResult compactStream(StreamId stream, Hlc now, EntryStore store);
  
  // Digests
  ChannelDigest computeDigest(EntryStore store);
  ChannelDelta? computeDelta(StreamId stream, VersionVector since, EntryStore store);
  
  // State materialization
  void registerMaterializer<T>(StreamId stream, StateMaterializer<T> materializer);
  T? getState<T>(StreamId stream, EntryStore store);
  
  // Events
  List<DomainEvent> get uncommittedEvents;
  void clearEvents();
}
```

**Emitted Events:**
- `MemberAdded(channelId, memberId)`
- `MemberRemoved(channelId, memberId)`
- `StreamCreated(channelId, streamId)`
- `EntryAppended(channelId, streamId, entry)`
- `EntriesMerged(channelId, streamId, entries, newVersion)`
- `StreamCompacted(channelId, streamId, result)`
- `BufferOverflowOccurred(channelId, streamId, author, droppedCount)`
- `NonMemberEntriesRejected(channelId, streamId, rejectedCount, unknownAuthors)`

### Entities

#### Peer

**File:** `lib/src/domain/entities/peer.dart`

Represents a remote node with liveness state.

```dart
class Peer {
  final NodeId id;
  final PeerStatus status;
  final int incarnation;
  final int lastContactMs;
  final int lastAntiEntropyMs;
  final int failedProbeCount;
  final PeerMetrics metrics;
  
  Peer copyWith({...});
}

enum PeerStatus { reachable, suspected, unreachable }
```

#### PeerMetrics

**File:** `lib/src/domain/entities/peer_metrics.dart`

Communication metrics for a peer with sliding window.

```dart
class PeerMetrics {
  final int messagesReceived;
  final int messagesSent;
  final int bytesReceived;
  final int bytesSent;
  final int windowStartMs;
  final int messagesInWindow;
  
  PeerMetrics recordReceived(int bytes, {required int nowMs, int windowSizeMs = 10000});
  PeerMetrics recordSent(int bytes, {required int nowMs});
}
```

#### StreamConfig

**File:** `lib/src/domain/entities/stream_config.dart`

Configuration for out-of-order entry buffering.

```dart
class StreamConfig {
  final int maxBufferSizePerAuthor;
  final int maxTotalBufferEntries;
  
  static const defaults = StreamConfig(
    maxBufferSizePerAuthor: 100,
    maxTotalBufferEntries: 10000,
  );
}
```

### Value Objects

#### NodeId

**File:** `lib/src/domain/value_objects/node_id.dart`

Unique identifier for a device/peer.

```dart
class NodeId {
  final String value;
  const NodeId(this.value);
}
```

#### ChannelId

**File:** `lib/src/domain/value_objects/channel_id.dart`

Unique identifier for a sync channel.

```dart
class ChannelId {
  final String value;
  const ChannelId(this.value);
}
```

#### StreamId

**File:** `lib/src/domain/value_objects/stream_id.dart`

Identifier for a stream within a channel.

```dart
class StreamId {
  final String value;
  const StreamId(this.value);
}
```

#### LogEntry

**File:** `lib/src/domain/value_objects/log_entry.dart`

Atomic synchronization unit.

```dart
class LogEntry {
  final NodeId author;
  final int sequence;
  final Hlc timestamp;
  final Uint8List payload;
  
  LogEntryId get id;
  int get sizeBytes;
}

class LogEntryId {
  final NodeId author;
  final int sequence;
}
```

#### Hlc (Hybrid Logical Clock)

**File:** `lib/src/domain/value_objects/hlc.dart`

Causality-preserving timestamp.

```dart
class Hlc implements Comparable<Hlc> {
  final int physicalMs;  // 48-bit physical time
  final int logical;     // 16-bit logical counter
  
  static const zero = Hlc(0, 0);
  
  int compareTo(Hlc other);
  Hlc subtract(Duration duration);
}
```

#### VersionVector

**File:** `lib/src/domain/value_objects/version_vector.dart`

Tracks sync state per author.

```dart
class VersionVector {
  static const empty = VersionVector({});
  
  Map<NodeId, int> get entries;
  bool get isEmpty;
  
  VersionVector increment(NodeId author);
  VersionVector set(NodeId author, int sequence);
  VersionVector merge(VersionVector other);
  VersionVector diff(VersionVector other);
  bool dominates(VersionVector other);
}
```

### Domain Services

#### HlcClock

**File:** `lib/src/domain/services/hlc_clock.dart`

Generates monotonically increasing HLC timestamps.

```dart
class HlcClock {
  HlcClock(TimeSource timeSource);
  
  Hlc now();
  Hlc receive(Hlc remoteTimestamp);
}
```

#### TimeSource

**File:** `lib/src/domain/services/time_source.dart`

Abstract time source for testability.

```dart
abstract interface class TimeSource {
  int nowMs();
}

class SystemTimeSource implements TimeSource {
  int nowMs() => DateTime.now().millisecondsSinceEpoch;
}
```

### Domain Events

**File:** `lib/src/domain/events/domain_event.dart`

Sealed class hierarchy for aggregate state changes.

```dart
sealed class DomainEvent {
  final DateTime occurredAt;
  const DomainEvent({required this.occurredAt});
}

// Peer events
final class PeerAdded extends DomainEvent { ... }
final class PeerRemoved extends DomainEvent { ... }
final class PeerStatusChanged extends DomainEvent { ... }
final class PeerOperationSkipped extends DomainEvent { ... }

// Channel events
final class ChannelCreated extends DomainEvent { ... }
final class ChannelRemoved extends DomainEvent { ... }
final class MemberAdded extends DomainEvent { ... }
final class MemberRemoved extends DomainEvent { ... }
final class StreamCreated extends DomainEvent { ... }

// Entry events
final class EntryAppended extends DomainEvent { ... }
final class EntriesMerged extends DomainEvent { ... }
final class StreamCompacted extends DomainEvent { ... }

// Error events
final class BufferOverflowOccurred extends DomainEvent { ... }
final class NonMemberEntriesRejected extends DomainEvent { ... }
final class SyncErrorOccurred extends DomainEvent { ... }
```

### Domain Errors

**File:** `lib/src/domain/errors/sync_error.dart`

Sealed class hierarchy for non-fatal errors.

```dart
typedef ErrorCallback = void Function(SyncError error);

sealed class SyncError {
  final String message;
  final DateTime occurredAt;
  const SyncError(this.message, {required this.occurredAt});
}

final class PeerSyncError extends SyncError {
  final NodeId peer;
  final SyncErrorType type;
  final Object? cause;
}

final class ChannelSyncError extends SyncError {
  final ChannelId channel;
  final SyncErrorType type;
  final Object? cause;
}

final class StorageSyncError extends SyncError {
  final SyncErrorType type;
  final Object? cause;
}

final class TransformSyncError extends SyncError {
  final ChannelId channel;
  final Object? cause;
}

final class BufferOverflowError extends SyncError {
  final ChannelId channel;
  final StreamId stream;
  final NodeId author;
  final int bufferSize;
}

enum SyncErrorType {
  peerUnreachable,
  messageCorrupted,
  protocolError,
  storageFailure,
  transformFailed,
  bufferOverflow,
  channelNotFound,
  streamNotFound,
  entryStorageError,
  invalidIncarnation,
  unknownError,
}
```

**File:** `lib/src/domain/errors/domain_exception.dart`

For fatal domain invariant violations.

```dart
class DomainException implements Exception {
  final String message;
  const DomainException(this.message);
}
```

### Repository Interfaces

#### ChannelRepository

**File:** `lib/src/domain/interfaces/channel_repository.dart`

Persistence abstraction for Channel aggregates.

```dart
abstract interface class ChannelRepository {
  Future<Channel?> findById(ChannelId id);
  Future<void> save(Channel channel);
  Future<void> delete(ChannelId id);
  Future<List<ChannelId>> listIds();
  Future<bool> exists(ChannelId id);
  Future<int> get count;
}
```

#### PeerRepository

**File:** `lib/src/domain/interfaces/peer_repository.dart`

Persistence abstraction for Peer entities.

```dart
abstract interface class PeerRepository {
  Future<Peer?> findById(NodeId id);
  Future<void> save(Peer peer);
  Future<void> delete(NodeId id);
  Future<List<Peer>> findAll();
  Future<List<Peer>> findReachable();
  Future<bool> exists(NodeId id);
  Future<int> get count;
}
```

#### EntryStore

**File:** `lib/src/domain/interfaces/entry_store.dart`

Persistence abstraction for LogEntry instances (separate from aggregates).

```dart
abstract interface class EntryStore {
  // Write
  void append(ChannelId channel, StreamId stream, LogEntry entry);
  void appendAll(ChannelId channel, StreamId stream, List<LogEntry> entries);
  
  // Read
  List<LogEntry> getAll(ChannelId channel, StreamId stream);
  List<LogEntry> entriesSince(ChannelId channel, StreamId stream, VersionVector since);
  List<LogEntry> entriesForAuthorAfter(ChannelId channel, StreamId stream, NodeId author, int afterSequence);
  
  // Metadata
  int latestSequence(ChannelId channel, StreamId stream, NodeId author);
  int entryCount(ChannelId channel, StreamId stream);
  int sizeBytes(ChannelId channel, StreamId stream);
  VersionVector getVersionVector(ChannelId channel, StreamId stream);
  
  // Maintenance
  void removeEntries(ChannelId channel, StreamId stream, List<LogEntryId> ids);
  void clearStream(ChannelId channel, StreamId stream);
  void clearChannel(ChannelId channel);
}
```

### Policy Interfaces

#### RetentionPolicy

**File:** `lib/src/domain/interfaces/retention_policy.dart`

Strategy for determining which entries to keep during compaction.

```dart
abstract interface class RetentionPolicy {
  List<LogEntry> compact(List<LogEntry> entries, Hlc now);
}

// Built-in implementations
class KeepAllRetention implements RetentionPolicy { ... }
class TimeBasedRetention implements RetentionPolicy { 
  final Duration maxAge;
}
class CountBasedRetention implements RetentionPolicy {
  final int maxEntriesPerAuthor;
}
class CompositeRetention implements RetentionPolicy {
  final List<RetentionPolicy> policies;
}
```

#### StateMaterializer

**File:** `lib/src/domain/interfaces/state_materializer.dart`

Folds log entries into derived application state.

```dart
abstract interface class StateMaterializer<T> {
  T initial();
  T fold(T state, LogEntry entry);
}
```

### Result Types

#### MergeResult

**File:** `lib/src/domain/results/merge_result.dart`

Outcome of merging entries into a stream.

```dart
class MergeResult {
  final List<LogEntry> newEntries;
  final List<LogEntry> duplicates;
  final List<LogEntry> outOfOrder;
  final List<LogEntry> dropped;
  final List<LogEntry> rejected;
  final VersionVector newVersion;
  
  bool get hasNewEntries;
  bool get hasOutOfOrder;
  bool get hasDropped;
  bool get hasRejected;
  int get totalProcessed;
}
```

#### CompactionResult

**File:** `lib/src/domain/results/compaction_result.dart`

Outcome of compacting a stream.

```dart
class CompactionResult {
  final int entriesRemoved;
  final int entriesRetained;
  final int bytesFreed;
  final VersionVector oldBaseVersion;
  final VersionVector newBaseVersion;
}
```

#### Digest Types

**File:** `lib/src/domain/results/digest.dart`

Compact representation of stream/channel state for sync.

```dart
class StreamDigest {
  final VersionVector version;
}

class ChannelDigest {
  final ChannelId channelId;
  final Map<StreamId, StreamDigest> streams;
}

class BatchedDigest {
  final Map<ChannelId, ChannelDigest> channels;
  bool get isEmpty;
}
```

#### ChannelDelta

**File:** `lib/src/domain/results/channel_delta.dart`

Entries to transmit for a stream.

```dart
class ChannelDelta {
  final ChannelId channelId;
  final Map<StreamId, List<LogEntry>> entries;
  
  int get totalEntries;
  int get totalBytes;
}
```

---

## Application Services Layer

**Location:** `lib/src/application/services/`

Coordinates domain logic with persistence. Pattern: Load → Modify → Save.

### ChannelService

**File:** `lib/src/application/services/channel_service.dart`

Coordinates `Channel` aggregate with repositories and entry storage.

```dart
class ChannelService {
  ChannelService({
    ChannelRepository? repository,
    EntryStore? entryStore,
    HlcClock? clock,
    ErrorCallback? onError,
  });
  
  Future<Channel> createChannel(ChannelId id, NodeId localNode, {StreamConfig? config});
  Future<void> addMember(ChannelId channelId, NodeId memberId);
  Future<void> removeMember(ChannelId channelId, NodeId memberId);
  Future<void> createStream(ChannelId channelId, StreamId streamId, {RetentionPolicy? retention});
  Future<LogEntry> appendEntry(ChannelId channelId, StreamId streamId, Uint8List payload, NodeId author);
  Future<List<LogEntry>> getEntries(ChannelId channelId, StreamId streamId);
}
```

**Error Handling:** Emits `StorageSyncError` when repository/entryStore is null.

### PeerService

**File:** `lib/src/application/services/peer_service.dart`

Coordinates `PeerRegistry` aggregate with persistence.

```dart
class PeerService {
  PeerService({
    required PeerRegistry registry,
    PeerRepository? repository,
    ErrorCallback? onError,
  });
  
  void addPeer(NodeId id, {int? incarnation});
  void removePeer(NodeId id);
  void updatePeerStatus(NodeId id, PeerStatus status);
  void recordPeerContact(NodeId id);
  void recordPeerAntiEntropy(NodeId id);
  void updatePeerIncarnation(NodeId id, int incarnation);
  void recordMessageReceived(NodeId id, int bytes);
  void recordMessageSent(NodeId id, int bytes);
  int incrementLocalIncarnation();
  
  Peer? getPeer(NodeId id);
  List<Peer> get allPeers;
  List<Peer> get reachablePeers;
}
```

**Error Handling:** Emits `StorageSyncError` when repository is null during persistence.

---

## Protocol Layer

**Location:** `lib/src/protocol/`

Implements gossip and SWIM protocols.

### GossipEngine

**File:** `lib/src/protocol/gossip_engine.dart`

Anti-entropy synchronization via 4-step digest/delta exchange.

```dart
class GossipEngine {
  GossipEngine({
    required this.localNode,
    required this.channelService,
    required this.peerService,
    required this.messagePort,
    required this.timerPort,
    this.gossipIntervalMs = 500,
    this.onError,
  });
  
  void setChannels(Set<ChannelId> channels);
  void start();
  void startListening();
  void stop();
}
```

**Protocol:**
1. Select random reachable peer
2. Send `DigestRequest` with local digests
3. Receive `DigestResponse` with peer's digests
4. Send `DeltaRequest` for missing data
5. Receive `DeltaResponse` and merge entries

**Messages Handled:**
- `DigestRequest` → respond with `DigestResponse`
- `DeltaRequest` → respond with `DeltaResponse`
- `DigestResponse` → send `DeltaRequest` for diff
- `DeltaResponse` → merge entries

**Error Handling:**
- Unawaited async operations wrapped in `.catchError()`
- Message send failures emit `PeerSyncError` with `peerUnreachable` type
- Malformed messages emit `PeerSyncError` with `messageCorrupted` type
- Unknown channels emit `ChannelSyncError`

### FailureDetector

**File:** `lib/src/protocol/failure_detector.dart`

SWIM failure detection protocol.

```dart
class FailureDetector {
  FailureDetector({
    required this.localNode,
    required this.peerService,
    required this.messagePort,
    required this.timerPort,
    this.probeIntervalMs = 1000,
    this.failureThreshold = 3,
    this.onError,
  });
  
  void start();
  void startListening();
  void stop();
}
```

**Protocol:**
1. Select random reachable peer
2. Send `Ping`
3. If no `Ack` within timeout:
   - Select K random intermediaries
   - Send `PingReq` to intermediaries
   - If no `Ack` via any intermediary: increment failed probe count
4. After `failureThreshold` failures: mark peer as suspected

**Messages Handled:**
- `Ping` → respond with `Ack`
- `PingReq` → forward `Ping` to target, relay `Ack`
- `Ack` → update peer contact timestamp

**Error Handling:**
- Unawaited async operations wrapped in `.catchError()`
- Message send failures emit `PeerSyncError` via `_safeSend()` helper
- Malformed messages emit `PeerSyncError` with `messageCorrupted` type

### ProtocolCodec

**File:** `lib/src/protocol/protocol_codec.dart`

Serializes/deserializes protocol messages.

```dart
class ProtocolCodec {
  Uint8List encode(ProtocolMessage message);
  ProtocolMessage decode(Uint8List bytes);
}
```

**Wire Format:** `[type:1][json:N]`

**Type Mapping:**
- 0: `Ping`
- 1: `Ack`
- 2: `PingReq`
- 3: `DigestRequest`
- 4: `DigestResponse`
- 5: `DeltaRequest`
- 6: `DeltaResponse`

### Protocol Messages

**Location:** `lib/src/protocol/messages/`

```dart
sealed class ProtocolMessage {
  final NodeId sender;
}

// SWIM messages
final class Ping extends ProtocolMessage { ... }
final class Ack extends ProtocolMessage { ... }
final class PingReq extends ProtocolMessage {
  final NodeId target;
}

// Anti-entropy messages
final class DigestRequest extends ProtocolMessage {
  final BatchedDigest digests;
}

final class DigestResponse extends ProtocolMessage {
  final BatchedDigest digests;
}

final class DeltaRequest extends ProtocolMessage {
  final Map<ChannelId, Map<StreamId, VersionVector>> requests;
}

final class DeltaResponse extends ProtocolMessage {
  final List<ChannelDelta> deltas;
}
```

---

## Infrastructure Layer

**Location:** `lib/src/infrastructure/`

Concrete implementations of ports and repositories.

### Port Interfaces

#### MessagePort

**File:** `lib/src/infrastructure/ports/message_port.dart`

Network communication abstraction.

```dart
abstract interface class MessagePort {
  Future<void> send(NodeId destination, Uint8List bytes);
  Stream<IncomingMessage> get incoming;
  Future<void> close();
}

class IncomingMessage {
  final NodeId sender;
  final Uint8List bytes;
  final DateTime receivedAt;
}
```

#### TimePort

**File:** `lib/src/infrastructure/ports/timer_port.dart`

Scheduling abstraction.

```dart
abstract interface class TimePort {
  Timer schedulePeriodic(Duration interval, void Function() callback);
  void cancel(Timer timer);
}
```

### In-Memory Implementations

#### InMemoryPeerRepository

**File:** `lib/src/infrastructure/repositories/in_memory_peer_repository.dart`

In-memory storage for testing.

```dart
class InMemoryPeerRepository implements PeerRepository {
  // Map<NodeId, Peer> storage
}
```

#### InMemoryChannelRepository

**File:** `lib/src/infrastructure/repositories/in_memory_channel_repository.dart`

In-memory storage for testing.

```dart
class InMemoryChannelRepository implements ChannelRepository {
  // Map<ChannelId, Channel> storage
}
```

#### InMemoryEntryStore

**File:** `lib/src/infrastructure/stores/in_memory_entry_store.dart`

In-memory entry storage with optimizations.

```dart
class InMemoryEntryStore implements EntryStore {
  // Nested maps: channel → stream → List<LogEntry>
  // Entries sorted by HLC timestamp using binary search insertion
  // Maintains O(1) latestSequence lookup via _latestSequenceCache
}
```

**Optimizations:**
- Binary search insertion maintains HLC timestamp ordering
- `_latestSequenceCache` for O(1) `latestSequence()` and `getVersionVector()`

#### InMemoryMessagePort

**File:** `lib/src/infrastructure/ports/in_memory_message_port.dart`

In-memory message passing for testing.

```dart
class InMemoryMessagePort implements MessagePort {
  // Uses MessageBus for routing
}
```

#### InMemoryTimePort

**File:** `lib/src/infrastructure/ports/in_memory_timer_port.dart`

In-memory timer simulation for testing.

```dart
class InMemoryTimePort implements TimePort {
  // Wraps dart:async Timer
}
```

---

## Facade Layer

⚠️ **NOT YET IMPLEMENTED**

The public API layer that provides `Coordinator`, `ChannelFacade`, and `EventStreamFacade` is not yet implemented. See `ARCHITECTURE_DEVIATIONS.md` for details.

### Planned Components

- `Coordinator` - Main entry point for lifecycle, peers, channels
- `ChannelFacade` - Channel-level operations (membership, streams)
- `EventStreamFacade` - Stream-level read/write operations

---

## Threading Model

**IMPORTANT:** This library assumes single-isolate execution.

### Guarantees

1. All `Coordinator` operations must run in the same Dart isolate
2. No locks or synchronization primitives - Dart's event loop ensures atomicity
3. Async methods yield only at `await` points; internal state modifications are synchronous

### EntryStore Concurrency

If your `EntryStore` implementation is accessed from multiple isolates (e.g., shared SQLite database), the implementation must handle its own synchronization. The library calls `EntryStore` methods synchronously.

### Background Processing

If you need background processing:
1. Keep the `Coordinator` in the main isolate
2. Use message passing to communicate with background isolates
3. Or create separate `Coordinator` instances per isolate (they won't share state)

---

## Error Handling

### Non-Fatal Errors (ErrorCallback Pattern)

The library emits non-fatal errors via the `ErrorCallback` pattern instead of throwing exceptions:

```dart
typedef ErrorCallback = void Function(SyncError error);
```

**Where used:**
- `GossipEngine(onError: ...)` - Protocol errors, network failures
- `FailureDetector(onError: ...)` - Protocol errors, network failures
- `ChannelService(onError: ...)` - Storage configuration warnings
- `PeerService(onError: ...)` - Storage configuration warnings

**Error types:**
- `PeerSyncError` - Peer-related errors (unreachable, corrupted messages)
- `ChannelSyncError` - Channel-related errors (not found, protocol errors)
- `StorageSyncError` - Storage configuration issues
- `TransformSyncError` - Payload transformation failures
- `BufferOverflowError` - Out-of-order buffer overflow

### Fatal Errors (Exceptions)

`DomainException` is thrown for invariant violations that indicate programming errors:
- Invalid sequence numbers
- Operations on non-existent entities
- Protocol violations

### Policy

**Never silently ignore exceptions.** All error paths must either:
1. Emit via `ErrorCallback`, or
2. Throw `DomainException`, or
3. Emit domain events (e.g., `PeerOperationSkipped`)

---

## Testing

**Test Suite:** 262 tests covering all layers

- **Domain Layer:** Pure unit tests with no mocks
- **Application Services:** Tests with fake repositories
- **Protocol Layer:** Tests with in-memory ports
- **Integration:** Two-node sync and failure detection scenarios

**Run tests:**
```bash
dart test
```

---

## Status Summary

| Component | Status | Files |
|-----------|--------|-------|
| Domain Layer | ✅ Complete | 40+ files |
| Application Services | ✅ Complete | 2 services |
| Protocol Layer | ✅ Complete | 9 components |
| Infrastructure | ✅ Complete | 5 implementations |
| **Facade Layer** | ❌ **Not Implemented** | **0 files** |
| **Public Exports** | ❌ **Not Implemented** | **Placeholder only** |

**Next Steps:** Implement Coordinator, ChannelFacade, and EventStreamFacade to provide public API. See `ARCHITECTURE_DEVIATIONS.md` for detailed plan.
