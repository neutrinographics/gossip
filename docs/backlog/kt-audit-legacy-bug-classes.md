# Audit the Kotlin library for the bug classes fixed in Dart

**Track:** Kotlin port   **Depends on:** nothing

## What this is

The Kotlin port was written from the Dart library as it stood before the
2026-07 audit remediation, so the bug classes those audits found and fixed
in Dart may exist in Kotlin unexamined: scheduler forking (restarts
spawning duplicate timer loops), silent duplicate-append drops, version
vectors regressing on compaction, and the compaction late-joiner lockout.
This item is a targeted audit of the Kotlin code against that known
defect list — not a general review.

## Why it matters

These were the highest-severity findings the Dart audits produced; the
Kotlin code inherited the same designs. Checking against a known defect
list is cheap compared to rediscovering them in production.

## Rough approach

Walk the 2026-07 audit reports finding-by-finding, locate the Kotlin
counterpart of each fixed site, verify or fix with the Dart regression
test translated.

## Related

- Source lists: [audits/2026-07-06-correctness-audit.md](../audits/2026-07-06-correctness-audit.md),
  [audits/2026-07-08-comprehensive-audit.md](../audits/2026-07-08-comprehensive-audit.md).
- Siblings: [Port the wire-efficiency behaviors to the Kotlin library](kt-port-wire-efficiency.md),
  [Mirror the bounded-context structure in the Kotlin library](kt-mirror-bounded-contexts.md).
