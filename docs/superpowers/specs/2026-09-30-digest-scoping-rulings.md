# A digest names only what the peer holds — rulings

**Status:** approved 2026-09-30 (see Review outcome), after a same-day cohesion, coupling and DDD/CA review the owner asked for. **Item:** [Only tell a peer about the groups you both belong to](../backlog/engine-scope-digests-to-shared-groups.md) (roadmap focus item 10). **Applies to:** both twins; Kotlin first, because the bytes are the server's. **Pulls forward from wire-efficiency phase 2 for Kotlin:** request-scoped and dominance-filtered digest responses, and the byte-budgeted digest rotation — the design depends on them. Recency suppression stays in phase 2.

## The finding, restated

A gossip round opens with a digest request that names every channel the
sender holds, with a version vector for every stream of every one of them.
The Kotlin twin answers with the same: every channel it holds, whatever was
asked. The server holds a channel for every user and every group in the
tenant — 36 on 2026-09-29, growing with the tenant — and a phone holds two
or three of them. So each round the server sends a phone about 37 KB in its
own request and about 37 KB again in its answer to the phone's, and the
phone uses two or three channels' worth. With presence heartbeats holding
the pacer at its floor, that read as ~5 MB out per phone per minute for two
phones in a meeting on v60, and ~1 MB per phone with eight phones on v52.
The ids are not the cost; the version vectors per stream are.

Two smaller costs ride along. The Dart response path emits a
`protocolError` for every channel it does not hold — about thirty-three
error callbacks per round per phone against the current server. And every
peer in radio range, related or not, learns the id of every group and
account the sender syncs, once a round.

What the join flow forbids: "shared" cannot come from an authority. A phone
holds `ChannelId(groupId)` the moment it publishes its first join event;
the server creates that channel only when the `user_member_linked` event
reaches it on the personal channel, a round or more later. App membership
is never enforced by the protocol (the channel aggregate's member set is
local metadata, and neither the app nor the server populates it). Shared
means one thing: **both peers hold the channel**, learned from what the
peer itself names on the wire, and re-learnable, because a channel unshared
this round can be shared the next.

## The model

Every piece below is sync's. Membership never sees any of it: what a peer
*holds* is a different fact from whether it is *alive*, and `PeerDirectory`
stays as it is.

**Holdings** — what a peer has shown it holds: the channels it has named in
its digests, requests and responses alike. Only a name is evidence — a
dominance-filtered response may omit a channel entirely, so an omission
teaches nothing — and so holdings only grow. Cleared with the peer. Never
persisted; our own restart forgets them and the peer's next digest teaches
them again.

**`PeerHoldings`** — a value: every peer's holdings, moved only by pure
transitions — *learn* the channels a peer named, *forget* a peer — and read
by one query: which of these channels has this peer shown? A value and not
an aggregate: it holds no entity and keeps no invariant beyond set
semantics, so it takes the shape of `Generation` (a value in a cell, moved
by pure transitions), not of `OutstandingPulls`. It stays apart from
`OutstandingPulls`, though both are per-peer facts sync keeps, because how
a peer answers and what a peer holds change for different reasons.

**Announcement** — a channel we hold, named to a peer without a digest: *I
hold this; if you do too, show me your digest for it.* A concept of its
own, carried by `DigestRequest` as a second field beside its digests — the
ids announced — and by nothing else: a response answers, it never
announces, and the type says so. The domain never learns an announcement
by inspecting a digest for an empty stream list; that reading is the
codec's, below.

**`DigestScoping`** — a stateless domain service, the rule of ruling 1: from
the digests of every channel we hold and the peer's holdings, the request's
two lists — a digest for each channel the peer has shown, an announcement
for each it has not. Pure: it reads no repository, keeps no cursor, knows
no byte.

**`DigestAnswering`** — a stateless domain service, the rule of ruling 2:
from a request and our digests for the channels it names that we hold, the
response's digests — whole for an announced channel, dominance-filtered to
the named streams for a digested one. Pure in the same way.

**Announce budget** — the bytes a request may spend on announcements. The
announcement list is the one cost that scales with how many channels a node
holds, and a hub's channel count is unbounded; the budget bounds what a hub
spends per round naming channels a phone will never hold. It is applied by
the digest budgeter, the application-layer mechanism that already fits
digests to bytes and rotates what does not fit — one more list, one more
cursor, the same job.

## Placement, both twins

The pipeline on the sending side is *scope, then budget, then send*; on the
receiving side *learn, then answer or pull*. Each step has one home:

Same name, same layer, same sublayer on both twins, per the parity program;
the two places the twins differ are cited to the register.

