# ADR-010: Bounded-Context Architecture

## Status

Accepted — 2026-08-23. **Supersedes the previous content of this ADR**
(a five-layer, DDD-by-layer organization with top-level `domain/`,
`application/`, `protocol/`, `infrastructure/`, `facade/` folders; see git
history for the superseded text). Shipped as Batch 3, Part 2 of
[health-architecture-alignment](../../../../docs/backlog/health-architecture-alignment.md)
(commits `4024678..544efe8`), per design spec
[2026-08-21-bounded-contexts-restructure-design.md](../../../../docs/superpowers/specs/2026-08-21-bounded-contexts-restructure-design.md).

## Context

The prior layout organized `packages/gossip` by DDD *layer*
(`domain/application/protocol/infrastructure/facade`), so the file tree said
"DDD template" instead of what the software does. Two subdomains were
invisible in the tree — anti-entropy synchronization and SWIM membership —
and their only contract was undocumented reach-ins through `PeerRegistry`.
Port interfaces (`MessagePort`, `TimePort`) lived in the outermost
(infrastructure) layer while inner layers depended on them, backwards from
the dependency rule the layers claimed to enforce (audit finding ARCH3-1).
The 2026-08-20 wire-scheduling audit (WIRE4-3, WIRE4-19) wanted an explicit,
named sync↔membership contract instead of the reach-ins, motivating a
structure where that contract could be drawn as a single seam.

### Context map — derived from the import graph, not assumed

The project's Kotlin port (`gossip-kt`) had already organized its code
concept-first (`sync/`, `detection/`, a leaf `shared/`), and the working
assumption going in was to port that layout verbatim. Checking it against
the *actual* Dart dependency graph rejected it in four places — recorded
here as findings to port back to `gossip-kt`:

1. kt splits `channels/` from `entries/`, but its own `ChannelService`
   straddles the split (append = HLC stamp + entry write + membership check
   + retention, all one operation). Channels, streams, entries, retention,
   and materialization are one language: the replicated event log → one
   **sync** context.
2. kt splits `peers/` from `detection/`, but the SWIM detector *is* the
   process that maintains the peer model — one thing, arbitrarily cut in
   two. Here it stays one **membership** context.
3. kt homes `RttTracker` in `detection/model`, but both engines consume it
   (adaptive gossip interval, adaptive probe timeout) — it belongs in the
   **shared kernel**, not inside membership.
4. kt's `messages/` owns every context's wire messages *and* a single
   central codec centrally. Here each context owns its own messages **and**
   its own codec — the central codec is dissolved outright, not ported (see
   the codec section below).

### The map

```
lib/src/
  shared/        # kernel — true leaf; imports nothing outside itself
  sync/          # CORE DOMAIN: anti-entropy replication of the event log
  membership/    # SWIM liveness: peer model + the detector that maintains it
  coordinator/   # facade shell / composition root (not a bounded context)
```

`coordinator/` is deliberately flat (`coordinator.dart`, `channel.dart`,
`event_stream.dart`, `coordinator_config.dart`, `adaptive_timing_status.dart`,
`gossip_sync_activity.dart`, `health_status.dart`, `resource_usage.dart`,
`sync_state.dart`) — it is the composition root that wires the two contexts
together and the library's public facade, not a bounded context with its
own ubiquitous language, so it gets no `domain/application/infrastructure`
interior.

## Decision

### Boundary rule (owner decision, Joel 2026-08-21 — binding)

**A bounded context may import `shared/` and itself — nothing else. The
single exception: its `infrastructure/` layer may import another context,
as a concession, to implement an adapter for an interface its own domain
defines.**

This is enforced today by exactly one adapter, and machine-checked (see
below):

- Sync's use of peer state goes through a **sync-owned port**,
  `sync/domain/interfaces/peer_directory.dart`
  (`abstract interface class PeerDirectory`), with a sync-owned
  `SyncPartner` value object (`sync/domain/value_objects/sync_partner.dart`)
  — never membership's `Peer`. `GossipEngine` (sync's application-layer
  protocol service) depends only on `PeerDirectory`/`SyncPartner`. The
  adapter `sync/infrastructure/membership_peer_directory.dart`
  (`MembershipPeerDirectory`) imports `membership/domain` — the one
  concession — and delegates to `PeerRegistry`, mapping each method to its
  `PeerRegistry` counterpart as a pure pass-through (no new selection or
  mutation semantics introduced at the seam). `Coordinator` constructs it
  and injects it into `GossipEngine`. This is the named sync↔membership
  contract; WIRE4-19's digest-on-probe piggybacking is expected to extend
  this port later.
