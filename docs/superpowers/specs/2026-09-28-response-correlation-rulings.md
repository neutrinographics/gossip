# A delta response answers one pull, or none — rulings

**Status:** approved 2026-09-28; ruling 1 landed in Kotlin (gossip-kt PR #17, 269f790) with the precisions below. **Item:** [Correlate delta responses with the pulls that solicited them](../backlog/engine-response-correlation.md) (Low today; this page asks to raise it). **Blocks:** the round-wake fix (gossip-kt `feature/round-wake`, Tasks 1–3 landed and green).

## Why now

The round-wake fix works: with it, the server's next round after a merge
comes within the active interval instead of after the old wait. But its
Task 3 measured a side effect. `ChurnSyncTest`'s "staggered restarts lose
no entries" passes convergence and fails its no-errors assertion in six of
ten runs with the wake, none of ten without. Every failure is the same
line: a node reports a protocol error, "sequence hole for author node1 …
expected seq 2, first available 3", and records a stalled range against a
peer that holds entries 1 to 3 and compacted nothing.

The cause is the flaw the correlation item already names. When a
`DeltaResponse` arrives, the engine decides "was this the answer to my
pull?" by asking whether a pull mark exists for that peer, channel and
stream — nothing about *which* request it answers. A reactive push from the
same peer for the same stream, arriving while a pull is outstanding, is
taken as the pull's answer; if the push starts above what the pull asked
for, the gap is a "sequence hole" the peer supposedly cannot fill, a false
stall is recorded (pulls of that author from a healthy peer are then
suppressed for the backoff window), and the true answer, arriving next,
reads as unsolicited (its floor is not adopted). The wake does not create
any of this. It makes pull-in-flight coincide with pushes often, on the
very path it was built to speed up — presence, where every phone pushes
every two seconds.

So the wake cannot ship alone. The correlation item comes forward and
lands with it.

## What the wire allows

The wire-versioning spec's bump policy: additive JSON fields stay within a
version; both v1 decoders were proven to ignore unknown keys. So a new
field on `DeltaRequest`/`DeltaResponse` needs no version bump and breaks
no phone on the fleet pin — but a phone on the fleet pin will not *send*
it. The server is the hub, and the misclassification that hurts is the
server misreading a phone's push; a fix that needs the phone to say
something only helps after the app's pin moves.

## Rulings (proposed)

1. **Content decides, not the mark's existence.** A pull mark records what
   the pull asked for — the `since` vector it sent. An arriving response is
   that pull's answer only if its content can be one: for every author it
   carries, the first sequence is `since[author] + 1`, or the response's
   `floor` for that author is at or above the first sequence (the peer
   compacted, and says so). Anything else is a push and is merged as one:
   no stall recorded, no solicited floor adopted, no RTT sample, and the
   mark stays outstanding for the answer still to come. `PendingPulls`
   gains the vector per mark; the rule is a pure function on the tracker
   (`answers(mark, response)`), pinned property-style, and both twins take
   it (the Dart half rides the round-wake's Dart plan). This needs nothing
   from the sender, so the server benefits against today's phones the day
   it ships.

2. **A response that is a valid prefix of the answer counts as the answer.**
   A push that happens to begin exactly at `since + 1` is indistinguishable
   from the answer's first page, and is treated as one — its content is
   what the pull wanted. If the real answer then arrives, it merges as a
   push; the cost is one floor adoption and one RTT sample missed, the
   same bounded cost the item records today, now confined to this one
   coincidence.

3. **True correlation follows, additively.** `DeltaRequest` gains a request
   identifier and `DeltaResponse` echoes it (`inReplyTo`; absent on a
   push). Additive within v1 and v2 per the bump policy; a receiver that
   sees the field uses it and skips ruling 1's content check; one that does
   not falls back to ruling 1. Both twins, designed together, after the
   round-wake lands on both; the fleet gains it with the app's pin. The
   item stays open until this half ships.

4. **Order.** Ruling 1 lands on the round-wake branch as its Task 3b, with
   the `ChurnSyncTest` rate as the pin (ten of ten runs error-free with the
   wake), then the docs and the PR; the server bump follows with the
   two-phone re-measure; then the Dart plan carries the wake and ruling 1
   together; then ruling 3 as its own small item.

## Pins the plans must carry

- Tracker: `answers(mark, response)` true for a response starting at
  `since + 1` for every author it carries; true when the floor covers the
  start; false when any author starts above `since + 1` with no floor to
  explain it; true for a response carrying no author (an empty response
  from the asked peer is the answer — today's semantics for an empty page,
  kept and stated; corrected 2026-09-28, see Precisions); property-style,
  inputs unmutated.
- Engine: a push arriving while a pull is outstanding is merged as a push
  — no stalled range, no protocol error, the mark still outstanding — and
  the true answer arriving afterwards is treated as the answer (floor
  adopted, mark completed).
- Suite: `ChurnSyncTest` "staggered restarts lose no entries" ten clean
  runs out of ten with the wake in place.
- Parity: the Dart tracker gains the same rule with the same cases.

## Review outcome

**Approved (owner, 2026-09-28)** as proposed: ruling 1 lands as Task 3b of the round-wake branch; ruling 3 becomes its own item after both twins carry the wake.

**Precisions from the Kotlin half (2026-09-28).** The Dart half takes these
as written here, not ruling 1's literal text.

- *The floor clause.* A compaction floor is the last sequence the sender
  compacted through, so a compacted answer starts at `floor + 1`, not at the
  floor; ruling 1's literal "floor at or above the first sequence" alone
  would read every compacted answer as a push (two existing floor pins went
  red on it). The rule as landed: for every author the response carries,
  its first sequence is one past the higher of `since[author]` and
  `floor[author]` — the position the merge path judges contiguity from
  once the floor is adopted — or the floor is at or past the first sequence
  (a sender that sends at or below its own floor contradicts itself but
  withholds nothing, so it answers too).
- *An empty response is the answer.* A response carrying no author, from
  the asked peer, answers the pull: the peer replied with nothing left to
  give. The pin above said the opposite and is corrected.
- *A mark without a vector completes as before.* The planner records the
  vector on the mark after shaping it, so a response can arrive against a
  mark that carries none yet; that response completes the mark on
  existence alone, as today.
- *An answer speaks to what the pull was for (ruling 2, precision; Codex
  review of gossip-kt PR #17).* Ruling 2's "valid prefix" is a prefix of the
  answer to *this* pull, so the mark records, besides `since`, the authors
  the peer's digest showed it ahead on — what the pull was for. A response
  answers only if, besides beginning where asked for every author it
  carries, it carries one of those authors or reports a floor past what we
  hold of one. Without this, a peer's push of its own newest entry, for an
  author we hold at its tip, begins exactly where an answer would and would
  retire a pull for a different author — on a mesh, where every peer
  writes, the commonest response there is. A continuation's ask joins its
  pull's authors with the authors its pages have carried, because which of
  them the next page opens with is the responder's choice.
- *Known limit, until ruling 3.* A peer whose history is truncated at the
  front and that reports no floor answers above everything asked, so by
  content it is indistinguishable from a push: no stall is recorded, no
  suppression follows, and the pull re-issues at the adaptive timeout
  (2–30 s) instead of the doubling backoff. No peer on the fleet does this
  (both twins report a floor whenever they compact, and the 2026-08-31
  incident that motivated stalled-range suppression was the JVM's heap,
  not a truncated peer); the request id of ruling 3 closes it. Recorded on
  the item.