| Piece | Layer | Home (both twins) |
|---|---|---|
| `PeerHoldings` + transitions | domain, value object | `sync/domain/value_objects/` — kt `values/`, exemption E1 |
| Announcement field on `DigestRequest` | domain, message | `sync/domain/messages/` |
| `DigestScoping`, `DigestAnswering` | domain, stateless services | `sync/domain/services/` |
| Announce budget + announcement cursor | application, mechanism | `DigestBudgeter` — new on kt, taking Dart's name as the register's *Pull planning's name* row already rules |
| Gathering version vectors, looking up held channels, learning holdings on receive, logging drops, sending | application, orchestration | `GossipEngine` — on kt split with `PullPlanner` per that same register row (kt extracted planning; Dart's adoption is a recorded low flow-back, not this item's) |
| Announcement ↔ `"streams": []` | infrastructure, codec | `SyncMessageCodec` and its per-version emitters — kt keeps the digest JSON helpers in `SyncWireCommon`, a layout difference no register row records yet; this item's docs pass adds the row |
| Announce budget value | composition root | `CoordinatorConfig` |

The rules live in the two services and nowhere else; the engine (and on
kt the planner) orchestrates and holds the cell. The Kotlin port lands the
rules as domain services from the start — not in `PullPlanner`, which
stays the orchestrator it became in the architecture remediation's batch D.

## Rulings (proposed)

1. **A request names every channel we hold, as a digest or an
   announcement.** `DigestScoping` gives each channel we hold a digest if
   the peer has shown it holds the channel and an announcement otherwise.
   The budgeter then fits the digests first, under the message budget with
   the existing request-side rotation, and fills the announce budget with
   announcements in the room that remains, rotated by a cursor of their
   own, so a hub over the budget names every channel to every peer across
   successive rounds and never the same head twice. No priority for new
   channels: a peer under the budget names everything every round, so a
   channel created on either side is shared within one round of both
   holding it; the only node that rotates is a hub, whose peers are small.

2. **A response answers the request and never widens beyond it.**
   `DigestAnswering` answers each named channel we hold: an announced
   channel with our whole digest for it — every stream we hold; no
   dominance filter is possible without the requester's vectors — and a
   digested channel as the Dart twin answers today, the named streams we
   hold, dominance-filtered. The budgeter fits the result under the message
   budget with the response-side cursor. A named channel we do not hold is
   not given to the service: the engine drops it at debug, on both twins,
   and it appears nowhere in the response. The reciprocal pull is planned
   from the request's digests only; an announcement carries nothing to
   pull.

3. **Every name teaches holdings.** On receiving a request or a response,
   the engine learns the channels it names — digested and announced alike,
   read through one query on the message so the engine never reaches into
   its lists — as the sender's holdings, before anything else is done with
   it. A response naming a channel we do not hold is dropped at debug, not
   emitted as a `protocolError`: an old peer that still answers with
   everything is a legitimate peer, not a broken one. This is the Dart
   flow-back the divergence register's *Unknown-channel digests* row
   already recommends; that row closes with this ruling.

4. **Holdings are cleared with the peer and nowhere else.** A peer removal
   forgets its holdings; a stop forgets all. A channel a peer once named and
   has since stopped holding stays in its holdings — nothing in either
   twin removes a channel today, and the cost of the stale name is one
   digest per round the peer drops at debug. Recorded as a limit, not
   solved; if channel removal ever ships, the peer's next request, which
   names everything it holds, is where a refresh would come from.

5. **The announce budget is a configuration value, defaulting to 1 KB.**
   About fifteen ids per round. A field beside `maxMessageBytes` on both
   twins' coordinator config, handed to the budgeter by the composition
   root, applied after the digests are fitted and never exceeding the room
   the message budget leaves. For a phone it is never reached. For the
   server, a phone with three shared channels receives three digests plus
   at most a kilobyte of names per round whatever the tenant grows to, and
   the 36 channels of today are named across three rounds. The value is a
   starting point: the tunnel measurement after the Kotlin half may move
   it.

6. **No wire change.** No new key, no marker bump, no flag day. The codec
   renders an announcement as a channel digest with an empty `streams`
   list — legal in every dialect in the fleet, about 65 bytes for a
   36-character id — and reads an empty stream list back as an
   announcement. A channel that genuinely has no streams yet is therefore
   received as an announcement, and that reading is right for it: the peer
   answers with what it has, which is how the two learn they share it. An
   old responder answers an announcement with nothing and drops it; an old
   requester still names every channel it holds, so a new node's holdings
   fill from an old peer on its first request. One announcement vector
   joins the canonical conformance set in both repos.

7. **Order.** Kotlin first, as its own PR: `PeerHoldings`, the announcement
   field, the two services, the budgeter with its cursors and the announce
   budget, the codec mapping. Then the server bump, live-device validated
   through the tunnel against the 2026-09-29 two-phone reading (~2.2 MB per
   phone per minute), which is where the production win lands whole: the
   server's answers become request-scoped and its requests carry the
   phone's shared channels plus the announce budget, and no phone needs a
   new pin for it. Then the Dart half, which serves the nearby meshes (a
   phone with nineteen groups beside a tablet with one) and parity,
   followed by the app pin bump in the normal course. Then a production
   meeting read against 5 MB per phone per minute with two phones and 1 MB
   with eight.

## What this is not

- Not membership. The channel aggregate's member set stays local metadata
  the protocol never reads; holdings are what a peer *shows*, not what an
  app *declares*.
- Not a change to what a digest does once shared: pulls, dominance,
  budgets, stalls and pacing keep their rules. Only *which* channels a
  request names, and *how* a response is scoped, are decided differently —
  and each by one pure service.