- Membership imports nothing from sync — it exercises no concession today;
  its row in the edge table stays `{membership, shared}` until a real
  interface demands more.
- `MembershipPeerDirectory` is the **only** exercised concession anywhere in
  the tree — there is no other cross-context exception class.

### Interior layout: `domain/application/infrastructure` + kind-named taxonomy

Every context (`shared`, `sync`, `membership`) contains exactly `domain/`,
`application/`, `infrastructure/` (`shared/` has no `application/` — it is a
kernel of values, interfaces, and pure services, not use cases).
`coordinator/` is exempt, per above.

Within a `domain/` folder, subfolders name **kinds**, never roles:
`aggregates/`, `entities/`, `value_objects/`, `services/`, `interfaces/`,
`events/`, `errors/`, `messages/` — the same name means the same kind of
thing in every context. Concretely, relative to the old layout:

- `protocol/values/` became `value_objects/` — no folder is ever called
  `values/`.
- `domain/results/` dissolved entirely: `MergeResult`, `ChannelDelta`,
  `CompactionResult` are plain value objects and live in `value_objects/`
  (`sync/domain/value_objects/merge_result.dart`,
  `channel_delta.dart`, `compaction_result.dart`).

**One deliberate role-named exception:** `messages/` members are also value
objects by kind, but the grouping is load-bearing — it is each context's
*published-language* seam, the thing its codec encodes and the boundary
test's `imports` still has to route through. Sync's messages
(`sync/domain/messages/`: `digest_request.dart`, `digest_response.dart`,
`delta_request.dart`, `delta_response.dart`) and membership's
(`membership/domain/messages/`: `ping.dart`, `ack.dart`, `ping_req.dart`)
are kept separate from their contexts' other value objects for this reason.

### Engines are application layer; the protocol layer retires

`GossipEngine` (`sync/application/gossip_engine.dart`) and
`FailureDetector` (`membership/application/failure_detector.dart`) are
**application-layer** use-case orchestrators over domain services and
ports, not a separate "protocol layer." The reusable protocol *policy* they
lean on already lived in domain services and value objects, not the
engines themselves: pacing is `QuiescencePacer` and `applyJitter`
(`shared/domain/services/`), and dominance is `VersionVector.dominates`
(`shared/domain/value_objects/`). The engines' own job is orchestration:
track whether a round has news, pick a partner, drive the digest/delta or
probe/ack exchange over those domain primitives, record telemetry, emit
events. There is no longer a `protocol/` folder in
`packages/gossip` at all — the concept fully retires there. (The transport
packages, `gossip_nearby` and `gossip_bluey`, are layer-first, single-context
packages and keep their own `protocol/` layers; this ADR governs the core
package only.)

### Per-context codecs + `WireTypes` partition (the dissolved compromise)

kt's central `messages/` module owns every context's wire messages *and* a
shared codec. The equivalent here, `ProtocolCodec`, has dissolved entirely —
**there is no crossing module at all, not even a codec.** In its place:

- `SyncMessageCodec` (`sync/infrastructure/sync_message_codec.dart`) encodes
  and decodes `DigestRequest`/`DigestResponse`/`DeltaRequest`/`DeltaResponse`
  — wire type bytes 3-6.
- `MembershipMessageCodec`
  (`membership/infrastructure/membership_message_codec.dart`) encodes and
  decodes `Ping`/`Ack`/`PingReq` — wire type bytes 0-2.
- Both implement the one shared interface,
  `shared/domain/interfaces/message_codec.dart`
  (`abstract interface class MessageCodec`), and each answers `null` from
  `decode` for a type byte it recognizes as belonging to the *other* known
  family ("not mine" — routine traffic sharing one transport), while
  throwing for a byte that belongs to **no** known context (genuinely
  corrupt) or for a malformed frame of its own family.
