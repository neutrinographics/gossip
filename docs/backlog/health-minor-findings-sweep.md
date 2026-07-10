# Sweep the remaining minor audit findings

**Track:** Code health   **Depends on:** nothing

## What this is

The catch-all closing round ("R14") of the 2026-07-08 audit: the MIN-series
minor findings plus two latent correctness items that were sized out of the
main remediation rounds:

- **Unbudgeted sync-request size (COR3-28).** The "what I already have"
  summary sent when requesting missing data is an unbounded list; a node
  whose summary for one stream outgrows the message size limit can advertise
  that stream but never pull it — a permanent, silent stall surfaced only as
  generic send failures. Bound it the same way the digests were.
- **Payloads are held by reference, not copied (COR3-30).** An application
  that reuses a scratch buffer after appending can corrupt what gets stored
  and synced — and because entry equality ignores payload bytes, local and
  remote copies can differ silently. Copy at the public API boundary.
- **The MIN-series**: dead types and phantom events, retention-policy input
  validation, safe parsing, documentation drift (including the root project
  docs claiming a mesh tie-break and star filter that don't exist — see the
  mesh item), unused dependencies, and a design note on the sync-request
  budget.

## Why it matters

Individually small; collectively they are the gap between "audited" and
"clean". The two correctness latents above are real bugs waiting on
unlucky inputs.

## Related

- Findings COR3-28, COR3-30 and MIN-* in
  [audits/2026-07-08-comprehensive-audit.md](../audits/2026-07-08-comprehensive-audit.md).
- [One Bluetooth link per device pair in a mesh](engine-mesh-connection-tiebreak.md)
  — implementing it resolves the doc-drift half of the tie-break claim.