- Not the disclosure fix. An announcement still names a channel in
  plaintext to every peer that connects; it is the one place a keyed hash
  would later go (recorded below), local to one field and one codec
  mapping, and digests for shared channels can stay plaintext even then.
- Not hub mode. A hub that never announces would save the last kilobyte;
  the rule above is correct for star and mesh alike without a switch, and
  the switch waits for a measurement that says the kilobyte matters.

## Pins the plans must carry

- **Value:** learning a name adds it and never removes another; a
  dominated response that omits a channel leaves it held; forgetting a peer
  removes only that peer; a stop clears all; every transition answers a new
  value and leaves its input untouched.
- **Scoping (pure):** a channel the peer has shown yields a digest, one it
  has not yields an announcement; nothing else is consulted; the service
  takes digests and holdings and returns two lists.
- **Answering (pure):** an announced channel is answered with every stream
  of it; a digested channel with the named streams only,
  dominance-filtered; the service takes the request and our digests for
  the held channels it names and returns the response's digests, and
  nothing not in the request can appear in them.
- **Budgeting:** the announce budget is respected with the digests already
  fitted, and is not spent when the digests fill the message; the
  announcement cursor rotates so a hub over budget names every channel
  across rounds; the two digest cursors are untouched by the third.
- **Engine:** a channel created after first contact is announced on the
  very next request; a named channel we do not hold is dropped at debug and
  reaches neither service; holdings are learned from a request and from a
  response before either is acted on; the reciprocal pull ignores
  announcements.
- **The join:** one side creates a channel after first contact; on the
  next request from either side it is announced; the round after the other
  side creates it, the pair holds each other's digests for it and the
  first pull is issued.
- **Mixed fleet:** an announcement to a responder on today's code produces
  no answer and no error; a request from a requester on today's code fills
  holdings with every channel it holds; a response on today's code naming
  everything is dropped at debug, not `protocolError`.
- **Wire:** an announcement round-trips through both codecs in both
  versions as an empty stream list and is byte-identical across twins; a
  received empty stream list decodes as an announcement; the conformance
  vector pinned in both repos.
- **Parity:** the Dart value and services have the same shape and the
  same cases as the Kotlin ones; the Dart engine's `protocolError` on an
  unknown channel in a response is gone and the register row closed; kt's
  response is request-scoped, dominance-filtered and budgeted with its own
  cursor, cited to the Dart tests it translates; kt's rules live in domain
  services, machine-checked by its layer-direction test.

## Consumer notes

- kt / opendoor-api: the library carries all of it; the server gains one
  optional config value (the announce budget) and otherwise touches
  nothing. The tunnel validation reads the server's per-peer bytes-out
  line, which already exists.
- Dart / OpenDoorApp: no API change; the app pin bump carries the scoped
  requests to the nearby meshes. Until then a phone's requests to the
  server still name its two or three channels in full, which the server
  answers scoped — the phone side of the production win does not wait on
  the pin.

## Recorded in the same docs pass

- **Glossary:** *holdings* and *announcement* join the sync section.
- **Disclosure follow-up, new item:** name channels in announcements by a
  keyed hash both holders can compute, so a bystander that connects learns
  nothing it did not already know. The seam is the announcement field and
  its codec mapping; digests for shared channels stay plaintext.
- **Server authorization, new server item:** the server serves deltas for
  any channel id a phone names, with no membership check; the sync-check
  route reads progress for any channel id likewise. Scoping hides ids from
  strangers; it does not close that door.
- **Push scoping** ([item](../backlog/engine-push-scoping.md)): holdings
  are the membership notion that item asked for; a reactive push can be
  scoped to the peers that have shown the channel.
- **Kotlin companion item** for the port, per parity convention 1; the
  phase-2 item loses the three pieces this spec pulls forward.
- **Divergence register:** the *Unknown-channel digests* row closes on the
  Dart half; a new row records the codec layout difference (kt's
  `SyncWireCommon` helpers vs Dart's helpers on the facade) with a verdict.

## Review outcome

**Owner review 2026-09-30 (cohesion, coupling, DDD/CA), findings folded
in above:**

1. *Rules were in the application service.* The first draft stated the
   request-shaping and answering rules as engine behaviour, which is where
   Dart's dominance filter already sits inline. They are now two stateless
   domain services; the engine gathers and sends.
2. *A value with two meanings.* "Bare digest" made `ChannelDigest` mean two
   things, told apart by inspecting the stream list. Announcement is now
   its own concept and its own field; the empty-list reading is the
   codec's alone.
3. *An aggregate that was a value.* `PeerHoldings` holds no entity and no
   invariant beyond set semantics; it is a value with pure transitions.
4. *The pipeline was implicit.* Scope (domain), budget (application
   mechanism), send (transport); learn (domain transition), answer or pull
   — now placed per layer on both twins so the port cannot land a rule in
   `PullPlanner`.

**Approved (owner, 2026-09-30)** as revised. Kotlin plan follows in gossip-kt `docs/superpowers/plans/`.
