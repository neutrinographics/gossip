# Bounded Contexts Restructure (Batch 3, Part 2)

**Date:** 2026-08-21
**Status:** Approved (design); implementation pending
**Drives:** the screaming-architecture half of
[health-architecture-alignment](../../backlog/health-architecture-alignment.md),
ARCH3-1 from the 2026-07-08 audit, and the explicit sync↔detection
contract motivated by WIRE4-3/WIRE4-19.
**Prerequisite:** Part 1
([architecture honesty fixes](2026-08-21-architecture-honesty-fixes-design.md))
is merged — the dead bridge is gone and `PeerService` is simplified, so
files move once into their final shape.

## Problem

`packages/gossip` is laid out by DDD layer, so the tree says "DDD
template" instead of what the software does. Two subdomains are
invisible (anti-entropy sync; SWIM membership), their only contract is
undocumented reach-ins through `PeerRegistry`, and the port interfaces
live in the outermost layer while inner layers depend on them
(ARCH3-1).

## Context map — derived from the import graph, not assumed

The gossip-kt layout was evaluated against the actual Dart dependency
graph and **rejected in four places** (recorded at the end as findings
to port back to gossip-kt):

1. kt's `channels/` vs `entries/` split is straddled by its own
   `ChannelService` (append = HLC stamp + entry write + membership
   check + retention). Channels, streams, entries, retention, and
   materialization are one language: the replicated event log → one
   **sync** context.
2. kt's `peers/` vs `detection/` split scatters one context: the SWIM
   detector is the process that maintains the peer model → one
   **membership** context.
3. kt homes `RttTracker` in `detection/model`, but both engines consume
   it (adaptive gossip interval, adaptive probe timeout) → shared kernel.
4. kt's `messages/` owns every context's wire messages centrally. Here
   each context owns its own messages AND its own codec — the central
   codec is dissolved, not ported (owner decision, Joel 2026-08-21: no
   standalone crossing module; see the codec paragraph under the
   boundary rule).

### The map

```
lib/src/
  shared/        # kernel — true leaf; imports nothing outside itself
  sync/          # CORE DOMAIN: anti-entropy replication of the event log
  membership/    # SWIM liveness: peer model + the detector that maintains it
  coordinator/   # facade shell / composition root (not a bounded context)
```

## Boundary rule (owner decision, Joel 2026-08-21 — binding)

**A bounded context may import `shared/` and itself — nothing else.
The single exception: its `infrastructure/` layer may import another
context, as a concession, to implement an adapter for an interface its
own domain defines.**

Consequences enforced by this spec:

- Sync's use of peer state goes through a **sync-owned port**:
  `sync/domain/interfaces/peer_directory.dart` with a sync-owned
  `SyncPartner` value object (`sync/domain/value_objects/`) — not
  membership's `Peer`. The adapter
  `sync/infrastructure/membership_peer_directory.dart` imports
  `membership/domain` (the concession) and delegates to `PeerRegistry`.
  `Coordinator` wires it. This is the named sync↔membership contract;
  WIRE4-19 digest-on-probe piggybacking later extends this port.
- Membership imports nothing from sync (holds today; the boundary test
  keeps it true).
- **The central codec dissolves into per-context codecs — no crossing
  module exists at all.** `ProtocolCodec` (internal-only: not exported
  from the barrel, unused by the transports) splits into
  `SyncMessageCodec` (`sync/infrastructure/`) and
  `MembershipMessageCodec` (`membership/infrastructure/`), each
  implementing the shared `MessageCodec` interface for its OWN message
  family and answering "not mine" for foreign type bytes. The only
  shared artifact is the envelope agreement: `wire_types.dart` in
  `shared/domain/value_objects/` partitions the type-byte space (pure
  constants; a shared test asserts the partition has no overlaps). The
  wire format itself does not change — only which class encodes which
  message. Engines take their context's codec injected via constructor
  (today both construct `ProtocolCodec()` inline and already ignore
  foreign message types after decoding, so behavior is equivalent);
  `Coordinator` and the test harnesses wire the concrete codecs. The
  static payload-budget helper (`maxEntryPayloadForBudget`, used by
  `Coordinator`) moves with the sync codec — entries are a sync
  concern. Future WIRE4-19 digest-on-probe piggybacking stays feasible
  via an **opaque payload**: membership's Ping carries bytes a
  sync-provided hook supplies and sync's codec decodes — neither codec
  ever names the other context.
- With the codec dissolved, the ACL adapter
  (`MembershipPeerDirectory`) is the boundary rule's ONLY exercised
  concession — there is no other exception class anywhere in the tree.

### PeerDirectory operations (derived from GossipEngine's real usage)

- `List<SyncPartner> reachablePartners()` — partner selection; a
  `SyncPartner` carries `nodeId`, `smoothedRtt?` (for the median-SRTT
  base interval), and `lastAntiEntropyMs?` (for recency suppression).
  Congestion stays where it is today (`MessagePort.pendingSendCount`) —
  the directory does not absorb transport concerns.
