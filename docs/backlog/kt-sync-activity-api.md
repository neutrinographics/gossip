# Port the sync-activity snapshot API to the Kotlin library

**Track:** Kotlin port   **Depends on:** nothing

## What this is

The Dart library can answer "are we still syncing, or up to date?" — a small
public snapshot exposing whether pulls are outstanding, whether the node has
gone quiet, and how much has been merged. Applications use it to show a
"syncing…" indicator honestly instead of guessing from timers.

The Kotlin library has no equivalent. It exposes lifecycle state, health, and
resource counters, but nothing an application can use to distinguish "busy
converging" from "converged".

## Why it matters

This is public-API parity: an application feature built on the Dart snapshot
(a sync spinner, a "safe to go offline" affordance) cannot be mirrored
server-side or in any future Kotlin client. Parity in observable state is
also what keeps operational dashboards comparable across the fleet and the
server.

## Rough approach

Port the snapshot type and its feeding points (pull tracking, quiescence,
merge counters). Note the quiescence half depends on the idle-pacing
machinery the Kotlin side doesn't have yet — either port that first or land
the snapshot with the quiescence field wired to its precursor signal.

## Related

- Found untracked by the 2026-09-01 parity survey; recorded in the
  [twin parity program](../parity.md).
- The quiescence machinery belongs to
  [Port the wire-efficiency behaviors to the Kotlin library](kt-port-wire-efficiency.md) —
  sequencing dependency, wire the two together.
