# Name announced channels by a keyed hash, so a stranger learns nothing

**Track:** Sync engine   **Depends on:** [Only tell a peer about the groups you both belong to](engine-scope-digests-to-shared-groups.md)

## What this is

Since digest scoping, a device tells a peer about the groups the peer has
not yet shown it holds by *announcing* them: naming the group's identifier
with nothing else, so the peer can answer if it holds the group too. The
announcement still names the group in plain text. Any device within radio
range that connects learns the identifiers of every group and account the
sender syncs, a little at a time, under the announce budget.

This item closes that: an announcement names a channel by a keyed hash that
both holders can compute and a bystander cannot invert. A peer that holds
the channel recognises the hash among its own; one that does not learns
only that the sender holds *something*. Digests for channels both sides
already share can stay in plain text — both already know them.

## Why it matters

The disclosure is mild — identifiers, not content — but it tells a
bystander that an account exists, that it is active nearby, and roughly
how many groups it joins. Nothing in the design intends that. Scoping cut
the volume of the disclosure; this cuts its content.

## Rough approach

The seam is exactly the announcement: one field on the digest request and
one codec mapping, so the change is local. The key must be something both
holders know and a bystander does not — the channel's own identifier is the
natural candidate (hash of the id, keyed by the id), since the only thing a
recipient does with an announcement is check it against channels it already
holds. A transition rule per peer, like the correlation bridge, lets old
and new announcers coexist until the fleet has moved.

## Related

- Spec that created the seam: [digest-scoping rulings](../superpowers/specs/2026-09-30-digest-scoping-rulings.md) ("Recorded in the same docs pass").
- Parent: [Only tell a peer about the groups you both belong to](engine-scope-digests-to-shared-groups.md).
- Both twins; the Kotlin half of scoping shipped first (gossip-kt PR #20).
