# A pull is a request with identity — rulings

**Status:** approved 2026-09-29 (see Review outcome); Kotlin half merged as gossip-kt PR #18 (c8dde6f, 2026-09-29); Dart half merged as gossip PR #17 (96a422f, 2026-09-29). **Item:** [Correlate delta responses with the pulls that solicited them](../backlog/engine-response-correlation.md). **Supersedes:** ruling 3 of [A delta response answers one pull, or none](2026-09-28-response-correlation-rulings.md) as written there ("a request identifier, additively"); the bridge those rulings shipped (gossip-kt PR #17) stays until this lands on both twins and the fleet has moved. **Applies to:** both twins; Kotlin first; the Dart half of the round-wake fix implements this model directly and never carries the bridge in full.

## Why a re-model, not a field

The pending-pull bookkeeping is keyed by the *subject* of a request — which
peer, which channel, which stream — when the thing with identity is the
*request*. Seven review rounds on the bridge PR were all consequences of
that one choice: two requests to the same peer for the same stream (a pull
and its continuation, or a pull and the continuation of a page nobody asked
for) could not both be tracked, so one displaced the other; and a response
could only be tied to a request by guessing from its content, so a peer's
push of its own newest entry — the commonest response on a mesh — kept
reading as the answer to whatever pull happened to be outstanding. Each
round closed a case, purely and with a pin, and the model grew a two-part
ask, partial answers, a hand-over on paging and a linked list of displaced
marks inside a value. That list is a set of entities in disguise. The
backlog item said "don't grow more heuristics piecemeal"; we did.

Adding an identifier to the current shape would keep the wrong grain and
the heuristics beside it. The re-model puts identity where the domain has
it and lets the heuristics go.

## The model

**`RequestId`** — a value: an opaque identifier a requester mints, unique
among the requests it has in flight, meaningless to anyone else. Carried on
the wire as a string.

**`PullRequest`** — an entity, identified by its `RequestId`. What one
request of ours is: the peer it went to, the channel and stream, the `since`
vector it asked for, the authors the peer's digest showed it ahead on (what
the pull is *for*), and when it was issued. A continuation is a
`PullRequest` in its own right, with its own identity, its own `since` (where
the page left us) and its own issue time; it records nothing about the page
it follows, because the peer answers a request, not a history.

**`OutstandingPulls`** — the aggregate: the set of `PullRequest`s in flight,
by identity, together with the round-trip evidence the staleness deadline is
derived from (`RttTracking`, as today). One value, one cell, pure
transitions, as `PendingPulls` is now. Its invariant is about identity, not
subject: no two requests share an id. "At most one pull *planned* at a time
per peer and stream" is a **policy** the planner asks the aggregate — *is a
request to this peer for this stream outstanding and not yet stale?* — not
the aggregate's key. A continuation counts as outstanding for that query; a
foreign page's continuation no longer exists (ruling 5).

**`Correlating`** — a per-peer fact the sync context keeps: whether this
peer has ever answered one of our requests by reference. Once it has, every
response from it that names no request is a push. Until it has, its
reference-less responses go through the legacy policy. A fact about a peer's
protocol behaviour, owned by sync (it is about *our* requests), not by
membership; cleared with the peer.

**`LegacyCorrelation`** — a domain service, explicitly transitional: the
content rule of the bridge, minimal, applied only to a peer not yet known to
correlate. Segregated so that deleting it is deleting one file and one call.

## Rulings (proposed)

1. **A response that names a request is that request's answer.** Whatever it
   carries. The request is retired, its round trip sampled from its own
   issue time, the sender's floor adopted, a hole recorded as a stall. A
   response that names a request we do not hold — expired and replaced,
   cleared by a stop or a removal, or from before a restart — is a push. A
   response from a correlating peer that names nothing is a push. No
   content is consulted in any of these cases: the two-part ask, partial
   answers, the `hasMore` hand-over and the displaced-mark chain are
   deleted with this ruling.

