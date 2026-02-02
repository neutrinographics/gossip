# ADR-006: Transport and Discovery External to Library

## Status

Accepted

## Context

A gossip sync library needs to communicate with peers. This requires:
1. **Transport**: How to send/receive bytes between devices
2. **Discovery**: How to find other devices to sync with

Transport options vary widely by platform:
- Mobile: Bluetooth, WiFi Direct, Nearby Connections
- Desktop: TCP/UDP sockets, WebSockets
- Browser: WebRTC, WebSockets
- Cloud: HTTP, gRPC

Discovery mechanisms also vary:
- Bluetooth scanning
- mDNS/Bonjour
- Central server registry
- Manual configuration

## Decision

**Transport and discovery are external to the library.** The library defines abstract interfaces (`MessagePort`, peer management via `Coordinator.addPeer`), and applications provide implementations.

```dart
// Transport: Application implements MessagePort
abstract class MessagePort {
  Future<void> send(NodeId destination, Uint8List bytes);
  Stream<IncomingMessage> get incoming;
}

// Discovery: Application calls Coordinator
await coordinator.addPeer(NodeId('discovered-device'));
await coordinator.removePeer(NodeId('lost-device'));
```

## Rationale

1. **Platform flexibility**: Same library works on mobile, desktop, web, server
2. **Transport agnostic**: Bluetooth, WiFi, TCP, WebRTC all work
3. **Discovery flexibility**: Any discovery mechanism can be used
4. **Reduced dependencies**: Library has no network dependencies
5. **Testability**: In-memory implementations for testing
6. **Separation of concerns**: Library does sync, app does networking

## Consequences

### Positive

- Library is lightweight with no platform-specific code
- Applications can optimize transport for their use case
- Easy to test with in-memory message passing
- Can adapt to new transports without library changes
- Multiple transports can be used simultaneously

### Negative

- Applications must implement `MessagePort` themselves
- No built-in discovery means more work for applications
- No transport-level optimizations in library (batching, compression)
- Applications responsible for connection management

### MessagePort Contract

The `MessagePort` interface is intentionally minimal:

```dart
abstract class MessagePort {
  /// Send bytes best-effort (no guaranteed delivery)
  Future<void> send(NodeId destination, Uint8List bytes);
  
  /// Stream of received messages
  Stream<IncomingMessage> get incoming;
  
  /// Clean up resources
  Future<void> close();
}
```

Key aspects:
- **Best-effort delivery**: Library handles message loss via retransmission
- **Async send**: Non-blocking, fire-and-forget semantics
- **Stream-based receive**: Natural fit for Dart async model
- **No connection state**: Port abstracts connection management

### Peer Management

Peers are managed explicitly by the application:

```dart
// Application discovers a device
final peerId = NodeId('device-uuid');
await coordinator.addPeer(peerId);

// Device becomes unreachable
await coordinator.removePeer(peerId);
```

The library handles:
- Tracking peer state (reachable, suspected, unreachable)
- Peer selection for gossip rounds
- SWIM failure detection

The application handles:
- Finding peers (discovery)
- Creating peer identifiers
- Connection lifecycle

## Alternatives Considered

### Built-in Bluetooth Transport

Include Bluetooth implementation in library:
- Simplifies mobile use case
- But adds platform dependencies
- Limits portability
- Ties library to specific Bluetooth API

### Built-in mDNS Discovery

Include mDNS discovery:
- Zero-config for local networks
- But not all platforms support it
- Doesn't work for WAN scenarios
- Adds complexity and dependencies

### Abstract Transport Factory

Provide factory pattern for transports:
- Library ships with transport implementations
- Application selects by name/config
- But still limits flexibility
- Plugin system adds complexity
