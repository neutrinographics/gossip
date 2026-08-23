# Piggyback sync summaries on liveness probes

**Track:** Sync engine   **Depends on:** nothing

## What this is

The sync loop and the failure-detection loop each wake the radio on their
own schedule and never share a message. SWIM's defining optimization — and
what comparable systems like memberlist do — is the opposite: let the
liveness probe carry a small sync summary (a digest or digest hash), so one
radio wakeup serves both purposes. The complementary half already shipped:
sync traffic now counts as liveness evidence and suppresses probes.

## Why it matters

In steady state the two loops are most of the remaining idle traffic. One
combined message per window instead of two halves the wakeups the pacing
work already made rare.

## Rough approach

The membership context's probe carries an opaque payload supplied by a
sync-provided hook and decoded by sync's own codec — the contract crosses
the `PeerDirectory` port (or a sibling seam beside it), so neither context
names the other's types and the boundary rule holds.

## Related

- Finding WIRE4-19 in
  [audits/2026-08-20-wire-scheduling-audit.md](../audits/2026-08-20-wire-scheduling-audit.md);
  anticipated as a future port extension in
  [the bounded-contexts spec](../superpowers/specs/2026-08-21-bounded-contexts-restructure-design.md).
- The shipped complementary half: probe suppression by recent contact
  (WIRE4-3, ADR-013 amendment).
