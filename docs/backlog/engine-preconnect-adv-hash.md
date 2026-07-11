# Best-effort pre-connect identity hash in the Android advertisement

**Track:** Sync engine   **Depends on:** nothing

## What this is

The shipped mesh tie-break resolves duplicate links *after* both sides
connect — the transient double-connect (two physical links for roughly one
identify round-trip) is inherent, because there is no way to learn a
peer's identity from its advertisement reliably on both platforms (iOS
peripherals cannot advertise manufacturer data at all).

On Android, though, manufacturer data IS available. This item adds an
optional, best-effort fast path: embed a short hash of the node identity
in the Android advertisement; a scanner that sees it and would lose the
tie-break simply doesn't initiate, avoiding the double-connect entirely
for Android↔Android pairs. Everything else (iOS on either end, hash
missing or colliding) falls through to the existing post-connect
tie-break, which remains the correctness backstop.

## Why it matters

Purely an optimization of a transient: fewer wasted radio cycles and
connection slots during dense mesh formation, at exactly the moment (many
devices meeting at once) when the radio is busiest. Not needed for
correctness — that's why it was explicitly deferred from the tie-break
work.

## Rough approach

Short collision-tolerant hash of the identity in the manufacturer-data
payload; surface it on the scan candidate; in the auto-connect policy,
skip initiating when the local identity would lose against the advertised
hash. Collisions and absence are safe: both sides connect and the
post-connect tie-break resolves as today.

## Related

- Backstop this optimizes:
  [One Bluetooth link per device pair in a mesh](engine-mesh-connection-tiebreak.md).
- Platform constraint documented in
  [the design spec](../superpowers/specs/2026-07-10-bluey-tiebreak-rejection-design.md)
  ("Rejected premise").
