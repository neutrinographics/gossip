# gossip_nearby Architecture

## Overview

This package provides peer discovery and connection management over Nearby Connections, bridging the gap between the `gossip` sync library and the physical transport layer.

## Domain Model

### Ubiquitous Language

| Term | Definition |
|------|------------|
| **Endpoint** | A Nearby Connections endpoint ID - an opaque, transient identifier assigned by the platform |
| **Node** | An application-level peer identified by a stable `NodeId` (from gossip) |
| **Connection** | An established link between two endpoints that has completed handshake |
| **Handshake** | The protocol for exchanging `NodeId`s after an endpoint connection is established |
| **Discovery** | The process of finding nearby endpoints advertising the same service |
| **Advertising** | The process of making this device visible to nearby discovering devices |

### Value Objects

```
EndpointId
└── value: String (platform-assigned, transient)

Endpoint
├── id: EndpointId
└── displayName: String (human-readable name)

ServiceId
└── value: String (reverse-domain identifier, e.g., 'com.example.app')
```

### Entities

```
Connection
├── endpoint: Endpoint
├── nodeId: NodeId (from gossip)
└── connectedAt: DateTime
```

### Aggregates

```
ConnectionRegistry (Aggregate Root)
├── connections: Map<EndpointId, Connection>
├── pendingHandshakes: Set<EndpointId>
│
├── Invariants:
│   - An EndpointId can only have one connection
│   - A NodeId can only be associated with one EndpointId
│
└── Methods:
    - registerPendingHandshake(endpointId) → tracks that handshake is in progress
    - completeHandshake(endpoint, nodeId) → creates connection, enforces NodeId uniqueness
    - removeConnection(endpointId) → cleans up
    - getNodeIdForEndpoint(endpointId) → lookup
    - getEndpointIdForNodeId(nodeId) → reverse lookup
```

**Design Decision**: `ConnectionRegistry` is an aggregate because we need to enforce
the invariant that a `NodeId` can only map to one endpoint at a time. This prevents
duplicate connections to the same peer and ensures message routing is unambiguous.

### Domain Events

```
HandshakeCompleted(endpoint, nodeId)  # A peer is ready to communicate
HandshakeFailed(endpoint, reason)     # Handshake couldn't complete (for debugging/logging)
ConnectionClosed(nodeId, reason)      # A peer disconnected
```

**Note:** Discovery and connection establishment events are not exposed since the package auto-accepts all connections. The first event the consuming app cares about is `HandshakeCompleted`.

### Domain Errors

```
ConnectionError
├── ConnectionNotFound    # Tried to send to a NodeId with no connection
├── HandshakeTimeout      # Handshake didn't complete in time
├── HandshakeInvalid      # Malformed handshake data
└── SendFailed            # Nearby couldn't send bytes
```

---

## Architecture Layers

### Domain Layer
Pure business logic, no external dependencies.

```
domain/
├── value_objects/
│   ├── endpoint_id.dart
│   ├── endpoint.dart
│   └── service_id.dart
├── entities/
│   └── connection.dart
├── aggregates/
│   └── connection_registry.dart
├── events/
│   └── connection_event.dart
├── errors/
│   └── connection_error.dart
└── interfaces/
    └── nearby_port.dart        # Port for Nearby Connections operations
```

### Application Layer
Orchestrates domain objects, implements use cases.

```
application/
└── services/
    └── connection_service.dart  # Coordinates ConnectionRegistry + ports
```

### Infrastructure Layer
Adapters for external systems.

```
infrastructure/
├── adapters/
│   └── nearby_adapter.dart          # Implements NearbyPort using nearby_connections
├── ports/
│   └── nearby_message_port.dart     # Implements gossip's MessagePort
└── codec/
    └── handshake_codec.dart         # Wire format for handshake messages
```

### Facade Layer
Simplified public API.

```
facade/
└── nearby_transport.dart    # High-level entry point for applications
```

**NearbyTransport API:**
```dart
class NearbyTransport {
  // For gossip integration
  MessagePort get messagePort;
  Stream<PeerEvent> get peerEvents;
  Set<NodeId> get connectedPeers;
  int get connectedPeerCount;
  
  // Advertising control (app-managed)
  Future<void> startAdvertising();
  Future<void> stopAdvertising();
  bool get isAdvertising;
  
  // Discovery control (app-managed)
  Future<void> startDiscovery();
  Future<void> stopDiscovery();
  bool get isDiscovering;
  
  // Lifecycle
  Future<void> dispose();
}
```

**Design Decision:** Discovery and advertising are explicitly controlled by the consuming app. This package does not auto-manage them based on connection count or other heuristics. This gives apps full control for scenarios like:
- Stopping discovery at a custom threshold to reduce network flooding
- Forcing discovery on during QR code scanning regardless of connection count
- Keeping advertising active while an invite screen is open

---

## Port Interfaces

### NearbyPort (Domain Interface)

The domain defines what it needs from a nearby connections implementation:

