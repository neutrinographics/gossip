# Share the ubiquitous-language glossary across the twins

**Track:** Kotlin port   **Depends on:** nothing

## What this is

The Dart repository has a glossary: one line per domain term, grouped by the
bounded context that owns it — the project's ubiquitous language, written
down. The Kotlin repository has nothing equivalent, and nothing that points
at the Dart one.

This item makes the glossary a shared, single-sourced artifact: the Dart copy
stays normative (the Kotlin README already declares the Dart repository the
source of protocol truth), the Kotlin repository points to it prominently,
and the terms are checked against the Kotlin class and package names so the
two codebases demonstrably speak the same language.

## Why it matters

Ubiquitous language is half of structural parity. The package trees now
mirror each other; the vocabulary should too, and it should be checkable — a
term that exists in the glossary but names a class in only one codebase is a
parity gap in exactly the way a missing feature is. A shared glossary is also
the cheapest onboarding artifact the twin setup has.

## Rough approach

Single-source: keep the Dart file normative, add a pointer (not a copy) from
the Kotlin repository, and do one reconciliation pass — every glossary term
resolves to the same concept name in both codebases, with any Kotlin-only or
Dart-only names either renamed or added to the glossary. Consider a light
check (grep-based) that keeps the reconciliation from rotting.

## Related

- The glossary: `GLOSSARY.md` at the Dart repository root.
- Part of the structural-parity dimension of the
  [twin parity program](../parity.md).
- Sibling: [Mirror the bounded-context structure in the Kotlin library](kt-mirror-bounded-contexts.md)
  (the package-tree half, already shipped).