- The only shared artifact is the envelope agreement:
  `shared/domain/value_objects/wire_types.dart` (`abstract final class
  WireTypes`) — pure integer constants partitioning the type-byte space
  (`membership = {0, 1, 2}`, `sync = {3, 4, 5, 6}`, `known` = their union).
  A dedicated test (`test/shared/domain/value_objects/wire_types_test.dart`)
  asserts the partition has no overlap. Referencing `WireTypes` is not a
  context-to-context dependency; it is the same partition both codec
  families already have to agree on to share a transport.
- The wire format itself did not change — only which class encodes which
  message. `GossipEngine` and `FailureDetector` each take their context's
  codec injected via constructor (`codec: SyncMessageCodec()` /
  `codec: MembershipMessageCodec()`, wired by `Coordinator`); the static
  payload-budget helper `SyncMessageCodec.maxEntryPayloadForBudget` moved
  with the sync codec — entries are a sync concern.
- Future WIRE4-19 digest-on-probe piggybacking stays feasible through an
  **opaque payload**: membership's `Ping` would carry bytes a sync-provided
  hook supplies and sync's codec decodes — neither codec ever needs to name
  the other context's message types.

With the codec dissolved, `MembershipPeerDirectory` is confirmed as the
boundary rule's only exercised concession anywhere in the tree — no crossing
module means one fewer place a violation could hide.

### Per-context sealed event families

`shared/domain/events/domain_event.dart`'s `DomainEvent` reduced to a plain
**abstract base class** (no longer `sealed`) plus `SyncErrorOccurred`, which
stays beside it — it wraps the shared `SyncError` type and has no
context-specific emitter. The concrete events split into two per-context
`sealed` families:

- `sealed class SyncEvent extends DomainEvent`
  (`sync/domain/events/sync_events.dart`): `ChannelCreated`,
  `ChannelRemoved`, `MemberAdded`, `MemberRemoved`, `StreamCreated`,
  `EntryAppended`, `EntriesMerged`, `StreamCompacted`,
  `BufferOverflowOccurred`, `NonMemberEntriesRejected`.
