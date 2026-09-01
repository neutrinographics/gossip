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
| E1 | Sublayer name `value_objects/` (Dart) vs `values/` (kt) | Kotlin package names cannot contain underscores | Structure mirror, 2026-08-29 |
| E2 | kt has no `DeltaMerger`/`KeyedTaskChain` | kt's single-collector receive loop structurally excludes the overlapping-merge hazard those exist to serialize | Divergence register, "Merge-path serialization" |
| E3 | kt domain services use monitor guards; Dart uses none | ADR-001 single-isolate execution is a Dart-only guarantee; kt runs on a multi-threaded dispatcher | Divergence register, "Thread-safety posture" |
| E4 | Version-vector explicit-zero handling differs | Tolerated asymmetry; the one real consequence was fixed consumer-side 2026-08-31 | Divergence register, "explicit-zero" row |
| E5 | kt keeps no `resume()`; `start()` doubles as resume | Deliberate smaller lifecycle surface; behavior contract identical | Receive-loop lifecycle rulings, 2026-09-01 (pending review) |

An exemption is falsifiable: if a later incident shows the skipped thing did
have a purpose, delete the row and open a port item.

## Open joint decisions

Divergences where neither side is simply "behind" — the twins should decide
once, together, or the shapes drift for no reason.

- **Where the in-memory test doubles live** — both libraries ship them in the
  main artifact; kt's are now substantial and kt has a separate published
  testing module. (Divergence register row.)
- **`PeerRepository`** — kt deliberately removed the interface (2026-03-27);
  Dart still has it. Restore in kt, or remove in Dart?
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