2. **A pull is issued with its identity, and a peer echoes it.**
   `DeltaRequest` gains `requestId`; `DeltaResponse` gains `inReplyTo`, set
   on an answer and absent on a push. Both are additive JSON keys within v1
   and v2 per the wire-versioning bump policy (both v1 decoders were proven
   to ignore unknown keys); no marker bump. A responder that receives a
   `requestId` echoes it; one that does not (a phone on the old pin) answers
   as today, and its answers are correlated by ruling 4.

3. **One outstanding pull per peer and stream is a policy, not a key.** The
   planner asks the aggregate whether a request to that peer for that stream
   is outstanding and not yet stale, and marks by minting a new
   `PullRequest` if not — the same gate as today, over a set. Staleness
   stays the adaptive timeout over the round-trip evidence. Because the gate
   is a query, a continuation and a pull to the same peer for the same
   stream can both be in flight and both be answered, each by its own
   reference, and a request the transport refused is released by its own
   identity and nothing else's.

4. **Peers that predate the identity are correlated by a minimal,
   transitional rule.** For a peer not yet `Correlating`, a reference-less
   response is judged against the requests outstanding to that peer for that
   stream, oldest first: it answers the first request it begins where asked
   for — for every author it carries, one past the higher of what that
   request held and what the sender compacted through, or floored at or past
   its start — and speaks to an author that request was for (carries one, or
   floors one past what the request held). It answers that request for the
   authors it accounts for and leaves the rest of it outstanding, as the
   bridge does today (the racing push of a peer's own author is real on a
   mesh); an empty response answers the oldest request whole. Nothing else
   of the bridge is kept: with continuations as requests of their own, the
   collisions that needed the displaced-mark chain and the `hasMore`
   hand-over cannot occur. The first response from the peer that names a
   request flips it to `Correlating`, and this rule never applies to it
   again.

5. **A page nobody asked for spawns no continuation.** Today a reference-less
   `hasMore` response still triggers a continuation request, which is how a
   page we never asked for came to displace a pull we did. A continuation is
   issued only for a response that answered a request of ours (ruling 1, or
   ruling 4 for a legacy peer); if we want the rest of an unasked page, the
   next digest exchange plans a pull for it as for anything else.

6. **The legacy rule has a deletion criterion, recorded on the item.** It is
   deleted from both twins when the app pin that echoes references has been
   the fleet pin long enough that the server has seen no legacy-correlated
   answer for two weeks (a counter on the server's error/log surface, added
   with the Kotlin half). A register row tracks the deletion; the pins that
   belong to the rule go with it.