```dart
abstract class NearbyPort {
  Future<void> startAdvertising(ServiceId serviceId, String displayName);
  Future<void> stopAdvertising();
  Future<void> startDiscovery(ServiceId serviceId);
  Future<void> stopDiscovery();
  Future<void> requestConnection(EndpointId endpointId);
  Future<void> disconnect(EndpointId endpointId);
  Future<void> sendPayload(EndpointId endpointId, Uint8List bytes);
  
  Stream<NearbyEvent> get events;
}
```

**NearbyEvent types:**
```dart
sealed class NearbyEvent {}
class EndpointDiscovered extends NearbyEvent { EndpointId id; String displayName; }
class ConnectionEstablished extends NearbyEvent { EndpointId id; }
class PayloadReceived extends NearbyEvent { EndpointId id; Uint8List bytes; }
class Disconnected extends NearbyEvent { EndpointId id; }
```



---

## Handshake Protocol

When a Nearby connection is established, both sides exchange their `NodeId`:

```
┌─────────┐                           ┌─────────┐
│ Device A│                           │ Device B│
└────┬────┘                           └────┬────┘
     │                                     │
     │ ── Connection Established ────────► │
     │                                     │
     │ ── Handshake(NodeId-A) ──────────► │
     │                                     │
     │ ◄── Handshake(NodeId-B) ────────── │
     │                                     │
     │   [Both sides now know NodeIds]     │
     │                                     │
```

**Wire format:**
```
[0x01][length:4 bytes][nodeId:UTF-8 bytes]  - Handshake message
[0x02][payload bytes]                        - Gossip message
```

**Responsibility:**
- Handshake codec (serialization) → **Infrastructure** (`HandshakeCodec`)
- Handshake orchestration (send/receive/timeout) → **Application** (`ConnectionService`)
- Connection registration → **Domain** (`ConnectionRegistry`)

Both sides send their handshake immediately after connection. Messages may cross in flight - order doesn't matter as long as both complete.

---

## Observability

Debugging network issues requires visibility into what's happening. The package provides multiple levels of observability:

### Log Callback

A callback for internal events at various severity levels:

```dart
enum LogLevel { trace, debug, info, warning, error }

typedef LogCallback = void Function(LogLevel level, String message, [Object? error, StackTrace? stackTrace]);

class NearbyTransport {
  NearbyTransport({
    LogCallback? onLog,
    // ...
  });
}
```

**Log events include:**
- `trace`: Payload sent/received (with size), internal state changes
- `debug`: Endpoint discovered/lost, connection requested, handshake messages
- `info`: Advertising/discovery started/stopped, connection established, handshake completed
- `warning`: Handshake timeout, unexpected message format, connection retry
- `error`: Send failed, handshake failed, unexpected disconnection

### Metrics

Expose metrics for monitoring:

```dart
class NearbyMetrics {
  int get connectedPeerCount;
  int get pendingHandshakeCount;
  int get totalConnectionsEstablished;
  int get totalConnectionsFailed;
  int get totalBytesSent;
  int get totalBytesReceived;
  int get totalMessagesSent;
  int get totalMessagesReceived;
  Duration get averageHandshakeDuration;
}

class NearbyTransport {
  NearbyMetrics get metrics;
}
```

### Domain Events (for app logic)

High-level events the consuming app reacts to:
- `HandshakeCompleted` - peer ready
- `HandshakeFailed` - peer failed to connect
- `ConnectionClosed` - peer disconnected

### Where observability lives

| Concern | Layer |
|---------|-------|
| Metrics collection | Application (`ConnectionService`) |
| Log emission | All layers (via callback passed down) |
| Domain events | Domain (`ConnectionRegistry` emits) |

---

## Design Decisions

1. **ConnectionRegistry is an aggregate** - Enforces the invariant that a NodeId can only map to one endpoint at a time.

2. **Retry logic in application layer** - `ConnectionService` handles reconnection with a configurable policy. The domain just models connection state and emits events.

3. **Single transport scope** - This package only handles Nearby Connections. Multi-transport orchestration would be a separate concern if needed later.

4. **Auto-accept connections** - All Nearby connections are accepted and handshakes completed automatically. Channel membership and access control are gossip/application concerns, not transport concerns.

5. **App-controlled discovery/advertising** - The consuming app explicitly controls when to start/stop discovery and advertising. No auto-management based on connection count or other heuristics.

---

## Dependencies

```
┌─────────────────────────────────────────────────────────┐
│                      Application                         │
│                    (your Flutter app)                    │
└─────────────────────────┬───────────────────────────────┘
                          │ uses
                          ▼
┌─────────────────────────────────────────────────────────┐
│                   gossip_nearby                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │
│  │   Facade    │  │ Application │  │ Infrastructure  │  │
│  │             │──│   Service   │──│    Adapters     │  │
│  └─────────────┘  └──────┬──────┘  └────────┬────────┘  │
│                          │                   │          │
│                   ┌──────▼──────┐            │          │
│                   │   Domain    │            │          │
│                   │  (no deps)  │◄───────────┘          │
│                   └─────────────┘                       │
└─────────────────────────┬───────────────────────────────┘
                          │ depends on
                          ▼
┌─────────────────────────────────────────────────────────┐
│                       gossip                             │
│              (NodeId, MessagePort, etc.)                 │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│                  nearby_connections                      │
│                  (Flutter plugin)                        │
└─────────────────────────────────────────────────────────┘
```
