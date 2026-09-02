# The twin parity program

The gossip library exists twice: this repository (Dart, the phones) and
[gossip-kt](https://github.com/neutrinographics/gossip-kt) (Kotlin, the
server). They gossip with each other directly, so they are two halves of one
system, not a library and a port that drifted apart.

**The program goal (owner, 2026-09-01):** at the end of the migration the two
libraries are in **full parity** — feature-wise and structurally (bounded
contexts, ubiquitous language, test coverage, wire behavior). Every Dart
feature is ported to Kotlin unless it *literally has no purpose in Kotlin*,
and any such skip is an explicit, recorded exemption in this document — never
a silent omission. Improvements uncovered on either side are adopted by the
other. All of it is tracked in the repositories, not in anyone's memory.

This document is the program's index: it owns the **exemption register**, the
**open joint decisions**, and the **working conventions**. It deliberately
owns no per-item status or priority — those live only in
[the roadmap](roadmap.md) (mostly the *Kotlin port* track), per the roadmap
conventions.

## Parity dimensions and their authoritative trackers

| Dimension | What parity means | Where it is tracked |
|---|---|---|
| Features & behavior | Every behavior in one library exists in the other, or is exempted below | Roadmap *Kotlin port* track; the [fix inventory](superpowers/specs/2026-08-28-kt-port-dart-fix-inventory.md); the [wire campaign register](backlog/kt-wire-versioning-campaign.md) |
| Structure | Same bounded contexts (`shared`/`sync`/`membership`/`coordinator`), same sublayers, machine-checked boundaries | Both repos' `CLAUDE.md` (Dart normative) + both boundary tests; shipped via [the structure mirror](backlog/kt-mirror-bounded-contexts.md) |
| Ubiquitous language | One glossary, both codebases speak it | `GLOSSARY.md` (Dart repo, normative); [sharing item](backlog/kt-shared-glossary.md) |
| Tests & scenarios | The scenario suites prove the same contracts; translations cite their source | [Scenario parity sweep](backlog/kt-scenario-parity-sweep.md); the test-citation convention below |
| Wire | Byte-identical dialects, proven against one canonical vector set | [Wire versioning spec](superpowers/specs/2026-08-28-wire-versioning.md); conformance vectors vendored in both repos with drift tests |
| Improvement adoption | Anything one side does better flows to the other — both directions | [Divergence register](backlog/kt-normalize-twin-divergences.md) (the record); [Dart flow-back item](backlog/health-adopt-kt-flow-backs.md) and the kt-track port items (the closure) |
| Deployment | The mixed fleet never breaks while the twins converge | Wire campaign §5.3 flip playbook (steps 1–5 shipped 2026-08-31; the send-side flips 6–8 remain, gated on fleet coverage) |

**How to read current status:** the roadmap's *Kotlin port* track is the
worklist; the divergence register is the debt ledger (every row must be
*homed* to a roadmap item, *closed*, or *exempted here*); the wire campaign
register carries the deployment steps. The [closing audit](backlog/kt-final-parity-audit.md)
is the program's finish line: parity is *certified*, not assumed.

## Exemption register

The only legitimate reasons to skip a port: the feature is meaningless on the
other platform, or the platforms' execution models demand different
mechanics for the same contract. Each exemption names its reason and where it
was decided. Anything not listed here is expected to reach parity.

| # | Divergence | Reason | Decided |
|---|---|---|---|
| E1 | Sublayer name `value_objects/` (Dart) vs `values/` (kt) | Kotlin package names cannot contain underscores. Normalizable only by Dart renaming *toward* the forced abbreviation — kept, because "value object" is the domain term and Dart is the normative side | Structure mirror, 2026-08-29; upheld on review, 2026-09-01 |
| E2 | kt has no `DeltaMerger`/`KeyedTaskChain` | The *contract* is identical (no two merges for one channel/stream ever interleave); only the mechanism differs — kt's serial collector structurally excludes the hazard those exist to serialize, so porting them would be dead code. Reassess only if Dart ever adopts a single-dispatch receive loop | Divergence register, "Merge-path serialization"; upheld on review, 2026-09-01 |
| E3 | kt needs thread safety Dart never will (ADR-001 is Dart-only; the single-threaded-confinement alternative was rejected: it would serialize the server's suspending repository work and still not cover the non-suspend lifecycle facade) — but **NARROWED 2026-09-02 (owner)**: the exemption covers only *infrastructure wrappers, coroutine-scope parameters, volatile lifecycle flags, and application mutexes whose critical sections suspend across repository IO*. Locks inside domain classes are NOT exempt — the domain stays pure, per [the purification item](backlog/kt-pure-domain-concurrency.md) | Divergence register, "Thread-safety posture"; upheld 2026-09-01, narrowed 2026-09-02 |

An exemption is falsifiable: if a later incident shows the skipped thing did
have a purpose, delete the row and open a port item. The first review
(owner, 2026-09-01) did exactly that to two drafted entries: version-vector
explicit-zero handling is now a **normalization** (kt adopts Dart's
construction-time zero-dropping; homed as KT-E scope in the
[wire campaign register](backlog/kt-wire-versioning-campaign.md)), and kt
**gains `resume()`** for API and vocabulary parity (folded into the
receive-loop lifecycle batch's rulings).

## Open joint decisions

Divergences where neither side is simply "behind" — the twins should decide
once, together, or the shapes drift for no reason.

- **Where the in-memory test doubles live** — both libraries ship them in the
  main artifact; kt's are now substantial and kt has a separate published
  testing module. (Divergence register row.)
- **Local-only mode semantics** — Dart gates auto-compaction on having a time
  source; kt compacts regardless. The register recommends Dart adopt kt's
  behavior; until ruled, this is a live behavioral divergence.
- **Whether gossip-kt commits should be signed** (owner question, carried
  from the wire campaign).

## Working conventions

1. **Companion items.** When a behavior item lands in one library, the same
   docs pass creates (or updates) the port item for the other — the way
   [stalled-range suppression](backlog/engine-stalled-range-request-backoff.md)
   got [its kt companion](backlog/kt-stalled-range-suppression-port.md) while
   still a spec. Open Dart items flagged for this on landing:
   [digest scoping](backlog/engine-scope-digests-to-shared-groups.md),
   [push scoping](backlog/engine-push-scoping.md).
2. **The register duty.** Every batch review asks "did either side do this
   better?" and writes a register row. A row must end up *homed* (routed to a
   roadmap item), *closed* (with the fixing commit), or *exempted* (moved
   here). "Registered but unhomed" is a defect state this program's reviews
   look for.
3. **Test citations.** Every translated test cites the source file it came
   from (the kt suite already does this); the citation trail is the
   finest-grained parity ledger we have.
4. **Review gate.** The owner reviews *spec-level* documents (a backlog item,
   a spec, a rulings page) — never plan-level ones. Plans are execution
   material for the agents running a batch.
5. **Docs truth passes.** Every batch ends by truthing the roadmap, the
   register, and this document in the same commit-cycle as the code.

## Related

- [Wire versioning spec](superpowers/specs/2026-08-28-wire-versioning.md) —
  the deployed-compatibility contract everything above must respect.
- [Kotlin port fix inventory](superpowers/specs/2026-08-28-kt-port-dart-fix-inventory.md) —
  the original 13-item catch-up list; closure tracked per batch.
- [Closing audit](backlog/kt-final-parity-audit.md) — how the program ends.
