# One Bluetooth link per device pair in a mesh

**Track:** Sync engine   **Depends on:** nothing

## What this is

In a mesh, every device both advertises and scans, so two devices routinely
discover each other at the same time and *each* opens a connection to the
other — two physical Bluetooth links where one would do, invisible to the
connection registry (which deduplicates by identity). At the recommended
8-device scale this approached double the platform connection ceilings.

Shipped as a **post-connect tie-break**: for any pair, the surviving link is
the one where the lexicographically smaller node identity is the central
("the smaller ID initiates"). The loser closes its *own* central link —
which is physically the same link as the winner's peripheral — so every
pair converges to exactly one link without needing the peripheral-side
disconnect API that Bluetooth doesn't offer. The brief double-connect
still happens (roughly one identify round-trip) and is accepted;
[a best-effort Android advertisement hash](engine-preconnect-adv-hash.md)
could shrink it further.

An earlier idea — embedding the identity in the advertisement so the
tie-break could happen *before* connecting — was rejected: iOS peripherals
cannot advertise manufacturer data, and backgrounded iOS demotes even
service UUIDs, so no advertisement channel works reliably across both
platforms.

Star topology needed no filter after all: only the hub advertises, so
spokes can only ever find the hub. The docs that claimed a discovery
filter were corrected instead.

## Why it matters

Connection storms at exactly the documented target scale, invisible in
production metrics. This was the highest-impact open finding of the
2026-07-08 audit (COR3-29).

## Related

- Audit finding COR3-29 in
  [audits/2026-07-08-comprehensive-audit.md](../audits/2026-07-08-comprehensive-audit.md).
- Design: [the spec](../superpowers/specs/2026-07-10-bluey-tiebreak-rejection-design.md)
  (includes the recorded "rejected premise" for the advertisement approach).
- [Tell a rejected Bluetooth peer it was rejected](engine-reject-notify-capped-peers.md)
  — shipped together; covers the capacity-rejection case the tie-break
  doesn't.
- Follow-up optimization:
  [Best-effort pre-connect identity hash on Android](engine-preconnect-adv-hash.md).
- Remaining test debt:
  [Close the recorded test debt from the tie-break/rejection reviews](../backlog/testing-tiebreak-followup-tests.md).