7. **Order.** Kotlin first, as its own PR: the aggregate, the wire fields,
   `Correlating`, the legacy service, the deletion counter; the server
   emits `requestId` on its pulls and echoes `inReplyTo` on its answers, so
   phones on the new app pin correlate the server's answers by reference
   the day it ships, and the server correlates each phone by reference from
   that phone's first echoed answer. Then the Dart half of the round-wake
   fix, which implements this model (never the bridge's chain), and the
   Dart tracker becomes a value at the same time — the flow-back the register
   already records. Then the app pin. Then the deletion, both twins, one PR
   each, when the criterion is met.

## What this is not

- Not a wire version bump: two additive keys, ignored by every decoder in
  the fleet today.
- Not a change to what a response does once correlated: floor adoption, stall
  recording, gap reporting and RTT sampling keep their rules; only *which*
  request a response belongs to is decided differently.
- Not a change to the round-wake fix or the scheduler.

## Pins the plans must carry

- **Aggregate:** two requests to one peer for one stream are both held and
  both retired, each by its own id; the planner's gate answers "outstanding"
  while either is live and not stale; releasing one by id leaves the other
  as it was; a stop clears all, a peer removal that peer's, a channel
  removal that channel's; every transition answers a new value and leaves
  its input untouched.
- **Correlation:** a response naming a held request retires it whatever its
  content — including one that begins above what was asked (a hole is then a
  stall, not a misclassification); a response naming an unknown request is
  a push; a response naming nothing from a `Correlating` peer is a push —
  including one that begins exactly where an outstanding request asked (the
  racing push the bridge had to reason about is now simply a push).
- **Peer capability:** a peer becomes `Correlating` on the first response
  that names a request; from then on its reference-less responses are
  pushes; a peer removal forgets it. Nothing here is persisted, so our own
  restart forgets it too and the peer's next referenced answer relearns it —
  in between, that peer's pushes go through the legacy rule once more, which
  is the bridge's behaviour today, not a regression. Stated, not hidden.
- **Legacy:** the bridge's racing-push pins re-homed on `LegacyCorrelation`
  for a non-correlating peer: a push of an unwanted author leaves the request
  outstanding; a push of a wanted author at its tip answers that author and
  leaves the rest; the true answer completes it and its floor is adopted; a
  paged answer whose second page carries only the other author still
  completes; and — new — the same responses from a `Correlating` peer with
  no reference are all pushes.
- **Continuation:** a `hasMore` answer to our request issues a continuation
  with its own id; a `hasMore` push issues none; a continuation the
  transport refuses is released alone.
- **Wire:** `requestId`/`inReplyTo` round-trip through both codecs in both
  versions; a frame without them decodes as today; a push carries no
  `inReplyTo`; the v1 decoder's tolerance of the two keys pinned explicitly.
- **Suite:** `ChurnSyncTest` "staggered restarts lose no entries" ten clean
  runs of ten, with the wake.
- **Parity:** the Dart aggregate has the same shape and the same cases; the
  Dart tracker is a value; the register carries the legacy rule's deletion
  and any site where one twin mints or echoes an id and the other does not.

## Consumer notes

- kt: `PendingPulls`/`PendingPullTracker` are replaced by `OutstandingPulls`
  and its transitions; opendoor-api touches only the initial value, which
  keeps a name-equivalent (`OutstandingPulls.initial`). The two wire keys are
  emitted by the library; the server's transport carries bytes and is
  untouched. The deletion counter surfaces on the existing metrics/log
  seam — its shape is the bump plan's to state.
- Dart: OpenDoorApp constructs no tracker and reads no pull state; the app's
  pin bump carries the identity to the phones.

## Review outcome

**Approved (owner, 2026-09-29)** as proposed. Kotlin plan follows in gossip-kt `docs/superpowers/plans/`.

**Precisions from the Kotlin half (gossip-kt PR #18, 2026-09-29).**

- *A request identity is an identifier.* It takes the same rule as node,
  channel and stream ids (at most 64 UTF-8 bytes; nothing JSON escapes), so
  an echo can never be an unbounded cost, and one outside the rule is a
  malformed frame like any other identifier. Minted ids are about twelve
  characters.
- *Each dialect pays for the identity it echoes.* The shared entry-envelope
  allowance stays 512 bytes and stays shared; the reply identity's maximal
  cost is subtracted per dialect before the expansion ratio — v1's batched
  object costs 25 bytes plus three identifiers (217), v2's flat field 15
  plus one (79). At the default 30 KiB budget the entry caps move from
  7552/22656 to 7497/22596 bytes; an entry exactly at the old cap is now
  refused at append. The Dart half derives its caps the same way — see the
  Dart precision below.
- *A reference is honoured only for the peer and stream the request named.*
  "Whatever it carries" (ruling 1) is about the entries; a peer echoing our
  id on a response for another stream is a fault to be inert about, not a
  reason to retire the request or adopt that stream's floor.
- *A request past its deadline is no legacy candidate.* Content is
  evidence, and a long-expired request is what a push is likeliest to
  resemble by accident; a reference is honoured whatever its age, because
  an id is proof.
- *A legacy drain's next page is recognised by what the page before it
  carried (corrects ruling 4's "nothing else of the bridge is kept").* A
  peer that answers by content pages a pull as it likes, so its next page may
  continue an author already accounted for rather than open one still owed.
  The bridge's second set was about this, not about the collisions the
  re-model removed, and it stays for the legacy rule alone: a continuation
  records the authors the page before it carried, and a page carrying one of
  them is the drain going on — recognised, not required, so a final page that
  does not carry it still completes. Empty on a planned pull, never read for
  a peer that answers by reference, deleted with the rule. The Dart half
  carries it the same way.

**Precisions from the Dart half (`feature/dart-round-wake-identity`, 2026-09-29).**

- *One cap per dialect, not one across dialects.* Dart's v1 is flat, like
  v2, so its reply identity costs 15 bytes plus one identifier (79) in both
  versions and its entry caps are 7532/22596 at the default budget, against
  kt v1's 7497. The twins promise the same rule, applied to what each
  dialect actually echoes; the register's identity row carries the three
  numbers.
- *A pull for a stream the responder does not hold is answered empty, by
  reference.* Dart's responder names the request on that empty answer, so
  the requester retires the pull at once instead of waiting out its deadline;
  kt sends nothing today (a kt flow-back row on the register).
- *The wake's wait-end clause is parity, not a live path.* Dart runs in one
  isolate, so a wake cannot pause between reading the clock and deciding;
  the scheduler still checks that the state it read is the state it acts on,
  for the same reason kt does, and the pin stands as documentation.
- *Dart's channel removal does not reach the pull state* (pre-existing):
  `clearForChannel` is written and pinned but has no Dart caller; recorded
  on the register as a Dart flow-back, not fixed on this branch.
- *One key, two shapes, read both.* The two dialects name a request under
  the same keys in different shapes — Dart flat (`"inReplyTo": "<id>"`),
  kt v1 batched (`"inReplyTo": {"<channel>": {"<stream>": "<id>"}}`, its
  requests under `requestIds`). A decoder that reads only its own shape
  turns the other twin's answer into a corrupt frame, which breaks the
  additive-key promise the rulings rest on. Dart's decoder reads both, taking
  the reference for the frame's own stream from a batched shape; a batched
  shape that names nothing for that stream names none, and any other type is
  malformed. kt's v1 decoder still rejects Dart's flat string — a kt flow-back
  on the register; until it lands, the app's translator maps one shape to the
  other, as it must anyway for the server.
- *A request identity is the identifier rule, once.* The four-clause rule is
  hoisted to `shared/domain/value_objects/identifiers.dart` (kt's
  `Identifiers.kt` shape) and `RequestId` applies it; the register's
  identifier-bound flow-back for `NodeId`, `ChannelId` and `StreamId` is now
  three call sites, not a re-implementation.
- *A partial legacy answer narrows a request only where the dialect can mark
  a page partial (corrects ruling 4's "leaves the rest of it outstanding" for
  v1).* v1 frames carry no `hasMore`, so a v1 responder that pages a
  multi-author backlog sends one page per request and relies on later rounds
  for the rest. Narrowing such a request and holding it open suppressed the
  next round's pull for that peer and stream until the deadline, on every
  page. The decoder now records on the response whether its frame's dialect
  can mark a page partial; where it cannot, a content-correlated answer is
  the whole of that request's answer — retired, sampled — and the next
  digest asks for the remainder. On v2 nothing changes. The Kotlin twin has
  the same latent rule for legacy phones over v1-kt (a kt flow-back row on
  the register). Found by Codex on gossip PR #17.
- *A non-positive interval is a scheduling failure on Dart too.* The old
  Dart loop spun on a zero `gossipInterval`; on the woken scheduler it is the
  same failure as on kt — the loop stops and reports through the error
  callback. Documented on `CoordinatorConfig.gossipInterval`.
