# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) documenting significant design decisions in the gossip sync library.

## What is an ADR?

An ADR captures an important architectural decision along with its context and consequences. ADRs are immutable once accepted - if a decision changes, a new ADR is created that supersedes the old one.

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [001](001-single-isolate-execution.md) | Single-Isolate Execution Model | Accepted |
| [002](002-separate-entry-storage.md) | Separate Entry Storage from Aggregates | Accepted |
| [003](003-payload-agnostic-design.md) | Payload-Agnostic Design | Accepted |
| [004](004-swim-failure-detection.md) | SWIM Protocol for Failure Detection | Accepted |
| [005](005-hybrid-logical-clocks.md) | Hybrid Logical Clocks for Ordering | Accepted |
| [006](006-transport-discovery-external.md) | Transport and Discovery External to Library | Accepted |
| [007](007-membership-local-metadata.md) | Membership as Local Metadata | Accepted |
| [008](008-anti-entropy-gossip-protocol.md) | Anti-Entropy Gossip Protocol | Accepted |
| [009](009-version-vectors-for-sync.md) | Version Vectors for Sync State Tracking | Accepted |
| [010](010-ddd-layered-architecture.md) | DDD Layered Architecture | Accepted |
| [011](011-error-callback-pattern.md) | Error Callback Pattern for Recoverable Errors | Accepted |
| [012](012-swim-late-ack-handling.md) | SWIM Late-Ack Handling | Accepted |

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
