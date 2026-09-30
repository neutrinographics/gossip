# A digest names only what the peer holds — rulings

**Status:** proposed 2026-09-30, for owner review. **Item:** [Only tell a peer about the groups you both belong to](../backlog/engine-scope-digests-to-shared-groups.md) (roadmap focus item 10). **Applies to:** both twins; Kotlin first, because the bytes are the server's. **Pulls forward from wire-efficiency phase 2 for Kotlin:** request-scoped and dominance-filtered digest responses, and the byte-budgeted digest rotation — the design depends on them. Recency suppression stays in phase 2.

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

**Holdings** — a fact sync keeps per peer: the channels that peer has shown
it holds, learned only from the channels it names in its digests, requests
and responses alike. It only grows: a dominance-filtered response may omit a
channel entirely, so an omission is not evidence, only a name is. Cleared
with the peer. Never persisted; our own restart forgets it and the peer's
next digest teaches it again.

**`PeerHoldings`** — the aggregate: one value over every peer's holdings,
with pure transitions — learn the names a peer used, forget a peer — and one
query: which of these channels has this peer shown? Held in a cell by the
engine, as the pulls are. It is sync's because it is about what a peer
*holds*, not whether it is alive; membership never sees it.

**Bare digest** — a `ChannelDigest` with no streams. On the wire it is
`"streams": []`, legal in every dialect today and about 65 bytes for a
36-character id. It says: *I hold this channel; if you do too, show me your
digest for it.* Named as a factory and a getter on the value, not a new
type, because on the wire it is one list with the full digests. A channel
that genuinely has no streams yet produces the same shape, and the same
reading is right for it: the peer answers with what it has, which is how
the two learn they share it.

**Announce budget** — the bytes a request may spend on bare digests. The
bare list is the one cost that scales with how many channels a node holds,
and a hub's channel count is unbounded; the announce budget bounds what a
hub spends per round naming channels a phone will never hold.

## Rulings (proposed)

1. **A request names every channel we hold, in one of two forms.** For each
   channel we hold: a full digest — the stream digests, as today — if the
   peer has shown it holds the channel; a bare digest otherwise. Full
   digests are fitted first, under the message budget with the existing
   request-side rotation. Bare digests fill the announce budget in the room
   that remains, rotated by a cursor of their own, so a hub over the budget
   names every channel to every peer across successive rounds and never the
   same head twice. No priority for new channels: a peer under the budget
   names everything every round, so a channel created on either side is
   shared within one round of both holding it; the only node that rotates
   is a hub, whose peers are small.

2. **A response answers the request and never widens beyond it.** For each
   channel the request names that we hold: a bare digest is answered with
   our whole digest for that channel — every stream we hold, no dominance
   filter is possible without the requester's vectors; a full digest is
   answered as the Dart twin answers today — the named streams we hold,
   dominance-filtered, fitted under the message budget with the
   response-side cursor. A channel we do not hold is dropped at debug on
   both twins. The responder's reciprocal pull runs on the full digests
   only; a bare digest carries nothing to pull.

3. **Every name teaches holdings.** On receiving a request or a response,
   the channels it names are learned as the sender's holdings before
   anything else is done with it. A response naming a channel we do not
   hold is dropped at debug, not emitted as a `protocolError`: an old peer
   that still answers with everything is a legitimate peer, not a broken
   one. This is the Dart flow-back the divergence register's
   *Unknown-channel digests* row already recommends; that row closes with
   this ruling.

4. **Holdings are cleared with the peer and nowhere else.** A peer removal
   forgets its holdings; a stop forgets all. A channel a peer once named and
   has since stopped holding stays in its holdings — nothing in either
   twin removes a channel today, and the cost of the stale name is one full
   digest per round the peer drops at debug. Recorded as a limit, not
   solved; if channel removal ever ships, the peer's next request, which
   names everything it holds, is where a refresh would come from.

