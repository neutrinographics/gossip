# Dart half of the relay retirement — rulings for review

The Dart batch for roadmap item 8: the Dart side of
[retire indirect health probing from both libraries](../../backlog/kt-retire-indirect-probing.md),
ruled B in the [decision record](2026-09-01-swim-slimdown-decision.md)
(owner, 2026-09-01) and shipped Kotlin-first in gossip-kt ea0d51c
(2026-09-15, per ruling 9 of the
[lifecycle rulings](2026-09-01-receive-loop-lifecycle-rulings.md)). The
decision record carries the what and why; this page carries only the
decisions that need the owner's eye before the Dart code moves. The
implementation plan follows this page and is execution material for the
agents, not for review.

Acceptance is fixed in advance: the whole core suite stays green with the
relay tests gone and the four new pins below in; the asymmetric-partition
suite pins the honest degradation with a third node present; both twins'
detectors read the same probe shape line for line.

## What Kotlin did (the shape Dart matches)

Read from gossip-kt a91404a and 67aa062, the two commits of the batch that
touched the detector:

- A probe is: direct Ping → per-peer adaptive timeout → **grace window** of
  one more per-peer timeout, re-read at entry, **racing the still-open
  pending ping** so a late Ack ends the wait the instant it lands → verdict.
  The pending entry is dropped only after the grace closes. No second
  sequence, no second frame.
- The unreachable-recovery probe takes the same shape; the new-peer RTT
  bootstrap probe does not (one timeout, no verdict, so nothing to grace).
- An inbound relay request is decoded, its bytes counted on the sender's
  metrics, one log line written, and nothing else: no Ping to the target,
  no Ack back, no contact recorded for the sender, no error, no wait.
- Intermediary selection, the relay fan-out, the intermediary timeout, and
  the forwarded-Ack allowance were deleted; the ack-sender guard is
  unconditional; RTT still lands on the pending target, which the guard now
  makes the same node as the Ack's sender.
- The `PingReq` type, its codec (both directions), and every wire fixture
  stayed byte-untouched.
- Nothing numeric changed. The probe-interval multiplier of 3 kept its
  value and got a new rationale: room for the direct probe and its grace
  window, plus slack.
- The rename away from "SWIM" was deferred to this batch, so Kotlin still
  ships the `[SWIM]` log prefix and "SWIM" in its README and CLAUDE.md.

## Rulings

1. **Removal scope is the decision record's, exactly.** Dart deletes the
   relay handler (`_handlePingReq`), the indirect phase
   (`_performIndirectPing`, the fan-out constant, `_sendPingRequests`),
   intermediary selection (`ProbeTargetSelector.selectIntermediaries`), the
   forwarded-Ack allowance on pending pings (`allowForwarded`), and the
   forwarded-Ack RTT exclusion. The ack-sender guard Dart already has
   becomes unconditional. An inbound `PingReq` is decoded and ignored with
   one log line. Dart already counts every received frame once, in the
   sync engine, so the "still counts" half of Kotlin's ruling 12 holds with
   no detector code. As in Kotlin, an ignored relay request records no
   contact for its sender: it is not proof the sender can hear us.

2. **The grace window adopts the Kotlin race.** After the direct timeout the
   probe waits one more per-peer adaptive timeout, re-read at entry, on the
   same still-open pending ping, and returns the moment a late Ack lands
   instead of sleeping the full window (the flow-back recorded in the
   divergence register). Same length as today's blind wait, so worst-case
   detection time per probe is unchanged. The late-Ack case keeps its own
   log line (it is the signal that a timeout is running tight) but is
   handled exactly like a direct answer: a quiet round for the pacer, with
   contact already recorded by the Ack handler.

3. **Which probes get the window.** Every verdict-bearing probe: the regular
   round and the unreachable-recovery probe. The new-peer RTT bootstrap
   probe keeps a single timeout: it records no failure, so a grace wait
   would only delay the first RTT sample. This is where ADR-012's "universal
   probe shape" is read precisely.

4. **No timing constant changes.** The probe interval stays 3× the ping
   timeout, clamped and paced as today; only its rationale is reworded to
   Kotlin's. The thresholds stay 5/15; the roadmap's note to re-measure them
   once relays are gone remains on
   [the threshold item](../../backlog/engine-swim-threshold-tuning.md) and
   is unblocked by this batch, not done by it.

5. **Wire: receive forever, send never, encoder stays for now.** The
   `PingReq` class, wire type byte 2, the codec in both directions, and the
   `v1-dart` and `v2` `pingreq` vectors all stay. The encoder is deleted
   only at the next dialect revision, because the conformance vectors bind
   both twins and Kotlin kept its encoder for the same reason. The class
   doc is rewritten to say it is a retired relay request kept for
   compatibility with older peers. No deprecation annotation: nothing
   outside the library ever constructed one.

