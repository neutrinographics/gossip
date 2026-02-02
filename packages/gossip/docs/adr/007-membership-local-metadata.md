# ADR-007: Membership as Local Metadata

## Status

Accepted

## Context

Channels have members - the peers that participate in synchronization. A key design question is whether membership should be enforced at the protocol level:

**Option A: Protocol-enforced membership**
- Only sync entries with/from members
- Reject entries from non-members
- Membership list must be synchronized

**Option B: Membership as local metadata**
- Sync with any peer that has the channel
- Membership is purely local information
- Application decides how to use membership

## Decision

**Membership is local metadata that is NOT enforced by the gossip protocol.** The protocol syncs entries to any peer that has the same channel, regardless of membership. Membership lists exist for application-level use only.

```dart
// Membership is local - not enforced by protocol
channel.addMember(peerId);    // Local metadata only
channel.removeMember(peerId); // Doesn't prevent sync

// Protocol syncs with any peer that has the channel
gossipEngine.performGossipRound(); // Syncs regardless of membership
```

## Rationale

1. **Avoids inconsistency**: Membership lists can diverge between nodes. If membership gated sync, nodes with different lists would have inconsistent data.

2. **Simplifies protocol**: No need to verify membership on every message. The protocol stays simple and predictable.

3. **Faster convergence**: Entries propagate through any available path, not just through "authorized" members.

4. **Application flexibility**: Applications can use membership for their own purposes (UI, local access control) without affecting sync behavior.

5. **Eventual consistency**: The primary goal is data consistency. Restricting sync paths works against this goal.

## Consequences

### Positive

- Simpler protocol with fewer edge cases
- Faster and more reliable convergence
- No "split brain" scenarios from membership divergence
- Applications have full control over access semantics

### Negative

- No built-in access control at sync level
- All peers with a channel can read/write entries
- Applications needing access control must implement it themselves

### Access Control Alternatives

Applications requiring access control can implement it at the application layer:

**1. Encrypted Payloads**
```dart
// Only members with key can decrypt
final encrypted = encrypt(payload, memberKey);
await stream.append(encrypted);
```

**2. Signed Entries**
```dart
// Verify author signature before accepting
if (!verifySignature(entry, authorPublicKey)) {
  // Reject entry at application level
}
```

**3. Application-Level Filtering**
```dart
// Filter entries from non-members before display
final entries = await stream.getAll();
final memberEntries = entries.where(
  (e) => members.contains(e.author)
);
```

### What Membership IS Used For

Membership lists are still useful for:
- **UI purposes**: Show who's in the channel
- **Gossip optimization**: Prefer syncing with members
- **Application authorization**: Gate writes at the facade level
- **Peer selection**: Target specific peers for sync

### Example Scenario

Consider nodes A, B, C where:
- A has members: {A, B}
- B has members: {A, B, C}
- C has members: {B, C}

With protocol-enforced membership, data would flow:
- A ↔ B (both consider each other members)
- B ↔ C (both consider each other members)
- A cannot sync directly with C

This creates unnecessary indirection and potential inconsistency. With local-only membership, all three nodes sync directly, ensuring faster convergence.

## Alternatives Considered

### Protocol-Enforced Membership

Reject messages from/to non-members:
- Provides built-in access control
- But creates consistency issues
- Complex to handle membership changes
- Slows convergence when membership diverges

### Membership as CRDT

Synchronize membership lists as CRDTs:
- Membership eventually converges
- But adds complexity
- Still has issues during convergence window
- Doesn't solve all access control needs

### No Membership Concept

Remove membership entirely:
- Maximum simplicity
- But loses useful application-level concept
- No way to express "who should be here"
- Less useful for UI and authorization
