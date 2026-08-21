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
   each context owns its own messages; only the codec crosses.

### The map

```
lib/src/
  shared/        # kernel — true leaf; imports nothing outside itself
  sync/          # CORE DOMAIN: anti-entropy replication of the event log
  membership/    # SWIM liveness: peer model + the detector that maintains it
  codec/         # wire codec — infrastructure module; the documented crossing
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
  `SyncPartner` value object — not membership's `Peer`. The adapter
  `sync/infrastructure/membership_peer_directory.dart` imports
  `membership/domain` (the concession) and delegates to `PeerRegistry`.
  `Coordinator` wires it. This is the named sync↔membership contract;
  WIRE4-19 digest-on-probe piggybacking later extends this port.
- Membership imports nothing from sync (holds today; the boundary test
  keeps it true).
- Engines depend on a **codec interface in shared/**
  (`MessageCodec`: encode/decode `ProtocolMessage`), injected via
  constructor (today both engines construct `ProtocolCodec()` inline —
  that inline construction is replaced by the injected interface;
  `Coordinator` and the test harnesses pass the concrete codec).
  `codec/` holds `ProtocolCodec`, importing both contexts'
  `domain/messages/` — the one documented crossing, exercised by a
  standalone infrastructure module. Each engine `is`-checks only its
  own context's message types, so neither names a foreign type.

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

`shared/` (kernel — every file verified to import only shared-bound files):

| Target | Files (from today's tree) |
|---|---|
| `shared/domain/value_objects/` | node_id, channel_id, stream_id, hlc, log_entry, log_entry_id, version_vector, rtt_estimate |
| `shared/domain/errors/` | sync_error, domain_exception |
| `shared/domain/events/` | domain_event (the WHOLE `sealed` family — Dart sealing requires one library; it references only shared types; deliberate, documented) |
| `shared/domain/results/` | compaction_result (referenced by the sealed events; wart, documented) |
| `shared/domain/services/` | jitter, quiescence_pacer, rtt_tracker, time_source (`hlc_clock` is NOT shared — only sync stamps and merges; it goes to `sync/domain/`) |
| `shared/domain/interfaces/` | time_port, message_port (ARCH3-1 fixed here), local_node_repository, message_codec (NEW), protocol_message (moved base) |
| `shared/domain/observability/` | log_level |
| `shared/infrastructure/` | real_time_port, in_memory_time_port, in_memory_message_port, in_memory_local_node_repository |

`sync/`:

| Target | Files |
|---|---|
| `sync/domain/` | channel_aggregate, stream_config, hlc_clock, merge_result, channel_delta |
| `sync/domain/values/` | channel_digest, stream_digest |
| `sync/domain/messages/` | digest_request, digest_response, delta_request, delta_response |
| `sync/domain/interfaces/` | channel_repository, entry_repository, state_materializer, retention_policy, peer_directory (NEW, + sync_partner VO beside it) |
| `sync/application/` | channel_service, gossip_engine |
| `sync/application/materialization/` | materialization_service, fold_cursor, materializer_state |
| `sync/infrastructure/` | in_memory_channel_repository, caching_channel_repository, in_memory_entry_repository, membership_peer_directory (NEW — the concession) |

`membership/`:

| Target | Files |
|---|---|
| `membership/domain/` | peer, peer_metrics, peer_registry |
| `membership/domain/messages/` | ping, ack, ping_req |
| `membership/domain/interfaces/` | peer_repository |
| `membership/application/` | peer_service, failure_detector |
| `membership/infrastructure/` | in_memory_peer_repository |

`codec/`: protocol_codec (implements shared `MessageCodec`).

`coordinator/`: coordinator, coordinator_config, channel, event_stream,
adaptive_timing_status, gossip_sync_activity, health_status,
resource_usage, sync_state.

The test tree moves to mirror `lib/` (`test/protocol/` splits into
`test/sync/`, `test/membership/`; `test/support/`, harnesses, and
integration suites keep their roles with rewritten imports).

## Boundary enforcement — architecture test

New `test/architecture/boundary_test.dart` walks every import in
`lib/src` and fails on:

1. `shared/` importing sync/membership/codec/coordinator;
2. a context file outside `<context>/infrastructure/` importing another
   context;
3. membership importing sync anywhere (no current need — the concession
   stays unexercised there until a real interface demands it);
4. `codec/` importing anything beyond the two contexts'
   `domain/messages/`, `domain/values/`, and shared;
5. anything under `lib/src` importing `coordinator/` (composition root
   is a sink, not a dependency).

## Public API stability

`lib/gossip.dart` keeps **identical exports** (same public names) —
gossip_nearby and gossip_bluey import only the barrel (verified: zero
`package:gossip/src/` imports in either transport), so they compile
untouched.

## Migration method

One mechanical batch per module, each ending with the full gate green:
`shared/` → `membership/` → `sync/` (incl. the new PeerDirectory port +
adapter and codec-interface injection) → `codec/` → `coordinator/` →
architecture test → docs. Import rewrites are scripted (Python precise
string replacement — the proven pattern for bulk mechanical refactoring
in this repo); the new interfaces (PeerDirectory, MessageCodec,
SyncPartner) are TDD'd (failing test first), moves are covered by the
existing suites staying green.

## Documentation

- ADR-010 rewritten: the context map, the boundary rule + concession,
  the interior layer convention, the engines-as-application decision,
  the codec crossing, the sealed-events compromise.
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
