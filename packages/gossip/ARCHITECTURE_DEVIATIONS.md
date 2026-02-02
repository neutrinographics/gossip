# Architecture Deviations Report

This document lists components specified in `architecture.md` (v7) that are either not yet implemented or differ from the specification.

**Last Updated:** 2026-01-27

---

## ❌ NOT IMPLEMENTED: Facade Layer (Critical)

The entire public API layer is missing. This is the primary interface for applications using the library.

### Missing Components

#### 1. Coordinator Class

**Location (Expected):** `lib/src/facade/coordinator.dart` or similar

**Purpose:** Main entry point for the library. Provides lifecycle management, peer management, and channel operations.

**Missing API:**
```dart
class Coordinator {
  // Factory
  static Future<Coordinator> create({...});
  
  // State management
  SyncState get state;
  bool get isDisposed;
  Future<void> start();
  Future<void> stop();
  Future<void> pause();
  Future<void> resume();
  Future<void> dispose();
  
  // Event/Error streams
  Stream<DomainEvent> get events;
  Stream<SyncError> get errors;
  
  // Peer management
  Future<void> addPeer(NodeId id, {ContactInfo? contact});
  Future<void> removePeer(NodeId id);
  List<Peer> get peers;
  List<Peer> get reachablePeers;
  int get localIncarnation;
  PeerMetrics? getPeerMetrics(NodeId id);
  
  // Channel management
  Future<ChannelFacade> createChannel(ChannelId id, {StreamConfig? config});
  ChannelFacade? getChannel(ChannelId id);
  Future<void> removeChannel(ChannelId id);
  List<ChannelId> get channelIds;
  List<ChannelId> channelsForPeer(NodeId peer);
  
  // Monitoring
  ResourceUsage getResourceUsage();
  HealthStatus getHealth();
  
  // Hooks (optional callbacks)
  void onBeforeMerge(BeforeMergeCallback callback);
  void onBeforeCreateChannel(BeforeCreateChannelCallback callback);
  void onBeforeAddPeer(BeforeAddPeerCallback callback);
}

enum SyncState { loading, running, paused, stopped, disposed }

class ResourceUsage {
  final int peerCount;
  final int channelCount;
  final int totalStorageBytes;
  final int totalEntries;
}

class HealthStatus {
  final SyncState state;
  final NodeId localNode;
  final int incarnation;
  final ResourceUsage resourceUsage;
  final int reachablePeerCount;
  bool get isHealthy;
}
```

**Impact:** Without this, there's no public API. Applications cannot use the library.

---

#### 2. ChannelFacade Class

**Location (Expected):** `lib/src/facade/channel_facade.dart` or similar

**Purpose:** Provides channel-level operations (membership, stream access, compaction).

**Missing API:**
```dart
class ChannelFacade {
  ChannelId get id;
  
  // Membership
  List<NodeId> get members;
  Future<void> addMember(NodeId member);
  Future<void> removeMember(NodeId member);
  
  // Streams
  Future<EventStreamFacade> getOrCreateStream(
    StreamId id, 
    {RetentionPolicy? retention}
  );
  EventStreamFacade? getStream(StreamId id);
  List<StreamId> get streamIds;
  
  // Maintenance
  Future<void> compact({List<StreamId>? streams});
}
```

**Impact:** No way to manage channel members or access streams.

---

#### 3. EventStreamFacade Class

**Location (Expected):** `lib/src/facade/event_stream_facade.dart` or similar

**Purpose:** Provides stream-level read/write operations.

**Missing API:**
```dart
class EventStreamFacade {
  StreamId get id;
  
  // Write
  Future<LogEntry> append(Uint8List payload);
  
  // Read
  Future<List<LogEntry>> getAll();
  Stream<LogEntry> subscribe();
  
  // State materialization
  void registerMaterializer<T>(StateMaterializer<T> materializer);
  T? getState<T>();
}
```

**Impact:** No way to read or write entries to streams.

---

## ❌ NOT IMPLEMENTED: Supporting Components

### 4. SyncCoordinatorService Interface

**Location (Expected):** `lib/src/application/sync_coordinator_service.dart` or similar

**Purpose:** Bridge between Coordinator facade and protocol services (GossipEngine, FailureDetector).

**Missing API:**
```dart
abstract interface class SyncCoordinatorService {
  NodeId get localNode;
  int get localIncarnation;
  List<Peer> get reachablePeers;
  Peer? getPeer(NodeId id);
  
  void updatePeerContact(NodeId id, {required int nowMs});
  void updatePeerAntiEntropy(NodeId id, {required int nowMs});
  void updatePeerIncarnation(NodeId id, int incarnation, {required int nowMs});
  void recordMessageReceived(NodeId id, int bytes, {required int nowMs});
  void recordMessageSent(NodeId id, int bytes, {required int nowMs});
  
  List<ChannelId> get channelIds;
  List<NodeId> getChannelMembers(ChannelId id);
  StreamDigest? computeDigest(ChannelId channel, StreamId stream);
  ChannelDelta? computeDelta(ChannelId channel, StreamId stream, VersionVector since);
  MergeResult mergeEntries(ChannelId channel, StreamId stream, List<LogEntry> entries);
  BatchedDigest computeBatchedDigest(List<ChannelId> channels);
  List<ChannelId> sharedChannels(NodeId peer);
  
  Hlc receiveTimestamp(Hlc remoteTs);
  void reportError(SyncError error);
  void incrementMetric(String name);
  void recordHistogram(String name, int value);
  bool shouldAcceptMerge(NodeId sender, ChannelId channel);
}
```

