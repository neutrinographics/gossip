# Gossip

A Dart library for synchronizing event streams across devices using gossip protocols.

Designed for mobile-first, offline-capable applications with sub-second convergence.

## Features

- **Gossip-based sync**: Anti-entropy protocol with digest/delta exchange for efficient synchronization
- **SWIM failure detection**: Scalable membership protocol for peer health monitoring
- **Hybrid Logical Clocks**: Causally consistent timestamps without coordination
- **Offline-first**: Local operations work without connectivity; sync happens when peers connect
- **Transport agnostic**: Bring your own transport (Bluetooth, WiFi Direct, TCP, WebRTC)
- **Payload agnostic**: Library syncs opaque bytes; you define the semantics

## Target Use Cases

- Collaborative mobile apps (shared documents, multiplayer games)
- Local-first software with peer-to-peer sync
- IoT device coordination
- Offline-capable field applications

## Quick Start

```dart
import 'package:gossip/gossip.dart';

void main() async {
  // 1. Create repositories (use in-memory for testing)
  final channelRepo = InMemoryChannelRepository();
  final peerRepo = InMemoryPeerRepository();
  final entryRepo = InMemoryEntryRepository();

  // 2. Create coordinator
  final coordinator = await Coordinator.create(
    localNode: NodeId('my-device'),
    channelRepository: channelRepo,
    peerRepository: peerRepo,
    entryRepository: entryRepo,
  );

  // 3. Create a channel and stream
  final channel = await coordinator.createChannel(ChannelId('my-channel'));
  final stream = await channel.getOrCreateStream(StreamId('messages'));

  // 4. Write entries
  await stream.append(Uint8List.fromList(utf8.encode('Hello!')));

  // 5. Read entries
  final entries = await stream.getAll();
  for (final entry in entries) {
    print('${entry.author}: ${utf8.decode(entry.payload)}');
  }

  // 6. Clean up
  await coordinator.dispose();
}
```

## Network Synchronization

To sync across devices, provide transport implementations:

```dart
final coordinator = await Coordinator.create(
  localNode: NodeId('device-1'),
  channelRepository: channelRepo,
  peerRepository: peerRepo,
  entryRepository: entryRepo,
  messagePort: MyBluetoothPort(),  // Your transport implementation
  timerPort: RealTimePort(),
);

// Add peers discovered via your transport
await coordinator.addPeer(NodeId('device-2'));

// Start synchronization
await coordinator.start();

// Monitor sync events
coordinator.events.listen((event) {
  print('Event: $event');
});

// Monitor errors
coordinator.errors.listen((error) {
  print('Error: ${error.message}');
});
```

## Core Concepts

### Coordinator

The main entry point. Manages sync lifecycle, peer connections, and channels.

```dart
final coordinator = await Coordinator.create(...);
await coordinator.start();   // Start sync
await coordinator.pause();   // Pause sync
await coordinator.resume();  // Resume sync
await coordinator.stop();    // Stop sync
await coordinator.dispose(); // Clean up
```

### Channels

Logical groupings of streams with membership. Each channel syncs independently.

```dart
final channel = await coordinator.createChannel(ChannelId('project-1'));
await channel.addMember(NodeId('collaborator'));
final members = await channel.members;
```

### Streams

Append-only logs of entries within a channel. Each stream has its own sync state.

```dart
final stream = await channel.getOrCreateStream(StreamId('messages'));
await stream.append(payload);
final entries = await stream.getAll();
```

### State Materialization

Compute derived state from entry logs using fold operations:

```dart
class CounterMaterializer implements StateMaterializer<int> {
  @override
  int initial() => 0;

  @override
  int fold(int state, LogEntry entry) => state + 1;
}

await stream.registerMaterializer(CounterMaterializer());
final count = await stream.getState<int>();
```

## Configuration

Tune sync behavior with `CoordinatorConfig`:

```dart
final config = CoordinatorConfig(
  gossipInterval: Duration(milliseconds: 100),  // Faster sync (default: 200ms)
  probeInterval: Duration(milliseconds: 500),   // Faster failure detection (default: 1000ms)
  pingTimeout: Duration(milliseconds: 300),     // Ping timeout (default: 500ms)
  suspicionThreshold: 2,                        // Failed probes before suspicion (default: 3)
);

final coordinator = await Coordinator.create(
  // ... other params
  config: config,
);
```

## Implementing Transport

The library requires a `MessagePort` implementation for network communication:

```dart
class MyBluetoothPort implements MessagePort {
  final _controller = StreamController<IncomingMessage>.broadcast();

  @override
  Future<void> send(NodeId destination, Uint8List bytes) async {
    // Send bytes to the destination device
    await bluetooth.sendTo(destination.value, bytes);
  }

  @override
  Stream<IncomingMessage> get incoming => _controller.stream;

  void onReceive(String deviceId, Uint8List data) {
    _controller.add(IncomingMessage(
      sender: NodeId(deviceId),
      bytes: data,
      receivedAt: DateTime.now(),
    ));
  }

  @override
  Future<void> close() async {
    await _controller.close();
  }
}
```

## Monitoring

Check coordinator health and resource usage:

```dart
final health = await coordinator.getHealth();
print('State: ${health.state}');
print('Healthy: ${health.isHealthy}');
print('Reachable peers: ${health.reachablePeerCount}');

final usage = await coordinator.getResourceUsage();
print('Channels: ${usage.channelCount}');
print('Entries: ${usage.totalEntries}');
print('Storage: ${usage.totalStorageBytes} bytes');
```

## Architecture

The library follows Domain-Driven Design with clear layer separation:

```
┌─────────────────────────────────────────┐
│            Facade Layer                 │
│  Coordinator, Channel, EventStream      │
└─────────────────────────────────────────┘
                    │
┌─────────────────────────────────────────┐
│          Application Layer              │
│  ChannelService, PeerService            │
└─────────────────────────────────────────┘
                    │
┌─────────────────────────────────────────┐
│   Domain    │  Protocol  │ Infrastructure│
│  Aggregates │  Gossip    │  Repositories │
│  Entities   │  SWIM      │  Ports        │
└─────────────────────────────────────────┘
```

See `docs/adr/` for Architecture Decision Records explaining design choices.

## Threading Model

**Important:** All `Coordinator` operations must run in the same Dart isolate. The library uses no locks or synchronization primitives. Accessing a coordinator from multiple isolates will cause data corruption.

## Design Targets

The library is optimized for:

- **Small peer groups**: Best performance with < 10 peers per channel
- **Payload size**: 32KB max recommended (Android Nearby Connections compatibility)
- **Convergence time**: ~150ms typical for small networks

## Development

```bash
# Get dependencies
dart pub get

# Run tests
dart test

# Analyze code
dart analyze

# Format code
dart format lib test
```

## License

See [LICENSE](LICENSE) file.
