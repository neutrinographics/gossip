# Sweep the remaining minor architecture-audit findings in the Kotlin library

**Track:** Kotlin port   **Depends on:** batch F of the architecture remediation (merged first)

## What this is

The Kotlin architecture audit of September 2026 produced a handful of small
findings that no design batch owned: a status string that should be a typed
value, a stop sequence written three times, a channel that vanishes between
two reads without a log line, a collaborator that may be absent with no
stated reason for the silence, a duplicated congestion check, a stale size
comment, a dropped message priority, two homes for the same timeout
constants, a doc comment naming the wrong caller. Batch E's reviews added a
few more of the same size: two registry methods that return the same
nullable type with opposite meanings (the status entered versus the status
left), a compaction scheduler built even when compaction is off, a value
object that does not validate itself, and a health read taken as two reads.

This item takes them as one small batch — batch G — after the structural
batches and before the server bump, so the bump carries a library with no
known small mistakes rather than a list of them.

## Why it matters

Each item alone is cheap and harmless; together they are the kind of drift a
later audit re-finds and re-argues. Taking them in one reviewed pass, with
the same gates and the same whole-branch review the design batches had,
closes the audit rather than leaving a tail.

## Rough approach

One plan, mechanical tasks batched by file, test-first where behaviour is
observable (a log line, a typed value on a published event), behaviour
preserved everywhere else. One consumer-visible change to call out at the
bump: the typed operation on the skipped-operation event, if taken.

## Related

- The audit and its addenda: [Kotlin architecture audit (2026-09-23)](../audits/2026-09-23-kt-architecture-audit.md)
  — findings KCA1-30, 31, 33, 34, 41, 43, 44, 45, 46, the batch E and F
  observations, and a check of KCA1-36.
- The rulings the batches executed: [remediation rulings](../superpowers/specs/2026-09-23-kt-architecture-remediation-rulings.md).
- Parity: [the divergence register](kt-normalize-twin-divergences.md) and
  [the parity program](../parity.md) — retention's package and the engine's
  constructor width are shared items there, not sweep work.