**Impact:** No way to wire protocol services to the Coordinator. Integration is manual.

---

### 5. CoordinatorSyncService Implementation

**Location (Expected):** `lib/src/application/coordinator_sync_service.dart` or similar

**Purpose:** Concrete implementation of `SyncCoordinatorService` that delegates to Coordinator.

**Impact:** Protocol services cannot be integrated with Coordinator.

---

## ❌ NOT IMPLEMENTED: Public Exports

### 6. Public API Exports

**Location:** `lib/gossip.dart`

**Current State:** Only exports placeholder `Awesome` class from `gossip_experiment_base.dart`

**Expected Exports:**
```dart
library;

// Facade layer
export 'src/facade/coordinator.dart';
export 'src/facade/channel_facade.dart';
export 'src/facade/event_stream_facade.dart';

// Domain types (needed by facade users)
export 'src/domain/value_objects/node_id.dart';
export 'src/domain/value_objects/channel_id.dart';
export 'src/domain/value_objects/stream_id.dart';
export 'src/domain/value_objects/log_entry.dart';
export 'src/domain/value_objects/hlc.dart';
export 'src/domain/value_objects/version_vector.dart';

export 'src/domain/entities/peer.dart';
export 'src/domain/entities/peer_metrics.dart';
export 'src/domain/entities/stream_config.dart';

export 'src/domain/events/domain_event.dart';
export 'src/domain/errors/sync_error.dart';

export 'src/domain/interfaces/retention_policy.dart';
export 'src/domain/interfaces/state_materializer.dart';

// Infrastructure ports (for custom implementations)
export 'src/infrastructure/ports/message_port.dart';
export 'src/infrastructure/ports/timer_port.dart';

// In-memory implementations (for testing)
export 'src/infrastructure/repositories/in_memory_peer_repository.dart';
export 'src/infrastructure/repositories/in_memory_channel_repository.dart';
export 'src/infrastructure/stores/in_memory_entry_store.dart';
export 'src/infrastructure/ports/in_memory_message_port.dart';
export 'src/infrastructure/ports/in_memory_timer_port.dart';
```

**Impact:** Applications cannot import the library's public API.

---

## ✅ CORRECTLY IMPLEMENTED (No Deviations)

The following layers match the architecture specification exactly:

### Domain Layer
- ✅ All value objects (NodeId, ChannelId, StreamId, LogEntry, LogEntryId, Hlc, VersionVector)
- ✅ All entities (Peer, PeerMetrics, StreamConfig)
- ✅ All aggregates (PeerRegistry, Channel)
- ✅ All domain events (13 event types)
- ✅ All domain errors (SyncError sealed class with 6 subtypes)
- ✅ All domain services (HlcClock, TimeSource)
- ✅ All repository interfaces (ChannelRepository, PeerRepository, EntryRepository)
- ✅ All policy interfaces (RetentionPolicy with 4 implementations)
- ✅ StateMaterializer interface
- ✅ All result types (MergeResult, CompactionResult, StreamDigest, ChannelDigest, BatchedDigest, ChannelDelta)

### Application Services Layer
- ✅ PeerService (with ErrorCallback support)
- ✅ ChannelService (with ErrorCallback support)

### Protocol Layer
- ✅ All protocol messages (Ping, Ack, PingReq, DigestRequest, DigestResponse, DeltaRequest, DeltaResponse)
- ✅ ProtocolCodec (serialization/deserialization)
- ✅ GossipEngine (anti-entropy sync with ErrorCallback support)
- ✅ FailureDetector (SWIM protocol with ErrorCallback support)

### Infrastructure Layer
- ✅ MessagePort interface and InMemoryMessagePort
- ✅ TimePort interface and InMemoryTimePort
- ✅ InMemoryPeerRepository
- ✅ InMemoryChannelRepository
- ✅ InMemoryEntryStore (with getVersionVector optimization)

---

## 📊 Implementation Status Summary

| Layer | Specified Components | Implemented | Status |
|-------|---------------------|-------------|--------|
| Domain | ~40 types | 40 | ✅ 100% |
| Application Services | 2 services | 2 | ✅ 100% |
| Protocol | 7 messages + 2 services | 9 | ✅ 100% |
| Infrastructure | 5 ports/impls | 5 | ✅ 100% |
| **Facade** | **3 classes** | **0** | ❌ **0%** |

**Overall:** 4 of 5 layers complete (80% of layers, but 0% of public API)

---

## 🎯 Priority Recommendations

### High Priority (Blocking Library Use)
1. Implement `Coordinator` class
2. Implement `ChannelFacade` class
3. Implement `EventStreamFacade` class
4. Export public API from `lib/gossip.dart`

### Medium Priority (Integration)
5. Implement `SyncCoordinatorService` interface
6. Implement `CoordinatorSyncService` adapter
7. Wire GossipEngine and FailureDetector to Coordinator via SyncCoordinatorService

### Low Priority (Nice to Have)
8. Add integration tests for end-to-end flows
9. Add example application demonstrating library usage
10. Document threading model and single-isolate guarantee

---

## 📝 Notes

- The implemented code is **high quality** and follows strict DDD principles
- No architectural violations detected in implemented code
- Error handling has been enhanced beyond spec (ErrorCallback pattern, PeerOperationSkipped events)
- The foundation is solid - only the public API layer is missing
