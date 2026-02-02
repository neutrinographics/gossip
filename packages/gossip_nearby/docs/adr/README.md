# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) documenting significant design decisions in the gossip_nearby package.

## What is an ADR?

An ADR captures an important architectural decision along with its context and consequences. ADRs are immutable once accepted - if a decision changes, a new ADR is created that supersedes the old one.

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [001](001-auto-accept-connections.md) | Auto-Accept Connections at Transport Layer | Accepted |
| [002](002-sealed-class-hierarchies.md) | Sealed Class Hierarchies for Exhaustive Pattern Matching | Accepted |
| [003](003-error-streaming-pattern.md) | Error Streaming Pattern | Accepted |
| [004](004-type-prefixed-wire-protocol.md) | Type-Prefixed Wire Protocol | Accepted |
| [005](005-dependency-inversion-nearby-port.md) | Dependency Inversion via NearbyPort Interface | Accepted |
| [006](006-deterministic-connection-initiation.md) | Deterministic Connection Initiation via NodeId Comparison | Accepted |

## Additional Design Decisions

The following decisions are documented in [ARCHITECTURE.md](../../ARCHITECTURE.md):

- **ConnectionRegistry as Aggregate Root**: Enforces NodeId uniqueness invariant
- **App-Controlled Discovery/Advertising**: No auto-management of discovery state
- **Bidirectional Handshake Protocol**: Both peers send NodeId simultaneously
- **Endpoint vs Node Abstraction**: Two identity spaces bridged by Connection entity

## Template

When adding a new ADR, use this template:

```markdown
# ADR-NNN: Title

## Status

[Proposed | Accepted | Deprecated | Superseded by ADR-XXX]

## Context

What is the issue that we're seeing that is motivating this decision?

## Decision

What is the change that we're proposing and/or doing?

## Rationale

Why is this the best choice among the alternatives?

## Consequences

What becomes easier or more difficult because of this decision?

## Alternatives Considered

What other options were considered and why were they rejected?
```
