# CLAUDE.md

This file provides guidance to Claude Code when working inside
`packages/gossip`. It's a package-local pointer, not a restatement — for
monorepo-wide practices (TDD workflow, Melos commands, the other packages),
see the root [`CLAUDE.md`](../../CLAUDE.md). For domain vocabulary, see
[`GLOSSARY.md`](../../GLOSSARY.md). For the full architecture rationale, see
[ADR-010](docs/adr/010-ddd-layered-architecture.md).

## Project Overview

`gossip` is a pure-Dart library for synchronizing event streams across
devices using an anti-entropy gossip protocol, with SWIM-based failure
detection for peer liveness.

## Architecture: bounded contexts, not layers

The package is organized concept-first, not layer-first. Four top-level
modules under `lib/src/`:

```
lib/src/
  shared/        # kernel — true leaf; imports nothing outside itself
  sync/          # core domain: anti-entropy replication of the event log
  membership/    # SWIM liveness: peer model + the detector that maintains it
  coordinator/   # facade shell / composition root (not a bounded context)
```

`shared/`, `sync/`, and `membership/` each contain exactly `domain/`,
`application/`, `infrastructure/` (`shared/` has no `application/` — it's a
kernel of values, interfaces, and pure services, not use cases).
`coordinator/` is deliberately flat: it's the composition root that wires
`sync` and `membership` together and the library's public facade, not a
bounded context with its own ubiquitous language.

### Boundary rule

A bounded context may import `shared/` and itself — nothing else. The one
exception: its `infrastructure/` layer may import another context, as a
concession, to implement an adapter for an interface its own domain defines.

Today there is exactly one exercised concession:
`sync/infrastructure/membership_peer_directory.dart` (`MembershipPeerDirectory`)
implements sync's own `PeerDirectory` port by wrapping membership's
`PeerRegistry`. Every other sync file sees peers only through
`PeerDirectory`/`SyncPartner`, never membership's `Peer`. Membership imports
nothing from `sync` at all.

### Codecs

There's no crossing wire-protocol module — each context owns its own codec:

- `SyncMessageCodec` (`sync/infrastructure/sync_message_codec.dart`) — wire
  type bytes 3-6.
- `MembershipMessageCodec`
  (`membership/infrastructure/membership_message_codec.dart`) — wire type
  bytes 0-2.

Both implement `shared/domain/interfaces/message_codec.dart`'s
`MessageCodec`. The only shared artifact is the envelope agreement,
`shared/domain/value_objects/wire_types.dart` (`WireTypes`), which
partitions the type-byte space — referencing it is not a context-to-context
dependency.

### Enforcement

The boundary rule is machine-checked, not just documented:
`test/architecture/boundary_test.dart` declares the edge table as data and
walks every import/export in `lib/src`, failing the build on any edge
outside it. If code and this file ever disagree, the test wins.

## Build & Development Commands

Run from `packages/gossip/`:

```bash
dart pub get

# Run all tests (boundary test runs as part of this)
dart test

# Run just the architecture boundary test
dart test test/architecture/boundary_test.dart

# Run a single test file
dart test test/sync/application/gossip_engine_test.dart

# Run tests with name filter
dart test --name "test name pattern"

# Static analysis
dart analyze

# Format
dart format lib test
```
