# Integration Tests

This directory contains integration tests for the gossip sync library. Tests are organized by functional area and test the system end-to-end using the `TestNetwork` DSL.

## Directory Structure

```
integration/
  edge_cases/         # Edge case handling (duplicates, ordering)
  failure_detection/  # SWIM protocol and peer status
  lifecycle/          # Coordinator and channel lifecycle
  ordering/           # HLC timestamps and sequence numbers
  sync/               # Core synchronization scenarios
```

## Test Summary

### Edge Cases (`edge_cases/`)

#### Message Handling
- **duplicate entries are handled idempotently** - Verifies that receiving the same entry multiple times doesn't create duplicates
- **out-of-order entry reception still converges** - Entries arriving in different orders on different nodes still converge

### Failure Detection (`failure_detection/`)

#### Peer Failure Detection
- **peers start as reachable** - New peers are initially marked as reachable
- **peer remains reachable when network is healthy** - Healthy network maintains reachable status
- **peer becomes suspected after network partition** - Partitioned peers transition to suspected/unreachable
- **partitioned peer has increased failed probe count** - Failed probes are tracked correctly

#### Failure Detection Recovery
- **peer recovers from suspected to reachable after heal** - Peers recover status when network heals

### Lifecycle (`lifecycle/`)

#### Channel Operations
- **can create channel, add stream, and append entries** - Basic channel/stream CRUD operations
- **channel membership can be modified** - Adding and removing channel members
- **adding member allows sync of existing entries** - Late joiners receive historical entries
- **concurrent channel creation on multiple nodes syncs correctly** - Simultaneous channel creation converges
- **removed member with local channel still syncs** - Membership is local metadata; gossip syncs to any node with the channel

#### Coordinator Lifecycle
- **peers can be added and queried** - Peer registry management
- **coordinator transitions through states correctly** - State machine: stopped -> running -> stopped -> disposed
- **disposed coordinator cannot be restarted** - Disposed state is terminal

### Ordering (`ordering/`)

#### HLC Timestamp Ordering
- **HLC timestamps preserve causal ordering across sync** - Causal writes have ordered HLCs
- **concurrent writes at different times have distinct HLCs** - Different physical times produce different HLCs
- **later writes have higher HLC due to time advancement** - Time advancement increases HLC
- **HLC updates on receive ensures causal ordering** - Receiving entries updates local HLC clock
- **entries sorted by HLC are globally consistent across nodes** - All nodes agree on HLC sort order
- **HLC physical time advances with simulated time** - Fake clock integration works correctly
- **clock skew is reflected in HLC physical timestamps** - Clock skew produces expected HLC differences

#### Sequence Number Ordering
- **sequential writes from same node have increasing sequence numbers** - Monotonic sequence per author
- **concurrent writes have independent sequence numbers per author** - Each author has independent sequence
- **sequence numbers are contiguous with no gaps** - No gaps in sequence numbers
- **multiple streams have independent sequence counters per stream** - Sequences are per-stream
- **sequence numbers persist correctly across sync** - Synced entries maintain original sequences

### Sync (`sync/`)

#### Basic Sync
- **two coordinators can create the same channel** - Channel creation on multiple nodes
- **entries written on node1 sync to node2** - Basic one-way sync
- **bidirectional sync - entries from both nodes converge** - Two-way sync
- **entries propagate through intermediate node** - Multi-hop sync (A -> B -> C)
- **all three nodes writing entries converge** - Three-way convergence
- **concurrent writes from multiple nodes converge** - 4-node concurrent writes
- **rapid sequential writes all sync** - 20 rapid writes sync correctly
- **rapid alternating writes from multiple nodes converge** - Interleaved writes from 3 nodes
- **multiple streams in same channel sync independently** - Multi-stream sync
- **stream created after entries exist syncs correctly** - Late stream creation

#### Churn Sync
- **node joins mid-sync and receives existing entries** - Dynamic node join
- **node rejoins with stale data and syncs missing entries** - Rejoin with stale state
- **node writes while offline, syncs after reconnect** - Offline writes sync on reconnect
- **sync after long offline period with many missed entries** - Catch-up after long offline (30 entries)

#### Partition Sync
- **partition heals and sync resumes** - Basic partition recovery
- **entries written during partition sync after healing** - Divergent writes merge after heal
- **divergent writes during partition merge correctly** - Two partition groups merge
- **three-way partition heals and all entries merge** - Complete network partition recovery

#### Scale Sync
- **empty channel syncs without error** - Empty channel edge case
- **single node network operations work** - Single node operation
- **large payload syncs correctly** - Large payload handling
- **many entries sync (stress test)** - 50 entries stress test
- **maximum nodes (8) all sync correctly** - 8-node network
- **payload at 32KB limit syncs correctly** - Max payload size (Android Nearby Connections limit)
- **100 entries from single node sync correctly** - 100 entry sync
- **entries from all 8 nodes with concurrent writes** - 8-node concurrent writes

#### Topology Sync
- **chain topology - entries propagate through intermediate node** - Linear topology (A-B-C-D-E)
- **star topology - hub relays between spokes** - Hub and spoke topology
- **ring topology - entries propagate around the ring** - Circular topology

## Running Tests

```bash
# Run all integration tests
dart test test/integration/

# Run a specific test file
dart test test/integration/sync/basic_sync_test.dart

# Run tests matching a pattern
dart test --name "partition"
```

## Test Infrastructure

Tests use the `TestNetwork` DSL from `test/support/test_network.dart` which provides:

- **Simulated time** - Deterministic time control via `InMemoryTimePort`
- **Simulated network** - In-memory message passing with partition simulation
- **Topology helpers** - `connectAll()`, `connectChain()`, `connectStar()`, `connectRing()`
- **Partition simulation** - `partition()`, `heal()`, `partitionNodes()`, `healAll()`
- **Convergence checking** - `hasConverged()`, `entryCounts()`