5. **The announce budget is a configuration value, defaulting to 1 KB.**
   About fifteen ids per round. A `CoordinatorConfig` field beside
   `maxMessageBytes` on both twins, applied after the full digests are
   fitted and never exceeding the room the message budget leaves. For a
   phone it is never reached. For the server, a phone with three shared
   channels receives three full digests plus at most a kilobyte of names
   per round whatever the tenant grows to, and the 36 channels of today are
   named across three rounds. The value is a starting point: the tunnel
   measurement after the Kotlin half may move it.

6. **No wire change.** No new key, no marker bump, no flag day. An empty
   `streams` list decodes in every dialect in the fleet; an old responder
   answers a bare digest with nothing and drops it; an old requester still
   names every channel it holds, so a new node's holdings fill from an old
   peer on its first request. One bare-digest vector joins the canonical
   conformance set in both repos.

7. **Order.** Kotlin first, as its own PR: `PeerHoldings`, bare digests,
   the scoped request, the scoped and dominance-filtered response, the
   digest budgeter with its two cursors and the announce budget. Then the
   server bump, live-device validated through the tunnel against the
   2026-09-29 two-phone reading (~2.2 MB per phone per minute), which is
   where the production win lands whole: the server's answers become
   request-scoped and its requests carry the phone's shared channels plus
   the announce budget, and no phone needs a new pin for it. Then the Dart
   half, which serves the nearby meshes (a phone with nineteen groups
   beside a tablet with one) and parity, followed by the app pin bump in
   the normal course. Then a production meeting read against 5 MB per
   phone per minute with two phones and 1 MB with eight.

## What this is not

- Not membership. The channel aggregate's member set stays local metadata
  the protocol never reads; holdings are what a peer *shows*, not what an
  app *declares*.
- Not a change to what a digest does once shared: pulls, dominance,
  budgets, stalls and pacing keep their rules. Only *which* channels a
  digest names is decided differently.
- Not the disclosure fix. A bare digest still names channels in plaintext to
  every peer that connects; it is the one place a keyed hash would later go
  (recorded below), and full digests for shared channels can stay
  plaintext even then.
- Not hub mode. A hub that never announces would save the last kilobyte;
  the rule above is correct for star and mesh alike without a switch, and
  the switch waits for a measurement that says the kilobyte matters.

## Pins the plans must carry

- **Aggregate:** learning a name adds it and never removes another; a
  dominated response that omits a channel leaves it held; forgetting a peer
  removes only that peer; a stop clears all; every transition answers a new
  value and leaves its input untouched.
- **Request:** a channel the peer has shown gets a full digest, one it has
  not gets a bare digest; the announce budget is respected with the full
  digests already fitted, and is not spent when the full digests fill the
  message; the bare cursor rotates so a hub over budget names every channel
  across rounds; a channel created after first contact is named bare on the
  very next request.
- **Response:** a bare digest for a held channel is answered with every
  stream of it; a full digest is answered with the named streams only,
  dominance-filtered; an unheld channel is dropped at debug and appears
  nowhere in the response; the reciprocal pull ignores bare digests.
- **The join:** one side creates a channel after first contact; on the
  next request from either side it is named bare; the round after the other
  side creates it, the pair holds each other's digests for it and the
  first pull is issued.
- **Mixed fleet:** a bare digest to a responder on today's code produces no
  answer and no error; a request from a requester on today's code fills
  holdings with every channel it holds; a response on today's code naming
  everything is dropped at debug, not `protocolError`.
- **Wire:** a bare digest round-trips through both codecs in both versions
  and is byte-identical across twins; the conformance vector pinned in both
  repos.
- **Parity:** the Dart aggregate has the same shape and the same cases; the
  Dart engine's `protocolError` on an unknown channel in a response is gone
  and the register row closed; kt's response is request-scoped,
  dominance-filtered and budgeted with two cursors, cited to the Dart
  tests it translates.

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

- **Disclosure follow-up, new item:** name channels in bare digests by a
  keyed hash both holders can compute, so a bystander that connects learns
  nothing it did not already know. The seam is exactly the bare digest;
  full digests for shared channels stay plaintext.
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
  Dart half.

## Review outcome

_Pending owner review._
