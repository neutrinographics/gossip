# Retiring indirect probing — decision record

_Awaiting owner review. This is the spec-level document for the "is SWIM
worth it?" question (owner, 2026-09-01); the ruling lands in the Review
outcome section at the bottom._

## The question

The library's failure detection is described (ADR-004) as SWIM. Is the
machinery earning its keep — and specifically, which parts?

## What the library actually implements

SWIM proper is three mechanisms: probing (direct + indirect through a
relay), **dissemination** (membership verdicts piggybacked epidemically so
the cluster converges on one view), and **refutation** (incarnation numbers
so a wrongly-suspected node can clear its name). This library implements
only the probing. ADR-007 makes membership deliberately *local* — no node
ever tells another who it thinks is alive — and the incarnation machinery
was ruled dead scaffolding on 2026-09-01 (never built in Dart; zero
production callers in Kotlin).

That changes what indirect probing is for. In real SWIM it prevents a
catastrophic failure mode: one node's false "dead" verdict is gossiped and
a living node is evicted cluster-wide. Here a verdict never leaves the node
that formed it — a false positive costs that one node some skipped sends
until contact recovery clears it. **The failure mode the relay defends
against cannot occur in this library.**

## Options

**A — keep as-is.** Indirect probing stays on both sides; the Kotlin relay
defect gets fixed as planned.

**B — slim (recommended).** Retire indirect probing on both sides. Keep
direct probing as the idle keepalive, the three-state grading, the
unreachable slow-probe recovery, the late-ack grace, and the RTT feed.

**C — passive only.** No dedicated probes; liveness from transport link
events plus sync-traffic recency. **Rejected**: quiescence pacing makes a
converged mesh deliberately quiet, so passive observation cannot
distinguish "paced and healthy" from "dead" — an active idle probe is
load-bearing.

## The case for B

1. **The protection protects nothing.** Without dissemination, the relay's
   entire purpose — insulating the cluster from one node's false verdict —
   has no referent (see above).
2. **Its local effect is counterproductive.** Keeping a one-way-deaf link
   marked reachable keeps the node sending into a link that cannot answer,
   while the data converges transitively through any healthy third node
   regardless — the Kotlin suite's "entries converge through the relay
   while one direction is deaf" test pins exactly that transitive path.
3. **Production evidence.** The Kotlin relay has been structurally inert
   since the port — the server fleet has effectively been running option B
   on the Kotlin side the whole time, unnoticed.
4. **The no-relay behavior is already specified and tested.** Both suites
   carry the deaf-pair contrast group: the deaf side eventually suspects
   its peer, and recovers after the heal via the unreachable slow-probe
   cycle (one recovery probe every `unreachableProbeInterval` rounds,
   default 5). Option B makes the already-tested degradation path the
   universal one.

## What B preserves — explicitly

- **Direct probing as idle keepalive.** Probe suppression by recent contact
  (already in Dart, queued for Kotlin) means probes mostly fire when sync
  is quiet — which is exactly when they carry information.
- **Three-state grading and thresholds** — `reachable → suspected →
  unreachable` still gates gossip partner selection and push fan-out.
- **Unreachable recovery probing** (the slow cycle above).
- **The late-ack grace (ADR-012), generalized not lost.** Today the grace
  window that rescues an ack arriving just after the direct timeout is
  implemented *by* the indirect phase, with an explicit equal-length wait
  when no intermediaries exist (the 2-device case). Under B, every probe
  takes the 2-device shape: direct timeout → grace wait → late-ack check →
  verdict. Same protection, one code path.
- **The RTT feed** into adaptive timing (ADR-013).

## What B removes

- **Dart:** the relay handler (`_handlePingReq`), the indirect phase of the
  probe cycle (`_performIndirectPing` collapses into the pure grace wait),
  intermediary selection, the forwarded-ack allowance on pending pings and
  the forwarded-ack RTT exclusion. The asymmetric-partition "with relay"
  *reachability* test goes (it pins removed behavior); the
  convergence-through-relay test **stays** — transitive sync remains true
  and pinned.
- **Kotlin:** `handlePingReq`, `selectRandomIntermediaries`,
  `INTERMEDIARY_TIMEOUT`, and the same indirect-phase collapse.
- **Wire:** `PingReq` follows the dialect playbook's retirement shape —
  **receive forever** (the mixed fleet still sends it), **send never**,
  delete the encoder at the next dialect revision. The v1-kt
  `originalRequester` quirk retires with it.

## Behavior change to document

A one-way-deaf pair now degrades honestly: each side eventually marks the
other unreachable and stops direct traffic, entries keep converging through
any healthy third node, and the pair recovers after the heal via slow
probes. Applications may see `unreachable` status for a peer that a relay
could have vouched for — intended, and arguably more truthful: "I cannot
usefully exchange data with this peer directly" is what the status gates.

## Consequences for tracked work

| Item | Effect under B |
|---|---|
| [Make the Kotlin library's indirect health probing actually work](../../backlog/kt-swim-indirect-probing-inert.md) (High) | **Closed by removal** — the defect is deleted, not fixed |
| Receive-loop lifecycle batch ([rulings](2026-09-01-receive-loop-lifecycle-rulings.md)) | Ruling 1 (launch the relay off the collector) is **mooted**; the detector's monitor guard **stays** (its races predate and outlive relaying); the batch shrinks to lifecycle + cancellation + guard, and absorbs the Kotlin-side removal (same files, same review) |
| [Scenario parity sweep](../../backlog/kt-scenario-parity-sweep.md) | The one withheld relay scenario becomes obsolete rather than pending |
| [SWIM threshold tuning](../../backlog/engine-swim-threshold-tuning.md) | Unaffected — thresholds remain |
| [Digest-on-probe piggyback](../../backlog/engine-digest-on-probe-piggyback.md) | Unaffected — direct probes remain |
| [Wire-efficiency port](../../backlog/kt-port-wire-efficiency.md) (probe suppression) | Unaffected; arguably more central once probes are keepalive-only |
| [Probe selection parity](../../backlog/kt-probe-selection-parity.md) | Unaffected — fair rotation and timing policies concern direct probing |
| ADR-004 | Revised: the indirect-probe half of the decision is retired with this record as rationale; consider renaming the mechanism in docs from "SWIM" to plain probe-based failure detection, since neither dissemination, refutation, nor indirect probing remain (ubiquitous-language hygiene) |
| ADR-012 | Amended: the grace period becomes the universal probe shape |
| [Parity program](../../parity.md) | No exemption needed — both sides converge on the same slimmer detector |

## Sequencing if ruled B

1. Dart first (it is the reference): remove the send side and relay
   handler, generalize the grace wait, revise ADR-004/012, adjust the
   asymmetric-partition suite.
2. Kotlin follows inside the receive-loop lifecycle batch (amended rulings
   page), which was already touching the detector.
3. `PingReq` decode retirement rides the wire playbook's existing step 8.

## Open points for the owner

1. The ruling: A or B.
2. If B — confirm the lifecycle batch absorbs the Kotlin-side removal
   (recommended) rather than a separate batch.
3. If B — confirm the documentation rename away from "SWIM."

## Review outcome

_Pending owner review._
