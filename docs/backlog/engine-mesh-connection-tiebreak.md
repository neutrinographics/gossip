# One Bluetooth link per device pair in a mesh

**Track:** Sync engine   **Depends on:** nothing

## What this is

In a mesh, every device both advertises and scans, so two devices routinely
discover each other at the same time and *each* opens a connection to the
other — leaving two physical Bluetooth links where one would do. There is
currently no way to break the tie before connecting, because a scan result
does not reveal the other device's identity; only after the link is up do we
learn who we reached and reject the duplicate — by which point the radio
resources were already spent, and the "rejected" link often stays physically
open anyway.

The fix is to embed each device's identity (or a short hash of it) in its
Bluetooth advertisement, so a scanner can apply a simple deterministic rule —
e.g. "the lexicographically smaller identity initiates" — *before* opening a
connection. One initiator per pair, every time.

The project docs also promise a star-topology discovery filter ("spokes only
connect to the hub") that the code does not actually offer. Either add the
filter or correct the docs as part of this work.

## Why it matters

At the recommended scale of 8 devices per channel, mutual connects can hold
up to 14 concurrent links per device — roughly double typical platform
ceilings — causing connection storms exactly at the advertised target scale.
The failure is invisible: the connection registry reports the deduplicated
count, not the physical one. This is the highest-impact open finding from the
2026-07-08 audit (COR3-29).

## Rough approach

- Put the node identity (or a collision-resistant hash) into the BLE
  advertisement payload.
- On scan, compare identities and only initiate when the local device wins
  the tie-break; the loser waits to be connected to.
- Add the star discovery filter (connect only to a named hub) or fix the
  README/CLAUDE.md claims that it exists.

## Related

- Audit finding COR3-29 in
  [audits/2026-07-08-comprehensive-audit.md](../audits/2026-07-08-comprehensive-audit.md).
- [Tell a rejected Bluetooth peer it was rejected](engine-reject-notify-capped-peers.md)
  — the other half of duplicate/cap handling; both touch the wire formats.
