# Port the wire-efficiency behaviors to the Kotlin library

**Track:** Kotlin port   **Depends on:** nothing

## What this is

The Kotlin port (the separate `gossip-kt` repository) predates the entire
2026-08 wire-efficiency campaign. It still runs both scheduling loops at
their latency-derived cadence forever: no quiescence pacing, no probe
suppression by recent contact (nor the 2-minute suppression cap that
bounds one-way-loss detection), no responder-side exchange recording, no
recency suppression, no dominance-filtered digest responses. This item
ports those behaviors.

## Why it matters

Any deployment on the Kotlin side pays the idle-traffic cost the Dart
library no longer pays — roughly an exchange per second instead of one per
30 seconds on a converged network. The wire changes are interop-safe
(time-based scheduling, response filtering), so mixed Dart/Kotlin meshes
work throughout an incremental port.

## Rough approach

Mirror the Dart designs one-for-one: the pure pacing state machine in both
loops, the news triggers, suppression + cap, responder recording, and the
dominance filter — each with the Dart test suite translated. The Dart specs
and ADR-013's amendment are the authority.

## Related

- Dart implementation trail: recommendations R3/R4 of
  [audits/2026-08-20-wire-scheduling-audit.md](../audits/2026-08-20-wire-scheduling-audit.md),
  spec [2026-08-20-two-tier-pacing-design.md](../superpowers/specs/2026-08-20-two-tier-pacing-design.md).
- Siblings: [Mirror the bounded-context structure in the Kotlin library](kt-mirror-bounded-contexts.md),
  [Audit the Kotlin library for the bug classes fixed in Dart](kt-audit-legacy-bug-classes.md).
