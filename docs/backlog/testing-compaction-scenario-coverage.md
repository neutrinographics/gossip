# Cover the compaction state space with scenario tests

**Track:** Testing   **Depends on:** nothing

## What this is

Compaction (pruning old entries under a retention policy) interacts with
almost everything: late joiners, returning peers, multi-author streams,
the digest budget, and in-flight syncs. The 2026-07 audits' one critical
bug lived exactly in those interactions. This item is the scenario suite
that pins them: a full simulated-network test of the original lockout
scenario (a late joiner converging with a compacted responder, then the
link going quiet — no futile re-send loop), transitive floor propagation
(a newcomer syncing truncated history second-hand from a peer that never
compacted anything itself), a returning peer skipping a pruned gap while
keeping its own older entries, prune-everything followed by new appends,
per-author floors, the dominance filter never hiding a compacted
responder, and a compaction landing mid-sync without wedging the
exchange.

## Why it matters

Each scenario is a regression trap for a bug class that was either found
in production-shaped code (the lockout) or designed against but never
pinned (transitive floors). With these in place, a change that breaks any
compaction interaction fails a named test instead of shipping.

## Related

- Shipped in 94e515a..e9f055e alongside the responder digest-rotation fix
  (OBS-3, recorded on
  [the minor-findings sweep](health-minor-findings-sweep.md)).
- The original critical: COR3-1 in
  [audits/2026-07-08-comprehensive-audit.md](../audits/2026-07-08-comprehensive-audit.md).
- The push flush-time nuance these tests surfaced lives with
  [push scoping](engine-push-scoping.md).
