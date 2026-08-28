# Audit the Kotlin library for the bug classes fixed in Dart

**Track:** Kotlin port   **Depends on:** nothing

## What this is

The Kotlin port was written from the Dart library as it stood before the
2026-07 audit remediation, so the bug classes those audits found and fixed
in Dart may exist in Kotlin unexamined: scheduler forking (restarts
spawning duplicate timer loops), silent duplicate-append drops, version
vectors regressing on compaction, and the compaction late-joiner lockout.

The audit itself has been done. Its deliverable is a written inventory of
thirteen differences between the two libraries, each with the Dart fix that
closed it and what the Kotlin equivalent would be. What remains is working
through that inventory, which is organised as a short sequence of batches:
the storage contract first (because several later fixes depend on how
entries are stored and rejected), then the wire format, then compaction, and
so on. The first batch has shipped.

## Why it matters

These were the highest-severity findings the Dart audits produced; the
Kotlin code inherited the same designs. Checking against a known defect
list is cheap compared to rediscovering them in production.

## Rough approach

Take the inventory in order, one batch per sitting, each with the Dart
regression tests translated so a fix cannot quietly regress. Batches whose
changes are only reachable through explicit application calls can ship
ahead of the rest without any deployment risk.

## Related

- **First batch done** (2026-08-29) — the storage-contract batch shipped in
  gossip-kt `1ffbf0d..3836bc7` on `feature/compaction`: entry storage gained
  a compaction floor, a high-water sequence mark that never regresses, and
  fail-fast construction guards, all pinned by a shared contract test.
- The inventory this works through:
  [Kotlin port fix inventory](../superpowers/specs/2026-08-28-kt-port-dart-fix-inventory.md).
- The wire-format batch and everything entangled with it live in
  [Teach both libraries to speak versioned wire formats](kt-wire-versioning-campaign.md).
- Source lists: [audits/2026-07-06-correctness-audit.md](../audits/2026-07-06-correctness-audit.md),
  [audits/2026-07-08-comprehensive-audit.md](../audits/2026-07-08-comprehensive-audit.md).
- Siblings: [Port the wire-efficiency behaviors to the Kotlin library](kt-port-wire-efficiency.md),
  [Mirror the bounded-context structure in the Kotlin library](kt-mirror-bounded-contexts.md).
