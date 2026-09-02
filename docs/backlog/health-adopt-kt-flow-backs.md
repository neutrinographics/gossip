# Adopt the Kotlin twin's recorded improvements into the Dart library

**Track:** Code health   **Depends on:** nothing

## What this is

The twin-divergence register records every place where the Kotlin library
turned out to do something *better* than the Dart original — improvements
discovered while porting, which the program's ground rules say must flow back.
Two concrete defects from that list are already queued in the minor-findings
sweep; this item is the home for the rest, which today are registered but
routed nowhere.

The current flow-back set (the register's "kt better" rows) includes: the
single-dispatch frame seam that avoids double-reporting an unknown frame; the
non-throwing decode-result contract; partition healing that blocks links in
place instead of unregistering endpoints (the only shape that proves
heal-in-place recovery); the congestion test knob that pins the real gate
rather than a declared number; the simulated clock's move-time-only escape
hatch; the stricter configuration-disable idiom; compaction facades and
local-only compaction gating; and a set of test-strength idioms the Kotlin
reviews demonstrated.

Five more candidates came out of the Kotlin domain purification
(2026-09-02) — Dart-side reshapes that would let the twins' domain bodies
diff line-for-line: the round news flag moving from the gossip engine into
the gossip timing policy (`news()` raises it, `beginRound()` consumes it or
stretches); the scheduler's generation state as a small `LoopGeneration`
collaborator; a `ReportedGapRegistry` (Dart keeps that set inside the
delta merger); a `PendingPushes` buffer behind the reactive pusher; and the
explicit never-heard-from guard in the probe target selector's freshness
test. Each is a register row.

## Why it matters

The migration's ground rule is bidirectional: the Kotlin library catching up
to Dart is only half the contract. Every unadopted flow-back is a divergence
that will confuse the next port, and several of these are not style — the
partition-heal shape determines what the Dart recovery suite can actually
prove, and the dispatch/decode seam removes a real double-error.

## Rough approach

Work the register's "kt better" rows as a sweep, newest evidence first, each
row either adopted (with the register updated to "closed") or explicitly
exempted in the parity program with a reason. Rows that are pure test-idiom
adoptions can ride along with whatever suite is next touched for other
reasons.

## Related

- The rows themselves:
  [Record where the Dart library and its Kotlin twin diverge, with a verdict](kt-normalize-twin-divergences.md).
- Two rows already queued elsewhere:
  [Sweep the remaining minor audit findings](health-minor-findings-sweep.md).
- Governed by the [twin parity program](../parity.md) (convention 2: rows end
  homed, closed, or exempted).