- `void recordContact(NodeId, int nowMs)` — liveness evidence from the
  sync path (consumed by membership's probe suppression).
- `void recordMessageReceived(NodeId)` — metrics.
- `void recordRtt(NodeId, Duration)` — RTT samples from digest
  round-trips.
- `void recordAntiEntropy(NodeId, int nowMs)` — exchange coverage
  (initiator and responder sides).

Exact signatures may adapt to the engine's call sites during
implementation; the boundary (sync never names membership types) is the
contract.

## Interior layout (owner decision — binding)

Every context contains exactly `domain/`, `application/`,
`infrastructure/` (subfolders inside each as needed). All domain logic
of a context is under its `domain/`. The engines are **application**
layer (use-case orchestrators over domain services + ports); their
protocol *policy* (pacing, news classification, dominance) already
lives in domain services. Wire messages are `domain/messages/` — value
objects of each context's published language. The separate "protocol
layer" concept retires; ADR-010's rewrite records this.

## File mapping

**Subfolder taxonomy (uniform across all contexts):** within a
`domain/` folder, subfolders use the repo's existing kind names —
`aggregates/`, `entities/`, `value_objects/`, `services/`,
`interfaces/`, `events/`, `errors/`, `results/`, `messages/` — the same
name for the same kind everywhere. (`protocol/values/` from today's
tree becomes `value_objects/`; no folder is ever called `values/`.)

`shared/` (kernel — every file verified to import only shared-bound files):

| Target | Files (from today's tree) |
|---|---|
| `shared/domain/value_objects/` | node_id, channel_id, stream_id, hlc, log_entry, log_entry_id, version_vector, rtt_estimate, log_level (from `application/observability/` — it is a plain enum VO of the logging seam), wire_types (NEW — the type-byte partition constants both codecs obey) |
| `shared/domain/errors/` | sync_error, domain_exception |
| `shared/domain/events/` | domain_event — reduced to an **abstract base class only**. The concrete events split into per-context `sealed` families (see sync/membership tables): `sealed class SyncEvent extends DomainEvent` and `sealed class MembershipEvent extends DomainEvent`. Boundary purity gained (`PeerAdded` finally lives in membership); per-context switches stay exhaustive; the *global* switch loses exhaustiveness — verify at plan time that no production code switches exhaustively over the whole family (tests may need `default` arms). This mirrors Eventur's per-feature event files and fluent's per-context `domain/events.ts`, and it removes the compaction_result-in-shared wart entirely. |
| `shared/domain/services/` | jitter, quiescence_pacer, rtt_tracker, time_source (`hlc_clock` is NOT shared — only sync stamps and merges; it goes to `sync/domain/services/`) |
| `shared/domain/interfaces/` | time_port, message_port (ARCH3-1 fixed here), local_node_repository, message_codec (NEW), protocol_message (moved base) |
| `shared/infrastructure/` | real_time_port, in_memory_time_port, in_memory_message_port, in_memory_local_node_repository |

`sync/`:

| Target | Files |
|---|---|
| `sync/domain/aggregates/` | channel_aggregate |
| `sync/domain/entities/` | stream_config |
| `sync/domain/value_objects/` | channel_digest, stream_digest (today's `protocol/values/`), sync_partner (NEW) |
| `sync/domain/services/` | hlc_clock |
| `sync/domain/results/` | merge_result, channel_delta, compaction_result |
| `sync/domain/events/` | sync_events (NEW file: the `sealed SyncEvent` family — channel/stream/entry/compaction events extracted from today's domain_event.dart) |
| `sync/domain/messages/` | digest_request, digest_response, delta_request, delta_response |
| `sync/domain/interfaces/` | channel_repository, entry_repository, state_materializer, retention_policy, peer_directory (NEW) |
| `sync/application/` | channel_service, gossip_engine |
| `sync/application/materialization/` | materialization_service, fold_cursor, materializer_state |
| `sync/infrastructure/` | in_memory_channel_repository, caching_channel_repository, in_memory_entry_repository, membership_peer_directory (NEW — the ACL, the rule's only concession), sync_message_codec (NEW — sync's half of today's protocol_codec, incl. the `maxEntryPayloadForBudget` helper) |

`membership/`:

| Target | Files |
|---|---|
| `membership/domain/aggregates/` | peer_registry |
| `membership/domain/entities/` | peer, peer_metrics |
| `membership/domain/events/` | membership_events (NEW file: the `sealed MembershipEvent` family — peer events extracted from today's domain_event.dart) |
| `membership/domain/messages/` | ping, ack, ping_req |
| `membership/domain/interfaces/` | peer_repository |
| `membership/application/` | peer_service, failure_detector |
| `membership/infrastructure/` | in_memory_peer_repository, membership_message_codec (NEW — membership's half of today's protocol_codec) |

`coordinator/`: coordinator, coordinator_config, channel, event_stream,
adaptive_timing_status, gossip_sync_activity, health_status,
resource_usage, sync_state.

The test tree moves to mirror `lib/` (`test/protocol/` splits into
`test/sync/`, `test/membership/`; `test/support/`, harnesses, and
integration suites keep their roles with rewritten imports).

## Boundary enforcement — the machine-checked edge table

New `test/architecture/boundary_test.dart`, shaped like fluent's
`architecture-edges.test.ts` (its CA2-3 pattern): the test declares the
intended edge table as data, then walks every import in `lib/src` and
fails on any edge not in the table. The table doubles as in-repo
documentation — adding an edge means editing the table, and the diff
review sees the architecture change explicitly.

```dart
// module            → may import
const edges = {
  'shared':            {'shared'},
  'sync':              {'sync', 'shared', 'membership'}, // 'membership' ONLY from sync/infrastructure/ (the ACL)
  'membership':        {'membership', 'shared'},
  'coordinator':       {}, // sink: may import anything; nothing imports it
};
```

Refinements the walker enforces beyond the table:

1. a context file importing another context must sit under
   `<context>/infrastructure/` (the ACL concession) — `sync/domain/` and
   `sync/application/` may never name membership, and vice versa;
2. membership currently exercises no concession (its row stays
   `{membership, shared}` until a real interface demands more);
3. nothing under `lib/src` imports `coordinator/`.

## Public API stability

`lib/gossip.dart` keeps **identical exports** (same public names) —
gossip_nearby and gossip_bluey import only the barrel (verified: zero
`package:gossip/src/` imports in either transport), so they compile
untouched.

## Migration method

One mechanical batch per module, each ending with the full gate green:
`shared/` → `membership/` → `sync/` (incl. the new PeerDirectory port +
adapter, and each context's codec split with injection) → `coordinator/` →
architecture test → docs. Import rewrites are scripted (Python precise
string replacement — the proven pattern for bulk mechanical refactoring
in this repo); the new interfaces (PeerDirectory, MessageCodec,
SyncPartner) are TDD'd (failing test first), moves are covered by the
existing suites staying green.

## Conventions adopted from the sample projects (Eventur `common/`, fluent)

Scanned 2026-08-21 at Joel's request; both projects converge on the same
target (contexts with `domain/application/infrastructure` interiors,
cross-context imports only at infrastructure). Adopted here:

- **Per-context sealed event families** (Eventur's per-feature
  `domain/events/`, fluent's per-context `domain/events.ts`) — see the
  shared/ table.
- **The edge-table architecture test** (fluent's machine-checked
  `architecture-edges.test.ts`) — see Boundary enforcement.
- **ACL naming made explicit** (fluent names its cross-context adapters
  `*-acl.ts`): `MembershipPeerDirectory` is documented as sync's
  anti-corruption layer over membership, and the boundary test pins its
  location under `sync/infrastructure/`.
- **Context barrels** (fluent contexts export a curated `index.ts`):
  each module gains a root barrel (`sync/sync.dart`,
  `membership/membership.dart`, `shared/shared.dart`) naming its public
  surface; `coordinator/` imports through them.
- **A ubiquitous-language glossary** (fluent's root `GLOSSARY.md`):
  gossip gains `GLOSSARY.md` defining the terms of both contexts
  (channel, stream, entry, digest, delta, dominance, quiescence, news,
  partner; peer, probe, suspicion, liveness evidence, suppression).

Deliberately NOT adopted, recorded so the divergence is a decision:

- **Eventur's one-class-per-use-case** (`UseCase<Params, Response>`)
  application layer: gossip's application layer hosts long-running
  protocol orchestrators (the engines) and cohesive service facades —
  request/response use-case classes are the wrong shape for a protocol
  library.
- **Eventur's `features/` parent folder**: with two contexts and three
  modules, flat top-level directories already scream; fluent's
  end-state also keeps contexts as top-level siblings.
- **Fluent's Stage 2 (contexts promoted to real packages)**: a folder
  boundary + edge test is Stage 1; promoting sync/membership to melos
  packages (making the wall physical, as pnpm isolation does for
  fluent) stays available later if the boundary test ever proves
  insufficient. Non-goal now.

## Documentation

- ADR-010 rewritten: the context map, the boundary rule + concession,
  the interior layer convention, the engines-as-application decision,
  the per-context codecs + wire-type partition (no crossing module),
  the per-context sealed event families, and the edge table (mirroring
  fluent's CLAUDE.md dependency diagram).
- New root `GLOSSARY.md` (see adopted conventions).
- ADR-011 amended where touched. CLAUDE.md architecture section updated
  (monorepo table + layer description). Backlog item closed on the
  roadmap.
- The four kt divergences recorded as findings for the gossip-kt
  roadmap (port the better answers back).

## Out of scope

- Any behavior change (this part is structure only; the two new
  interfaces are seams over existing behavior).
- Transport-package restructuring (they stay layer-first single-context
  packages; Part 1 already fixed their layering).
- WIRE4-19 piggybacking (future PeerDirectory extension).

## Gates

Full monorepo after every batch: `melos run test` + `melos run analyze`
all green/zero. The architecture test is part of the gate from its
introduction onward.
