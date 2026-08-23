# Glossary

The ubiquitous language of `packages/gossip`, one line per term, in plain
language. Terms are grouped by the bounded context that owns them (see
[ADR-010](packages/gossip/docs/adr/010-ddd-layered-architecture.md) for the
context map and the boundary rule that keeps each context's language its
own). `shared/` terms are the true leaf every context builds on.

## sync

The context that replicates the event log between peers: channels, streams,
entries, and the anti-entropy protocol that keeps them converged.

- **Channel** — A named sync group: a set of streams shared with a set of
  peers, plus local membership metadata. Membership is NOT enforced by the
  protocol — any peer that has the channel locally can sync it.
- **Stream** — An append-only, ordered log of entries inside a channel; the
  unit two peers reconcile independently of every other stream.
- **Entry** — One immutable, HLC-stamped, opaque-payload item appended to a
  stream — the smallest unit of replicated data.
- **Digest** — A compact summary of a channel's (or stream's) sync state —
  version vectors, not the entries themselves — sent so a peer can tell what
  it's missing without transmitting the data yet.
- **Delta** — The entries a peer is actually missing, computed from a digest
  comparison and sent to fill the gap the digest exchange revealed.
- **Dominance** — The version-vector comparison ("does my state already
  contain everything of yours?") that decides whether data needs sending at
  all; see version vector below.
- **Version vector** — Per-author sequence counters summarizing how much of
  each author's history a stream has seen; the mechanism digests and
  dominance are both built from.
- **Quiescence** — The state a gossip loop settles into once a round after
  round carries nothing new; detected per round and used to stretch the
  anti-entropy interval toward its idle ceiling.
- **News** — Anything worth telling peers about since the last round (a
  local append, a merge, delta traffic in either direction); its arrival
  snaps the pacer back out of quiescence to the active cadence.
- **Partner** — The peer a gossip round picks to exchange with. Sync sees a
  partner only through its own `SyncPartner` view (node id, smoothed RTT,
  last anti-entropy time) — never through membership's `Peer` directly (see
  `PeerDirectory` in ADR-010's boundary rule).
- **Anti-entropy** — The periodic digest/delta exchange that reconciles two
  peers' streams to identical state, independent of any single message
  actually arriving — the completeness safety net.
- **Reactive push** — The eager, immediate send of a freshly-appended local
  entry to peers (rumor-mongering) ahead of the next anti-entropy round;
  anti-entropy is the safety net behind it, not the primary delivery path.

## membership

The context that maintains the peer model and detects failures: the SWIM
protocol.

- **Peer** — A remote node this node knows about and tracks the
  reachability of, held in the peer registry.
- **Probe** — A SWIM ping sent directly to a peer, or indirectly via
  intermediaries, to test whether it is still reachable.
- **Suspicion** — The intermediate reachability state a peer enters after a
  failed probe, before it is confirmed unreachable or refuted by a later
  response.
- **Liveness evidence** — Any observed signal that a peer is alive: a probe
  ack, but also contact recorded from the sync path (anti-entropy, message
  receipt) — evidence from outside the probe cycle can refute suspicion too.
- **Suppression** — Skipping a peer's next scheduled probe because recent
  liveness evidence already shows it's alive; bounded by a hard ceiling so
  it can never mask a real failure indefinitely.
- **Reachability** — A peer's current SWIM status: reachable, suspected, or
  unreachable (`PeerStatus`).

## shared

The true leaf kernel both contexts build on; imports nothing from `sync/`
or `membership/`.

- **HLC (Hybrid Logical Clock)** — A timestamp combining wall-clock time
  with a logical counter, giving every entry a causally-consistent,
  monotonically increasing stamp even across clock skew between devices.
- **Node identity (`NodeId`)** — The globally unique identifier for a single
  device/peer participating in gossip; the identity both sync and
  membership key their state by.