6. **The rename away from "SWIM."** Recommended scope: every place that
   names what *this library does*: the library doc in `gossip.dart`, the
   coordinator and config docs, the membership context's doc comments,
   README, CLAUDE.md, ADR-010's tree comment, and test names and comments.
   Vocabulary: "failure detection" for the mechanism, "the failure
   detector" for the component, "probe" for the act, "liveness" where the
   sync engine feeds it. "SWIM" survives only where it names the literature
   the design departs from (ADR-004's history, the note that
   incarnation/refutation is deliberately not implemented, the jitter
   comment citing SWIM practice) and in historical records (audits, plans,
   earlier specs, the decision record, the changelog's past entries). The
   one runtime-visible string, the `[SWIM]` log prefix, becomes
   `[FailureDetector]`; no opendoor-api script greps the old prefix
   (checked 2026-09-18). Kotlin adopts the same prefix and wording in its
   next bump (item 9), recorded as a register row until then. The
   alternative, docs-only with the log prefix left alone on both twins, is
   cheaper but leaves the library describing itself two ways.

7. **ADR handling.** ADR-004 is rewritten in place: title "Probe-based
   failure detection", status "Amended 2026-09-18: indirect probing
   retired", the original SWIM decision kept as a history section pointing
   at the decision record, and its false statements corrected while there
   (it claims incarnation numbers exist; Dart never built them; its timeline
   and recovery paths still credit intermediaries). ADR-012 is amended to
   state the grace window as the universal shape and loses its two-scenario
   framing. File names keep their numbers and current slugs: the number is
   the identity, and only the ADR index links them. CLAUDE.md's ADR table
   row follows the new title.

8. **Tests.** Deleted because they pin removed behavior: the intermediary
   timeout file, the "Intermediary role" group, the indirect-success and
   recovers-via-intermediary cases, the recovery-through-relay file, the
   intermediary-selection group, and the asymmetric-partition
   relay-reachability case. Rewritten to the grace-window vocabulary: the
   late-Ack cases, the RTT late-Ack case, the pacing and adaptive-timeout
   comments, the harness docs. Kept as is: the convergence-through-relay
   case (transitive sync is still true), the codec round-trip and wire
   vector pins. Added, four pins:
   - an inbound relay request is decoded and ignored end to end through the
     coordinator: no frame back, no error (Kotlin's pin);
   - a late Ack landing partway into the grace window completes the round
     without waiting out the window (the race, net-new against Kotlin,
     which pins the window only by its length);
   - a failed direct probe with reachable third peers sends no relay
     request (send never);
   - with a third node connected to both sides, the one-way-deaf node still
     suspects its peer, the third node stays reachable to both, and entries
     still converge (the honest degradation, in the suite that used to pin
     the opposite).
   Estimated suite: 1274 → ~1266.

9. **Production effect, stated honestly.** The server has ignored relay
   requests since v47. A phone with only the server as a peer has never had
   an intermediary, so it already ran the grace-only shape. A phone with
   Nearby active can have several peers and can send a relay request today:
   to the server (ignored) or to another phone on the old pin (relayed). After
   the pin bump phones stop sending, and a phone one-way-deaf to a peer that
   a third phone could have vouched for now marks it unreachable and
   recovers through the slow probe after the heal. The wire is safe in
   either order, so no fleet coordination is needed.

10. **Sequencing and shape.** One Dart PR on a branch off main, TDD, carrying
    the code, the ADR revisions, the rename sweep, the CHANGELOG entry under
    Unreleased (behavior: relays retired, deaf pairs degrade honestly, the
    log prefix change), and the bookkeeping in the same PR: roadmap item 8
    done, the backlog item closed on both halves, the divergence register's
    relay and grace-window rows closed, the flow-backs item updated. Then the
    OpenDoorApp pin bump as its own PR in the app repo, checked on an
    Android and an iOS device the way the compaction pin was, since the
    server is untouched and the tunnel runbook proves nothing here. Item 9,
    the next Kotlin bump, rides after and carries Kotlin's rename riders
    (log prefix, README, CLAUDE.md), all documentation, no wire.

## Open points for the owner

1. Ruling 6's scope: the full rename including the log prefix
   (recommended), or docs-only leaving `[SWIM]` on both twins.
2. Ruling 3: confirm the bootstrap probe stays outside the grace window.
3. Ruling 10: confirm a device check, not the tunnel runbook, is the bar for
   the app pin bump.

## Review outcome

**Approved as recommended (owner, 2026-09-18).** All three open points
ruled: the full rename sweep including the `[SWIM]` → `[FailureDetector]`
log prefix (ruling 6); the new-peer RTT bootstrap probe stays outside the
grace window (ruling 3); a device check on Android and iOS is the bar for
the OpenDoorApp pin bump (ruling 10). Asked during review: whether Dart
should adopt incarnation numbers. Answer recorded here so the amended
ADR-004 carries it: no — refutation only has meaning when verdicts travel
between nodes, and under ADR-007 a verdict never leaves the node that
formed it; a wrongly suspected peer clears its name by answering the next
probe. Kotlin's copy is dead scaffolding scoped for deletion in KT-E. The
implementation plan follows this record.

**Shipped 2026-09-18** on branch `feature/retire-indirect-probing` per the
plan `docs/superpowers/plans/2026-09-18-dart-relay-retirement.md`; suite
1274 → 1267. The OpenDoorApp pin bump follows as its own PR.

**Precision note (final review, 2026-09-18):** ruling 1's "records no
contact for its sender" is the detector's behavior. The sync engine stamps
contact on every inbound frame before decoding it, so an ignored relay
request still refreshes the sender's last-contact time at the library
level — the same as any frame, and correct: it proves the inbound path
works, which is what freshness suppression keys on.
