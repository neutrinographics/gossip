# Correlate delta responses with the pulls that solicited them

**Track:** Sync engine   **Depends on:** nothing

## What this is

When the library decides whether an incoming batch of entries was an answer
to its own request ("solicited") or an unprompted push from a peer, it
matches only on *who sent it and which stream it concerns* — not on which
request it answers. So a reactive push that races an outstanding pull to
the same peer and stream is misclassified as the pull's answer, and the
real answer, arriving a moment later, is misclassified as unprompted.

Three things key off that classification today, and all three inherit the
misattribution: the one-time warning about a peer that cannot supply a
range, the round-trip-time measurement that tunes request timeouts, and —
since stalled-range suppression landed — the recording of a stall. The
last case can record a *false* stall from a racing push (flagged by the
PR #15 review): it self-heals when the true answer arrives, and costs at
most one 30-second probe window if that answer is lost, but it is a wrong
fact recorded confidently.

## Why it matters

Every consumer of "was this solicited?" is making a per-request question
answer a per-stream approximation. The individual costs are each bounded
and rare, but they compound quietly (a mistimed RTT sample skews the
adaptive timeout; a false stall delays a range briefly; a warning blames
the wrong exchange), and each new feature that needs the distinction —
suppression was the third — inherits the same flaw. Correlating properly
once removes the whole class.

## Rough approach

The pending-pull bookkeeping is keyed by the *subject* of a request (which
peer, which stream) when the thing with identity is the *request*. Every
misclassification is a consequence: two requests to the same peer for the
same stream cannot both be tracked, and a response can only be tied to a
request by guessing from its content. The fix is a re-model, not a field: a
pull becomes an entity with an identity the peer echoes back, the aggregate
is the set of requests in flight, and "one outstanding pull per peer and
stream" becomes a policy over that set instead of its key. A response that
names a request is its answer whatever it carries; one that names none is a
push. Peers that predate the identity are correlated by a minimal,
explicitly transitional content rule until the fleet has moved.

The content rule shipped first, as a bridge (gossip-kt PR #17), because the
round-wake fix could not ship without correlation and the phones will not
echo identities until the app's pin moves. It is deleted with the re-model.

## Related

- Re-model rulings, approved 2026-09-29: [A pull is a request with identity — rulings](../superpowers/specs/2026-09-29-pull-request-identity-rulings.md).
- Kotlin half: gossip-kt PR #18, merged c8dde6f on 2026-09-29 — the
  entity, the aggregate, the wire keys, the by-reference correlation, the
  transitional `LegacyCorrelation` with its once-per-peer INFO lines as the
  deletion criterion's counter, the bridge's surface deleted and pinned
  retired. Deletion criterion (ruling 6) and its reading caveat are on the
  register row "The transitional content rule and its deletion".
- Bridge rulings, approved 2026-09-28: [A delta response answers one pull, or none — rulings](../superpowers/specs/2026-09-28-response-correlation-rulings.md) — raised by the round-wake fix, whose Task 3 measured the misclassification at six of ten churn runs with the wake and none without.
- Ruling 1 (classify by content) landed in the Kotlin library on the
  round-wake branch (gossip-kt PR #17, 269f790): the pull mark carries the vector it
  asked for, and a response retires it only when its content can be the
  answer — beginning where the pull asked, and speaking to an author the
  pull was for; ten of ten churn runs clean with the wake. Known limit recorded in
  the rulings' Precisions: a peer truncated at the front that reports no
  compaction floor is indistinguishable from a push until the request id of
  ruling 3 lands. The Dart half rides the Dart round-wake plan; the item
  stays open until ruling 3 ships on both.
- A second residual the content rule leaves for ruling 3: a response that
  lands in the moment between a pull being marked and its vector being
  recorded retires the mark on existence alone, so the request then goes
  out unmarked and its true answer reads as unprompted. Bounded (one pull,
  one missed floor and RTT sample), and closed by the request id.
- A third, from the controller's review of gossip-kt PR #17: a probe of a
  suppressed range asks from above what the peer can supply, so the peer's
  answer begins above where it was asked and reads as a push under the
  content rule. The suppression cadence is unaffected (it re-arms when the
  probe is sent), but the probe's mark now lingers until the pull timeout,
  during which other pulls of that stream from that peer wait. Bounded by
  the adaptive timeout; closed by the request id.

- Flagged concretely by the PR #15 review (a racing reactive push recorded
  as a stalled pull); the stalled-range spec documents the bounded impact.
- The wire-versioning machinery that would carry a request id:
  [Teach both libraries to speak versioned wire formats](kt-wire-versioning-campaign.md).
- Sibling consumer of the classification:
  [Suppress pulling an author's range a peer has already failed to supply](engine-stalled-range-request-backoff.md).
