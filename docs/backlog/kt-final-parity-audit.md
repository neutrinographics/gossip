# Certify twin parity with a closing audit

**Track:** Kotlin port   **Depends on:** the rest of the Kotlin-port track

## What this is

The migration's finish line: a systematic audit that *certifies* the two
libraries are in full parity rather than assuming it because the worklist
emptied. It sweeps every parity dimension — features and behavior, structure,
ubiquitous language, scenario coverage, wire conformance, and the divergence
register — and its deliverable is a signed-off report plus a final state of
the parity program's exemption register in which every deliberate divergence
is ratified by the owner.

## Why it matters

Every gap this program has found so far was found by *looking* — audits and
reviews, not incidents. The items on the worklist are the gaps already known;
the closing audit is the guard against the ones nobody wrote down. It is also
what makes the program's central promise ("nothing skipped unless it
literally has no purpose in Kotlin") checkable: at the end, the exemption
register *is* the complete list of differences, and everything else matches.

## Rough approach

A fresh feature-surface diff of both libraries (public API, services, config,
events, errors), a structure and glossary reconciliation, a scenario-coverage
diff, a wire-vector re-verification, and a divergence-register closure check
(no row left unhomed). Findings become items or exemptions; the audit repeats
until it finds nothing. Run it only after the known worklist is empty —
sooner, and it just re-discovers the roadmap.

## Related

- The program it closes: [twin parity program](../parity.md).
- Precedents for the method: the
  [foundation audit](../superpowers/specs/2026-08-29-foundation-audit.md) and the
  [post-KT-B scoped audit](../superpowers/specs/2026-08-30-post-ktb-scoped-audit.md).
