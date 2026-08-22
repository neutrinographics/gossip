# gossip_nearby

Implements the `gossip` package's `MessagePort` using Android/iOS Nearby
Connections.

## Architecture

Follows the same DDD Layered Architecture as the rest of the monorepo (see
root `CLAUDE.md`):

```
Facade Layer         → NearbyTransport
Application Layer    → ConnectionService (handshake orchestration, message routing)
Domain Layer         → ConnectionRegistry, Endpoint, ConnectionEvent, NearbyPort (interface)
Protocol Layer       → HandshakeCodec, WireDispatcher (wire format + byte classification)
Infrastructure Layer → NearbyAdapter (platform integration via `nearby_connections`)
```

See `docs/adr/` for Architecture Decision Records explaining design choices.

### 2026-08-22 addendum (ARCH3-3)

Wire codecs and byte-level classification (`HandshakeCodec`, `WireDispatcher`,
`MessageType`, `WireFormat`) live in `protocol/`, not `infrastructure/`. The
application layer (`ConnectionService`) consumes the `MessageType` value
returned by `WireDispatcher.classify()` only — it no longer reads wire byte
offsets (`bytes[WireFormat.typeOffset]`) directly.

This note lives here rather than as an ADR amendment because no existing ADR
under `docs/adr/` documents codec *placement*: `grep -rln "odec"
packages/gossip_nearby/docs/` returns no matches. ADR-004 ("Type-Prefixed
Wire Protocol") defines the `MessageType`/`WireFormat` wire format these
types implement, but does not speak to which architectural layer owns them —
so it wasn't amended.
