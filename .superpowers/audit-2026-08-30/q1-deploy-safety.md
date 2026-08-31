# Q1 — Deploy safety: gossip-kt feature/compaction @ 6ee2b03 vs main @ 5255d74

**Scenario audited:** merge feature/compaction, redeploy opendoor-api with a submodule bump only
(server code unchanged, `wireVersion` left at default V1), app fleet unchanged (OpenDoorApp main:
old `ProtocolTranslator`, Dart gossip pinned to `73f6a580`, v1-only).

**Verdict up front: the scenario as stated is impossible — the server does not compile against
6ee2b03.** opendoor-api consumes gossip-kt as a composite source build
(`/Users/joel/git/neutrinographics/opendoor-api/settings.gradle.kts` line 4: `includeBuild("gossip-kt")`),
and the structure mirror renamed **every** package the server imports. Everything in the table below
that is a runtime behavior is therefore counterfactual: it describes what would change on the live
mesh *after* the mechanical compile fix, which is the realistic deploy.

## Compile break detail (item 8 — the gate)

Every one of the 27 distinct `com.neutrinographics.gossip.*` imports across 17 main-source files in
opendoor-api resolves to a package that no longer exists at 6ee2b03:

| Server import (main @ 5255d74 package) | 6ee2b03 package |
|---|---|
| `gossip.shared.*` (NodeId, ChannelId, StreamId, Hlc, LogEntry, LogEntryId, VersionVector, LocalNodeRepository, ProtocolMessage, RetentionPolicy, EntriesMerged/EntryAppended via wildcard) | `gossip.shared.domain.values.*`, `gossip.shared.domain.interfaces.*`, `gossip.sync.domain.events.*`, `gossip.sync.domain.interfaces.RetentionPolicy` |
| `gossip.entries.repository.{EntryRepository, InMemoryEntryRepository}` | `gossip.sync.domain.interfaces.EntryRepository`, `gossip.sync.infrastructure.InMemoryEntryRepository` |
| `gossip.entries.retention.{KeepAll,CountBased,TimeBased}Retention` | `gossip.sync.domain.services.*` |
| `gossip.entries.service.StateMaterializer` | `gossip.sync.domain.interfaces.StateMaterializer` |
| `gossip.transport.port.{MessagePort, IncomingMessage, MessagePriority}` | `gossip.shared.domain.interfaces.*` |
| `gossip.node.repository.InMemoryLocalNodeRepository` | `gossip.shared.infrastructure.*` |
| `gossip.peers.model.Peer` | `gossip.membership.domain.entities.Peer` |
| `gossip.messages.*`, `gossip.messages.ProtocolCodec` (PeerDto.kt; tests GossipTestClient/WebSocketSyncTest) | split into `gossip.membership.infrastructure.MembershipMessageCodec` + `gossip.sync.infrastructure.SyncMessageCodec` — the old `ProtocolCodec` class is **deleted** |

Verified by comparing `package` declarations across all of `src/main` at both commits: the old
namespaces (`gossip.shared`, `gossip.entries.*`, `gossip.messages`, `gossip.transport.port`,
`gossip.peers.*`, `gossip.node.repository`, `gossip.channels.*`, `gossip.detection.*`,
`gossip.clock.*`) have zero files at 6ee2b03.

Beyond imports, **`PgEntryRepository` no longer implements the interface**: 6ee2b03's
`EntryRepository` adds `getCompactionFloor` (line 149) and `adoptVersionFloor` (line 169)
(`sync/domain/interfaces/EntryRepository.kt`), which
`opendoor-api/src/main/.../sync/infrastructure/gossip/PgEntryRepository.kt` lacks. The engine calls
both on live paths (`GossipEngine.kt:396`, `:652`, `reportableFloor` :332), so they need real
implementations, not stubs. The interface also re-contracts duplicates: "Duplicate (author,
sequence) pairs must throw IllegalStateException" (`EntryRepository.kt:40`) — Pg's silent-skip
(`PgEntryRepository.kt:63-90`, `batchInsert(ignore = true)`) violates the letter of the new contract
but is benign in practice (see row 3).

