# Make the server's entry store keep the library's repository contract

**Track:** Server   **Depends on:** nothing

## What this is

The Kotlin library publishes a contract test that any entry store must
pass: a fixed list of behaviours the sync engine relies on, from "reads
come back in one total order" to "a compaction floor is only ever raised
past entries that were actually removed". The server's Postgres entry
store was run against that contract for the first time during the item 9
bump (2026-09-23). It passed 30 of 36 cases. The two ordering cases were
the bump's own fix and are green now. The four remaining failures are all
about the compaction floor, and one of them changes what peers are told.

## Why it matters

The compaction floor is the server's statement to every phone of "entries
below this point are gone; do not ask for them". If the floor is raised
past entries the server still holds, a phone that needs those entries is
told they are unobtainable and stops asking, which is the same shape as
the late-joiner lockout the July audit found on the phone side and fixed
there. The server's floor logic today raises the floor for every author a
peer's claim names, even when the claim is at or below what the server
already holds; the contract says such claims are ignored. Whether a real
room has hit this is unknown, and the sync-check tooling can answer that.

The other three failures are cosmetic: the server writes a marks row with
a floor of zero on every append, so its floor vector names authors the
in-memory store leaves out. The answers agree; the vectors are not equal.

## Rough approach

Fix the behavioural half in the floor-adoption method so a claim at or
below the current high-water mark leaves the floor alone, with the
contract's own test as the pin. Decide the cosmetic half either way (omit
the zero rows from the vector, or state in the contract that a zero entry
is equivalent to absence). Then replace the server's Postgres-only
ordering test with the contract subclass the bump had to remove, so every
future divergence surfaces at once. A functional index on the new sort
order is worth an EXPLAIN on the delta path while there.

## Evidence

The four failing cases, from the run recorded in the bump's ledger:

- `getCompactionFloor returns empty when nothing has been compacted` —
  expected an empty vector, got `{a → 0}`
- `adoptVersionFloor with an empty floor changes nothing` — same
- `adoptVersionFloor ignores claims at or below the current high-water mark`
  — expected 0, got 7
- `adoptVersionFloor raises each author independently` — expected 0, got 2

Root causes read from the adapter: the append path writes a marks row with
`floor = 0` for every author; the floor-adoption path calls the
raise-floor primitive unconditionally for every author in the claim.

## Related

- [Keep the server's inbound queue under a second in a meeting](server-inbound-queue-under-load.md)
  (the marks cache this touches)
- [Small follow-ups from the inbound-queue design audit](server-audit-follow-ups.md)
- The bump that found it: gossip-kt PR #9 and its opendoor-api companion
  (item 9 rulings, `superpowers/specs/2026-09-22-kt-bump-item-9-rulings.md`)