- `sealed class MembershipEvent extends DomainEvent`
  (`membership/domain/events/membership_events.dart`): `PeerAdded`,
  `PeerRemoved`, `PeerStatusChanged` (using
  `membership/domain/value_objects/peer_status.dart`'s `PeerStatus`),
  `PeerOperationSkipped`.

Boundary purity is gained by this split — `PeerAdded` and friends finally
live inside `membership/` instead of a shared file — and it removes the
`CompactionResult`-living-in-`shared/` wart the old layout had. Each
per-context switch stays exhaustive. The *global* switch over `DomainEvent`
loses exhaustiveness by design (verified 2026-08-22: no production or test
code switched exhaustively over the whole family before this change, so
nothing broke); consumers of the shared `Stream<DomainEvent>` are otherwise
unaffected — every context-specific event still `is a` `DomainEvent`.

### Context barrels

Each module gained a root barrel — `shared/shared.dart`, `sync/sync.dart`,
`membership/membership.dart` — naming its public surface; `coordinator/`
and the public `lib/gossip.dart` import through them where convenient. Each
barrel is a **mechanical, full re-export** of its context's `domain/` and
`infrastructure/` files (not a curated subset) — stated honestly here so the
convention isn't mistaken for an encapsulation boundary. The encapsulation
boundary is the edge table below, not the barrel's export list. `lib/gossip.dart`,
the package's actual public API, keeps its own curated, identical set of
exported symbols regardless of what the context barrels re-export.

### Boundary enforcement — the machine-checked edge table

`test/architecture/boundary_test.dart` declares the intended edge table as
data, then walks every import in `lib/src` and fails on any edge not in the
table (fluent's `architecture-edges.test.ts` CA2-3 pattern). The table
below mirrors that test exactly — it is the authoritative edge list; if the
two ever disagree, the test wins and this ADR is stale.

```dart
// module            → may import
const edges = {
  'shared':            {'shared'},
  'sync':              {'sync', 'shared', 'membership'}, // 'membership' ONLY from sync/infrastructure/ (the ACL)
  'membership':        {'membership', 'shared'},
  // Composition root: may import everything. It is the graph's sink —
  // "nothing imports it" is enforced by its absence from every other row.
  'coordinator':       {'coordinator', 'shared', 'sync', 'membership'},
};
```

The walker enforces two things beyond the table itself: (1) a context file
importing another context must sit under `<context>/infrastructure/` (the
ACL concession) — `sync/domain/` and `sync/application/` may never name
membership, and vice versa; (2) nothing under `lib/src` imports
`coordinator/`.

## Consequences

### Positive

- **The tree screams the domain**: `sync/` and `membership/` are visible
  subdomains instead of being smeared across `domain/`, `application/`, and
  `protocol/`.
- **The sync↔membership contract is named and machine-checked**, not an
  undocumented reach-in — `PeerDirectory`/`SyncPartner`/
  `MembershipPeerDirectory` is the only place it can happen, and the
  boundary test fails the build if a second one appears.
- **No crossing codec module**: wire knowledge for each context's messages
  lives with that context; `WireTypes` is a constants-only partition
  agreement, not a dependency.
- **Per-context event families restore boundary purity** for `PeerAdded`
  and friends, and remove the `CompactionResult`-in-`shared` wart.
- **A newcomer question — "where does X live?" — usually has one answer**:
  is it about replicating the log (`sync/`), about peer liveness
  (`membership/`), about both (`shared/`), or about wiring the two together
  (`coordinator/`).

### Negative

- **More files and more boilerplate at the seams**: `SyncPartner` duplicates
  a subset of `Peer`'s fields; `PeerDirectory` duplicates a subset of
  `PeerRegistry`'s method surface; two codecs exist where one did before.
- **The global `DomainEvent` switch is no longer exhaustive** — code (and
  especially tests) that pattern-matches across every event kind needs a
  `default` arm now; this was verified to affect nothing at the time of the
  change, but it is a standing constraint on new code.
- **Public API and wire format are unchanged, but the internal `import
  'package:gossip/src/...'` paths every consumer's tests reference all
  moved** — a one-time churn cost, paid in full by this restructure and its
  test-tree mirror (`test/sync/`, `test/membership/`, `test/shared/`,
  `test/coordinator/`).
- **The boundary is a folder + a test, not a physical package boundary** —
  see Alternatives Considered; nothing stops a determined author from
  editing the edge table itself to add an unwanted edge (the mitigation is
  that doing so is a visible, reviewable diff, not a build failure that
  can't be silenced).

## Alternatives Considered

Two comparable projects (Eventur's `common/`-kernel layout, fluent's
context-per-folder layout with a machine-checked edge test) were scanned
2026-08-21 at Joel's request; both converge on the same target this ADR
adopts (contexts with `domain/application/infrastructure` interiors,
cross-context imports only at infrastructure). Adopted from them: per-context
sealed event families (Eventur's per-feature `domain/events/`, fluent's
per-context `domain/events.ts`); the edge-table architecture test (fluent's
`architecture-edges.test.ts`); explicit ACL naming (fluent names its
cross-context adapters `*-acl.ts`; here, `MembershipPeerDirectory`); context
barrels (fluent's per-context `index.ts`); a root `GLOSSARY.md` (fluent's).

Deliberately **not** adopted, recorded so the divergence is a decision and
not an oversight:

- **Eventur's one-class-per-use-case application layer**
  (`UseCase<Params, Response>`): gossip's application layer hosts
  long-running protocol orchestrators (the engines) and cohesive service
  facades (`ChannelService`, `PeerService`) — request/response use-case
  classes are the wrong shape for a protocol library's continuous loops.
- **Eventur's `features/` parent folder**: with two contexts and three
  modules, flat top-level directories (`shared/`, `sync/`, `membership/`,
  `coordinator/`) already scream; an extra wrapping folder would add
  nothing. fluent's end state also keeps contexts as top-level siblings.
- **fluent's Stage 2 (contexts promoted to real packages)**: a folder
  boundary plus an edge test is Stage 1. Promoting `sync/`/`membership/` to
  separate Melos packages (making the wall physical, as pnpm workspace
  isolation does for fluent) stays available later if the boundary test
  ever proves insufficient. Non-goal today.
- **Porting gossip-kt's `channels/`/`entries/` split, `peers/`/`detection/`
  split, `RttTracker` placement, or its central `messages/` module
  verbatim**: rejected in all four places by the actual Dart import graph
  (see Context above) — recorded there as findings for `gossip-kt`'s own
  roadmap to consider porting back.
