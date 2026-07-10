# Tell a rejected Bluetooth peer it was rejected

**Track:** Sync engine   **Depends on:** nothing

## What this is

When a device is at its connection limit (or already holds a link to the same
peer) and another device connects to it inbound over BLE, the receiving side
"rejects" the newcomer — but has no way to actually close the link from its
side, because the BLE role it holds (peripheral) offers no per-client
disconnect. The rejected peer is never told anything: its writes are
acknowledged at the radio level and silently discarded above, so it believes
the connection is healthy and keeps gossiping into the void indefinitely,
burning one of its own connection slots and radio time.

The fix is an explicit, in-band "you were rejected" message sent back on the
still-open link (outbound sends on that link do work). On receiving it, the
rejected side — which *can* disconnect, being the central — tears the link
down and moves on.

## Why it matters

Two devices meeting at a capacity boundary currently degrade permanently and
invisibly: one wastes a slot talking to a wall, the other wastes radio
servicing writes it drops. Deferred from the 2026-07 audit remediation
(finding COR3-21) because it needs a small wire-format change.

## Rough approach

The BLE data channel today carries only opaque gossip payloads, so a control
message needs a discriminator — a type byte in the framing layer
distinguishing "application data" from "control: rejected". Version-skew note:
an old peer that doesn't understand the frame just ignores it, which is no
worse than today.

## Related

- Audit finding COR3-21 in
  [audits/2026-07-08-comprehensive-audit.md](../audits/2026-07-08-comprehensive-audit.md).
- [One Bluetooth link per device pair in a mesh](engine-mesh-connection-tiebreak.md)
  — removes the *duplicate*-rejection case entirely; this item still covers
  the capacity-limit case.
