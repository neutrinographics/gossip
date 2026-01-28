# ADR-004: Type-Prefixed Wire Protocol

## Status

Accepted

## Context

After a Nearby Connections link is established, devices need to:

1. Exchange identity information (NodeIds) via a handshake
2. Send gossip protocol messages for sync

These are different message types with different structures and handlers. The transport needs a way to distinguish between them when bytes arrive.

Options for message type discrimination:

1. **Type prefix byte**: First byte indicates message type
2. **Length-prefixed with type**: Type + length + payload
3. **Separate channels**: Use Nearby Connections' multiple payload streams
4. **Magic bytes/headers**: Multi-byte signatures per message type
5. **State machine**: Infer type from connection state (first message = handshake)

## Decision

**Use a single-byte type prefix at the start of every message.**

Wire format:
```
Handshake: [0x01][length:4 bytes][nodeId:UTF-8 bytes]
Gossip:    [0x02][payload bytes]
```

Implementation:
```dart
abstract class MessageType {
  static const int handshake = 0x01;
  static const int gossip = 0x02;
}

abstract class WireFormat {
  static const int typeOffset = 0;
  static const int lengthOffset = 1;
  static const int lengthFieldSize = 4;
  static const int handshakeHeaderSize = 1 + lengthFieldSize;
  static const int handshakePayloadOffset = handshakeHeaderSize;
  static const int gossipPayloadOffset = 1;
}
```

## Rationale

1. **Simplicity**: Single byte check to route messages
2. **Efficiency**: Minimal overhead (1 byte for gossip, 5 bytes for handshake header)
3. **Extensibility**: 254 additional message types available if needed
4. **Stateless**: Any message can be understood without connection state
5. **Debuggable**: Easy to identify message type in packet captures

The handshake message includes a length field because NodeIds are variable-length. Gossip messages don't need length because the remaining bytes are the payload.

## Consequences

### Positive

- Simple to implement and debug
- Minimal wire overhead
- Easy to add new message types
- No dependency on connection state for message parsing
- Clear separation between protocol layers

### Negative

- All messages must be prefixed (even single-type scenarios)
- Type byte is "wasted" for gossip-heavy workloads (1 byte per message)
- No built-in versioning for the protocol itself

### Mitigations

- 1 byte overhead is negligible for typical message sizes
- Protocol versioning can be added via new message types if needed
- Constants are well-documented for maintainability

## Alternatives Considered

### Separate Nearby Connections Channels

Use different payload types or stream IDs for handshake vs gossip.

Rejected because:
- Adds platform-specific complexity
- Nearby Connections API doesn't cleanly support multiple logical channels
- Would need separate setup for each message type

### State Machine Inference

First message after connection = handshake, subsequent = gossip.

Rejected because:
- Fragile if messages are lost or reordered
- Can't handle re-handshake scenarios
- Makes message parsing depend on global state

### Magic Byte Headers

Use multi-byte signatures like `HSHK` for handshake, `GSSP` for gossip.

Rejected because:
- More bytes wasted on every message
- Single byte is sufficient for our needs
- Magic bytes typically used for file format identification, not stream protocols

### Length-Prefixed Everything

```
[type:1][length:4][payload:N]
```

Rejected for gossip messages because:
- Gossip payloads are already complete messages from the gossip library
- Adding length is redundant - Nearby Connections delivers complete payloads
- Handshake uses length because NodeId size varies
