# ADR-001: Auto-Accept Connections at Transport Layer

## Status

Accepted

## Context

When a nearby device requests a connection via Nearby Connections, the receiving device must decide whether to accept or reject the connection. This decision could be made at different layers:

1. **Transport layer**: Automatically accept all connections
2. **Application layer**: Ask the application to approve each connection request
3. **Domain layer**: Use business rules to filter connections

The gossip_nearby package sits between the Nearby Connections platform API and the gossip sync library. The gossip library handles channel membership and access control separately from transport concerns.

## Decision

**The transport layer automatically accepts all incoming Nearby Connections without application involvement.** Channel membership, access control, and peer filtering are handled at the gossip/application layer, not the transport layer.

```dart
void _onConnectionInitiated(String endpointId, ConnectionInfo info) {
  unawaited(
    _nearby.acceptConnection(
      endpointId,
      onPayLoadRecieved: _onPayloadReceived,
      onPayloadTransferUpdate: (_, __) {},
    ),
  );
}
```

## Rationale

1. **Separation of concerns**: Transport should only handle bytes, not authorization
2. **Reduced latency**: No round-trip to application layer before accepting
3. **Simpler API**: No callback or approval flow needed in the facade
4. **Gossip handles access**: The gossip library already has channel membership semantics - duplicating this at transport level would be redundant
5. **Handshake as filter**: After connection, the handshake protocol exchanges NodeIds, giving the application a natural point to disconnect unwanted peers

## Consequences

### Positive

- Simpler transport layer with single responsibility
- Faster connection establishment
- Cleaner integration with gossip's existing membership model
- No complex approval flow to implement and test

### Negative

- Cannot reject connections before handshake (minor bandwidth for unwanted peers)
- Malicious peers can connect and send handshake before being identified
- No pre-connection filtering based on device name or metadata

### Mitigations

- Applications can immediately disconnect after handshake if the NodeId is unwanted
- The handshake is small (just a NodeId), so rejected peers cost minimal bandwidth
- Platform-level Nearby Connections has its own proximity limits

## Alternatives Considered

### Application-Controlled Acceptance

Would require:
- Callback from transport to application for each connection request
- Application returns accept/reject decision
- Transport waits for decision before proceeding

Rejected because:
- Adds latency to every connection
- Couples transport to application-level concepts
- Gossip already handles membership - this would duplicate logic

### Whitelist-Based Acceptance

Accept only from pre-registered device identifiers.

Rejected because:
- Nearby Connections endpoints are transient - they change between sessions
- Would require separate out-of-band key exchange
- Doesn't match the ad-hoc discovery use case