`Coordinator.create(...)` itself is signature-compatible (`Coordinator.kt`, same params both sides),
`CoordinatorConfig` only gains `wireVersion` with default V1 plus `require()` guards satisfied by the
defaults, and the `EntriesMerged`/`EntryAppended` event shapes are field-identical (old
`shared/EntryEvents.kt` vs new `sync/domain/events/*.kt`) — so the fix is mechanical: imports plus
two `PgEntryRepository` methods.

## Behavior differences observable from outside the process

Sides: **OLD** = kt main @ 5255d74, **NEW** = kt feature/compaction @ 6ee2b03,
**TR** = deployed translator, OpenDoorApp `main:lib/features/sync/infrastructure/gossip/protocol_translator.dart`,
**DART** = pinned Dart gossip @ 73f6a580.

| # | Change | Observable effect | Class | Evidence |
|---|--------|-------------------|-------|----------|
| 1 | v1 delta frames are one single-entry batched envelope per (channel, stream); old batched all channels/streams into one DeltaRequest + one DeltaResponse | An exchange missing N streams is now N+N frames instead of 1+1 — chattier WebSocket, each frame smaller. Deployed translator iterates envelopes generically (nested `for` over map entries), so single-entry maps decode identically; a single-entry map is a strict subset of what it already parses. | SAFE | OLD `sync/engine/GossipEngine.kt:241-266` (batched response), `:351-395` (batched request); NEW `sync/application/GossipEngine.kt:300-321` (per-stream response), `:594-626` (per-stream requests); wrapper `sync/infrastructure/SyncWireV1.kt:102-112,137-158`; TR `_translateIncomingDeltaResponse` lines 119-141, `_translateIncomingDeltaRequest` 94-117 |
| 2a | v1 DeltaResponse gains additive `floor` key, emitted only when the compaction floor is non-empty | **Nothing today.** Floors move only via `ChannelService.compactStream` (never called: opendoor-api's only retention reference is display-only in `analytics/api/dto/PeerDto.kt:47-51`; no `compact` call anywhere in server main source), via incoming floors (deployed apps never emit the key — TR builds outgoing DeltaResponse with exactly sender/channelId/streamId→entries, lines 73-84), or via the authorship-claim path (row 9d, dormant). No auto-compaction exists: `CoordinatorConfig` has no `compactionInterval`; the only compact entry points are the new manual `Channel.compact()`/`EventStream.compact()` facades. | DORMANT | NEW `SyncWireV1.kt:147-156` (`if (msg.floor.entries.isNotEmpty())`); `coordinator/Channel.kt:115`, `EventStream.kt` compact(); `sync/application/ChannelService.kt` `compactStream` |
| 2b | …and if a floor WERE emitted | Old translator decodes the JSON, then constructs a **fresh** output map containing only sender/channelId/streamId/entries — the unknown `floor` key is silently dropped, no crash. The envelope always carries `entries` alongside, so fan-out still yields well-formed Dart frames (possibly with empty entry lists, which DART handles). Apps would simply never learn the floor (that's what the unshipped wire-floor-translation PR adds). | SAFE (if ever triggered) | TR lines 119-141 (no passthrough of unrecognized keys); NEW `SyncWireV1.kt:137-158` |
| 3 | EntryRepository duplicate appends now throw (contract); merge path filters first | **No live effect on the server.** The contiguity/dedup guard strips already-held and duplicate entries before the repository (`selectContiguousEntries`: keeps only `seq > ourVersion[author]` and contiguous). Residual path a remote peer CAN reach: a frame listing the same (author, seq) **twice within one frame** passes the filter twice (the accept predicate doesn't dedupe within the accepted run) → both copies hit `appendAll`. On the server that's still harmless: `PgEntryRepository.appendAll` pre-filters against existing rows and uses `batchInsert(ignore = true)` — but two copies in one batch would both survive its pre-filter and insert-ignore dedupes only on a unique index; worst case with a throwing repo, the exception is caught by the Coordinator receive loop, surfaced as `StorageSyncError` to `onError` — which the server does not wire (`SyncModule.kt:18-26` passes no callbacks) → swallowed; the collect loop survives, only that frame's merge is lost. | DORMANT (server); throw is reachable but contained | NEW `GossipEngine.kt:407-426,466-489`; `EntryRepository.kt:40`; Coordinator catch `coordinator/Coordinator.kt:338-345`; server `PgEntryRepository.kt:63-90`; no onError: `SyncModule.kt:20-24` |
| 4 | Ingestion guard: DeltaResponses for channels/streams the node doesn't hold are refused (trace log, silent) | OLD appended **anything** in the response map — phantom rows in Postgres for channels the server never joined, never advertised, never cleaned. NEW drops them at `channelRepository.findById == null`. On this fleet the difference rarely fires: DART @ 73f6a580 has no reactive push (only solicited responses; verified — the only `DeltaResponse(` constructions are the reply in handleDeltaRequest and log matching), and the server only requests channels it holds; trigger is a stale/late response arriving after channel removal. Trace log goes to `onLog` — also not wired → invisible. | SAFE (strict improvement) | OLD `GossipEngine.kt:274-315` (no channel check before `appendAll`); NEW `GossipEngine.kt:361-374`; DART `protocol/gossip_engine.dart` (no push path) |
| 5 | Decode failures surface as `PeerSyncError` via `DecodeResult.Malformed` instead of silent `null` drop | **Operationally identical for this server.** OLD: `codec.decode` returned null → skipped silently. NEW: `Malformed` → `onError?.invoke(PeerSyncError(MESSAGE_CORRUPTED, ...))` — server passes `onError = null`, so a burst of decode errors still produces no log, no crash, no disconnect; the receive loop continues either way. The improvement is real only once the server wires the callback. | SAFE (no-op here) | OLD `Coordinator.kt:288-292`; NEW `Coordinator.kt:306-336`; server `SyncModule.kt:18-26` |
| 6 | Pull-request expiry: fixed 5s keyed (channel, stream) → adaptive RFC-6298 2-30s (8s before samples) keyed **(peer, channel, stream)** + cleared on peer disconnect | Mesh-visible timing: (a) a lost DeltaResponse is re-requested after the adaptive timeout — can be slower than before (up to 30s on jittery links) or faster (2s floor); (b) per-peer keying means the server may pull the **same missing stream from several apps in parallel** where OLD serialized one pull per stream globally — more duplicate delta traffic in multi-app channels, all filtered on arrival (row 3 guard); (c) an app's WS disconnect now releases its pendings immediately (`Peers.remove` → `clearPendingRequestsForPeer`), where OLD's `clearPendingRequests` existed but was never called — faster recovery after reconnect. | SAFE (timing/bandwidth) | OLD `GossipEngine.kt:81,367-376,474` (`PENDING_REQUEST_TIMEOUT = 5.seconds`, key `channelId to streamId`, dead `clearPendingRequests`:341); NEW `sync/domain/services/PendingPullTracker.kt:58,81-123,140-142` (`DEFAULT 8s / MIN 2s / MAX 30s`, `Triple(peer, channel, stream)`), `Coordinator.kt:87`, `Peers.kt:17,27` |
| 7 | Out-of-order arrival → materializer full rebuild | **Not new** — full rebuild on `containsOutOfOrder` already existed on main (`foldForState` → `fullRebuild`). The delta: the trigger widened from `timestamp < previousTail` to `<=` (tie-inclusive), so entries tying the tail timestamp now force a rebuild too. Cost per trigger: `getAll` on the stream from Postgres + refold + cursor save — heavier on long streams (server streams are keep-all, so unbounded growth makes this grow over time). Partly offset: the contiguity guard reduces out-of-order incidence by refusing gapped merges. Externally visible only as DB read load / latency of materialized side effects. | SAFE (cost note) | OLD `entries/service/MaterializationService.kt` `foldForState`/`fullRebuild`; OLD trigger `GossipEngine.kt:303-304` (`<`); NEW trigger `GossipEngine.kt:431-434` (`<=`) with rationale comment |
| 8 | Config/API surface | Compile break — see section above (RISK, deploy-blocking). Post-fix, runtime config is compatible: `wireVersion` defaults V1 and is wired into both codecs (`Coordinator.kt:179-180`); V2 emission (0xF2-marker frames) never happens; V2 **receive** capability is new but dormant (no peer emits it). New `require()` guards in `CoordinatorConfig` pass on defaults. | RISK (build) / DORMANT (runtime knobs) | `CoordinatorConfig.kt` diff; `shared/domain/values/WireTypes.kt:48,57-95`; `WireVersion.kt` |
| 9a | Payload bytes on the v1 wire: signed → unsigned ints | OLD emitted `entry.payload.map { it.toInt() }` → -128..127. NEW emits `and 0xFF` → 0..255. Deployed DART decodes with `Uint8List.fromList((json['payload'] as List).cast<int>())` — Uint8List truncates to the low 8 bits, so 0..255 round-trips exactly (as -128..127 already did). App→server unchanged (Dart always emitted 0..255); NEW decode widened to accept -128..255 (`decodePayloadByte`), covering any stale old-kt emission. Translator passes payload arrays through untouched (it only reshapes the envelope). | SAFE | OLD `messages/ProtocolCodec.kt` `encodeLogEntry`; NEW `SyncWireV1.kt:231,264-283`; DART `protocol/protocol_codec.dart:228,353` (@73f6a580); TR lines 119-141 |
| 9b | Empty DeltaResponse suppressed (no entries **and** no floor → no frame) | Invisible to deployed apps: OLD's empty response carried an empty `entries` **map**, which the translator fanned out to **zero** Dart messages — DART never saw empties anyway. On the rare advertised-but-gone race, the app's pending flag now expires by its fixed 5s timeout instead of clearing on an (unseen) empty reply — identical outcome. | SAFE | OLD `GossipEngine.kt:262-266` (unconditional send); NEW `GossipEngine.kt:309`; TR 119-141 (empty map → no output); DART `gossip_engine.dart:167-174` (5s expiry) |
| 9c | Contiguity guard on solicited responses: gapped entries dropped + `ChannelSyncError` per gap, instead of OLD's blind append | This is the deepest semantic change. OLD merged sequence-gapped entries, silently advancing the version vector past holes — a **permanent silent gap** (the missing range would never be re-requested). NEW refuses everything beyond the gap, reports once per gap position (to the unwired callback → invisible), and re-requests each round until the range is obtainable — trading silent corruption for a visible-in-traffic stall (repeating DeltaRequests). Live trigger today: essentially none — deployed apps **do not compact** (`coordinator_sync_service.dart:936`: `_compactionTimer.ensureRunning()` commented out pending the gossip fix) and DART serves solicited deltas from an uncompacted log, so no honest peer sends holes. Becomes load-bearing the day app-side compaction is re-enabled — at which point the unshipped floor translation (the wire-floor-translation PR) is what resolves the stall. | SAFE today; latent stall risk gated on app compaction | NEW `GossipEngine.kt:407-426,466-489,491-545`; OLD `GossipEngine.kt:296-311`; App main `coordinator_sync_service.dart:933-936`; unmerged PR branch `wire-floor-translation` |
| 9d | `adoptClaimedAuthorshipFloor`: peer digest claiming server-authored entries beyond the server's own mark → server adopts a sequence floor (WARN log) | Fires only after server-side history loss (DB reset/restore) while apps retain server-authored entries. OLD would re-allocate colliding sequences (new server entries invisible to every up-to-date peer — silent write loss); NEW skips past the claimed range. Requires `adoptVersionFloor` in PgEntryRepository (compile item). WARN goes to unwired `onLog` → invisible. | DORMANT (until a DB reset); improvement when it fires | NEW `GossipEngine.kt:594-668`; OLD `GossipEngine.kt:351-395` (no such check) |
| 9e | PingReq: domain drops `originalRequester`; v1 emission synthesizes it from `sender`; relay ack now returns to `sender` | Wire shape unchanged (4 keys in V1). Semantics equivalent on this mesh: OLD kt always emitted `originalRequester = localNode = sender` (`FailureDetector.kt:489-492` @5255d74), and the deployed translator writes `originalRequester = sender` for app-originated PingReqs (TR line 87) and strips it inbound (line 146). No peer ever sends a differing value. | SAFE | NEW `membership/infrastructure/MembershipMessageCodec.kt:111-126,148-153`; FailureDetector diff (ack → `pingReq.sender`); TR 85-89,144-148 |
| 9f | Duplicate re-deliveries no longer re-fire `EntriesMerged` | OLD invoked `onEntriesMerged` with entries the repo had silently skipped as duplicates → duplicate `EntriesMerged` domain events → redundant `SideEffectProcessor.processEntry` calls (idempotent via ProcessedEventStore, but wasted work). NEW filters first; only genuinely new entries reach the event. Fewer duplicate side-effect invocations — externally a small DB-load reduction. | SAFE | OLD `GossipEngine.kt:300-311`; NEW `GossipEngine.kt:407-437`; server `CoordinatorLifecycle.kt:55-64` |
| 9g | Codec split (membership/sync) + `WireTypes.classifyFrame` | Type bytes 0-6 and all v1 JSON field names byte-for-byte preserved (digests identical; ping/ack identical). Unknown leading bytes: OLD → decode null, silent; NEW → `Malformed` with diagnostic detail → unwired callback. Net observable: nothing. | SAFE | OLD `ProtocolCodec.kt` whole file vs NEW `SyncWireV1.kt` + `MembershipMessageCodec.kt`; `WireTypes.kt:57-95` |

Also checked and found **no** behavior delta: `performGossipRound` peer selection/congestion gating
(identical incl. constants — `PER_PEER_CONGESTION_THRESHOLD = 3`, gossip interval clamps 100ms-5s),
`buildLocalDigests`, `FailureDetector` probe logic (diff is imports + codec type + the 9e ack
change), `EntriesMerged`/`EntryAppended` event shapes, `MessagePort`/`IncomingMessage` interface
members (package move only), HLC clock, SWIM timings. `MaterializationService` gained per-state
mutexes + ConcurrentHashMap (internal race hardening, not externally visible) and a documented
known-limitation note (rebuild decision not persisted — pre-existing, mirrored from Dart).

## Bottom line

**Deployable today: NO — as specified, the deploy fails at build time.** The structure mirror
renamed every package opendoor-api imports and grew the `EntryRepository` interface by two members
(`getCompactionFloor`, `adoptVersionFloor`) that `PgEntryRepository` doesn't implement, so a
submodule bump with "server code unchanged" cannot produce an artifact; nothing reaches the mesh.
Conditions to make it deployable: (1) mechanical import-path update across ~17 main files + the two
integration tests; (2) implement the two floor methods in `PgEntryRepository` with real persistence
(a floors table or column — the engine reads them on live paths, so a stub returning EMPTY is only
acceptable while nothing compacts, and silently defeats 9c/9d the day something does). With those
done, the wire remains v1-compatible with the deployed old-translator fleet in both directions
(verified against the translator and the pinned Dart codec at 73f6a580, including the payload
sign change and the single-entry envelopes); floor emission, v2, and all compaction paths are
genuinely dormant (server never compacts, no auto-compaction exists, deployed apps have compaction
disabled); and the remaining live differences are frame granularity, adaptive pull timing, and the
strict ingestion/contiguity guards — which convert OLD's silent-corruption failure modes into
refuse-and-retry modes. One strong recommendation attaches: the server passes **neither `onError`
nor `onLog`** to `Coordinator.create`, so every new diagnostic this branch added (decode errors,
contiguity-gap stalls, authorship-floor warnings, ingestion refusals) is currently invisible — wire
both callbacks to slf4j in the same PR as the import fix, or the first real stall (9c) will present
as "sync silently stopped for one author" with an empty log.
