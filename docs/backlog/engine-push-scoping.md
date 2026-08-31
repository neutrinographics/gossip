# Send reactive pushes only to peers that share the data

**Track:** Sync engine   **Depends on:** nothing

## What this is

When a device writes a new entry, it immediately pushes that entry to its
peers (the "reactive push"). Today that push goes to every reachable peer
and ignores the congestion gate, even though some peers may not be members
of the channel the entry belongs to, and a congested link gains nothing
from more traffic. This item scopes the push to peers that actually share
the channel, applies the same per-peer congestion gate the periodic loop
already uses to pushes and request bursts, and caches the per-peer channel
membership so digests can shrink too.

## Why it matters

Every needless push is a radio wakeup and airtime on a Bluetooth link that
may already be struggling. On small meshes the waste is modest; as channel
membership diverges from mesh membership it grows linearly.

## Rough approach

Scope push fan-out by channel membership; consult the per-peer pending-send
gate on the push and delta-request paths (responses may stay exempt —
serving is cheap for the requester's progress); keep a per-peer cache of
shared channels that also trims digest construction.

While reworking the push path, also make its timing semantics deliberate:
the debounced push freezes the entries at append time but picks its
recipients (who is reachable) at flush time — and never re-consults the
repository in between, so an unflushed batch can outlive a compaction or
be handed to a peer that connected inside the debounce window, carrying
entries the sender no longer durably holds. Benign today (entries are
immutable, and a mismatched delivery is either useful or dropped and
repaired by anti-entropy) — surfaced by the 2026-08 compaction test
hardening; decide and document buffer-time vs flush-time on purpose.

## Related

- Findings WIRE4-6, WIRE4-11, WIRE4-20 (recommendation R6) in
  [audits/2026-08-20-wire-scheduling-audit.md](../audits/2026-08-20-wire-scheduling-audit.md).
- Sibling: [Coalesce wire traffic into fewer radio wakeups](engine-message-coalescing.md).
- Closest sibling: [Only tell a peer about the groups you both belong to](engine-scope-digests-to-shared-groups.md)
  — the same "does this peer share the data?" question, asked of the summary
  exchange rather than of reactive pushes. A membership notion built for
  either one should serve both.
