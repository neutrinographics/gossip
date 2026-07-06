# Correctness Audit — `gossip` core + `gossip_bluey`

**Date:** 2026-07-06
**Scope:** `packages/gossip` (core protocol) and `packages/gossip_bluey` (BLE transport), ~12.6k LOC.
**Focus:** correctness and bugs only — logic errors, async race conditions, protocol edge cases, resource leaks, silent error swallowing. Not style, not architecture.
**Method:** four parallel deep-read audits (gossip engine + codec, SWIM failure detector, coordinator/HLC/storage, gossip_bluey), followed by independent verification of every HIGH finding against source.

**Verification status:** all 12 HIGH findings traced and confirmed directly in source. Medium findings are auditor-reported; several spot-verified (TOCTOU dedup, entry-order tiebreak, event-clear grep, `onEntriesMerged`).

> **REMEDIATION COMPLETE (2026-07-06).** All findings fixed via TDD across
> ten workstreams — commits `2c1f6a9` (WS-A–E, core protocol) and
> `c368a31` (WS-F–J, coordinator/materialization/gossip_bluey). Every HIGH,
> MEDIUM, and LOW item was addressed; L21 (`discoverPeers` serviceUuid) was
> documented rather than changed (deprecated API, bluey filters by its own
> control service). Notable contract changes: duplicate `EntryRepository`
> appends now throw; wire payloads are base64 (old int-list still decodes);
> max entry payload ≈22KB derived from `CoordinatorConfig.maxDeltaResponseBytes`;
> `ConnectionManager.connectTo` throws typed `AlreadyConnectingException`.
> Suites after remediation: gossip 814, gossip_nearby 173, gossip_bluey 151.

---

## Summary

| Severity | Count | Themes |
|----------|-------|--------|
| HIGH | 12 | Sync livelock, scheduler forking, permanent peer limbo, silent data loss, BLE traffic black hole |
| MEDIUM | ~15 | TOCTOU races across `await`, subscription/error-handling gaps, lifecycle races |
| LOW | ~15 | Codec robustness, observability gaps, dead code, minor leaks |

### Cross-cutting patterns

1. **Fire-and-forget schedulers without generation tokens** — the stop/start loop-forking bug exists identically in `GossipEngine` and `FailureDetector`.
2. **Check-then-act across `await`** — appendEntry sequencing, pending-delta dedup, soft connection cap, coordinator start. Single-isolate execution does not prevent interleaving at await points.
3. **The project's own no-silent-errors rule is violated in the worst places** — the BLE write drop (H9), append duplicate drop (H5), remote-stream skip, subscriptions without `onError`.
4. **Bookkeeping keyed by NodeId without connection identity** — root cause of bluey H9–H12 and several mediums. A per-connection generation/handle ID would fix the whole class.

---

## 🔴 HIGH

### Core protocol (`packages/gossip`)

#### H1. Oversized deltas → permanent sync livelock

- `lib/src/protocol/gossip_engine.dart:719-732` (`handleDeltaRequest`), `:617-623` (`computeDelta`)
- `lib/src/protocol/protocol_codec.dart:228` (payload encoded as JSON int list), `:49-51` (codec disclaims size enforcement)

`handleDeltaRequest` returns **all** entries from `entriesSince()` in a single `DeltaResponse` — no entry cap, no byte budget, no pagination. The codec encodes each payload byte as a JSON integer (~3.6 chars/byte, plus ~52 B/entry overhead).

**Failure:** a fresh peer joins a stream holding 100 × 1 KB entries → responder builds one ~370 KB wire message — 11× the 32 KB Nearby limit the design targets. Even a *single* entry at the documented 32 KB app-payload limit encodes to ~117 KB. The transport send fails, the requester's pending flag expires after 5 s, the identical request is re-sent, and the identical failure repeats **forever**. Permanent sync livelock for any stream whose delta exceeds the transport limit.

#### H2. `stop()` → `start()` forks the scheduler loop — in both engines

- `lib/src/protocol/gossip_engine.dart:281-307, 550-568`
- `lib/src/protocol/failure_detector.dart:237-247, 497-518` (identical pattern)
- Reachable via `Coordinator.pause()`/`resume()` (`lib/src/facade/coordinator.dart:847-889`)

`stop()` only flips `_isRunning = false`; the already-scheduled `timePort.delay(...).then((_) { if (_isRunning) _round(); })` callback stays in flight. After a restart it sees `_isRunning == true`, runs, and reschedules — now two independent round chains run forever. Every pause/resume cycle within one interval adds another chain, multiplying gossip and probe traffic. Directly undermines BLE-pressure timing tuning.

**Fix direction:** generation counter checked in the callback, or a cancellable timer token.

#### H3. Peer reachable only via indirect probes is stuck `suspected` forever

- `lib/src/protocol/failure_detector.dart:521-538` (`_evaluateProbeOutcome`) vs `:376-386` (`_probeUnreachablePeer`)

Forwarded indirect Acks carry the **intermediary** as sender, so `handleAck` (`:434-435`) updates the intermediary's contact, not the target's. `_probeUnreachablePeer` compensates with an explicit `_recordPeerContact(peer.id, ...)` (`:384` — the comment admits the problem), but the regular round path `_evaluateProbeOutcome` does **not** — on indirect success it just returns.

**Failure (the exact BLE-mesh case this library targets):** A and B drift out of direct radio range but both reach C. B fails 3 direct probes → `suspected`. Every subsequent round: direct ping times out, indirect ack via C succeeds → no failure recorded, but no recovery either. B stays `suspected` forever — excluded from gossip peer selection (`reachablePeers` only), never transitioned to unreachable, never recovered, despite being provably alive every round.

#### H4. Aggregate `uncommittedEvents` never cleared → duplicate event emission + unbounded memory growth

- `lib/src/domain/aggregates/channel_aggregate.dart:53, 116-121`
- `lib/src/domain/aggregates/peer_registry.dart:41, 145-149`
- `lib/src/application/services/channel_service.dart:130, 285`

Neither aggregate has any clear/commit API (grep-verified across lib/ and test/), yet `ChannelService._withChannel` emits the **entire** `uncommittedEvents` list after every operation, and `CachingChannelRepository` (wired unconditionally, `coordinator.dart:256`) returns the same aggregate instance.

**Failure (a):** `createChannel` emits `[ChannelCreated]`; `addMember(p1)` emits `[ChannelCreated, MemberAdded(p1)]`; `addMember(p2)` emits all three plus the new one. Apps treating events as facts double-apply.
**Failure (b):** `PeerRegistry.recordMessageReceived` appends a `PeerOperationSkipped` event for **every message from an unknown/removed peer** (`peer_registry.dart:305-313`) — twice per message, since both `FailureDetector` (`failure_detector.dart:612`) and `GossipEngine` (`gossip_engine.dart:402`) subscribe to the same incoming stream. Remove a peer while its transport still delivers → unbounded growth until OOM on a long-running node.

#### H5. Concurrent `appendEntry` calls silently lose entries

- `lib/src/application/services/channel_service.dart:331-351`
- `lib/src/infrastructure/stores/in_memory_entry_repository.dart:57-61`

Multiple awaits (`hasStream`, `latestSequence`, `saveClockState`) sit between reading the latest sequence and calling `append`. Two interleaved appends both read seq = N and both build entries with seq = N+1. `InMemoryEntryRepository.append` detects the duplicate `(author, sequence)` and **returns silently** — no error, no ErrorCallback (violates the no-silent-errors rule).

**Failure:** `unawaited(stream.append(a)); await stream.append(b);` — one payload vanishes permanently; peers never see it.

#### H6. Compaction regresses the version vector and latest-sequence → entry resurrection and sequence reuse

- `lib/src/infrastructure/stores/in_memory_entry_repository.dart:171-183, 224-240`
- `lib/src/facade/event_stream.dart:194-236`

`removeEntries` rebuilds `_latestSequenceCache` from surviving entries only, so `getVersionVector` and `latestSequence` regress after pruning.

**Failure (a) — resurrection:** node A compacts with `TimeBasedRetention`; its VV regresses below what peer B holds; A's next digest advertises the lower VV; B's delta re-sends pruned entries; A re-inserts them (append dedup only blocks entries A *still has*). Compaction is undone every gossip round.
**Failure (b) — sequence reuse:** if ALL of the local author's entries in a stream are pruned (easy with time-based retention on an idle stream), `latestSequence` returns 0 and the next `appendEntry` re-issues seq 1. Peers whose VV already covers seq 1 never request it (`entriesSince` filters `sequence > authorSeq`); peers still holding the old seq-1 silently drop the new one via append dedup. New data **permanently invisible** to those peers.

#### H7. `start()`/`stop()` interleave leaves engines running while state says stopped

- `lib/src/facade/coordinator.dart:789-809` (esp. `:795` vs `:798-808`)

`start()` transitions to `running` (`:795`), **then** awaits `_loadChannels()` before starting the engines.

**Failure:** `unawaited(coordinator.start()); await coordinator.stop();` — `stop()` sees `running`, stops engines that never started, sets `stopped`; `start()` resumes and calls `startListening()` + `start()` on both engines. Result: state = stopped (or disposed) but gossip timers and message subscriptions are live; after dispose, engine errors are silently dropped (events controller closed). Permanent background activity.

#### H8. `removeMember` never emits `MemberRemoved` despite documented contract

- `lib/src/domain/aggregates/channel_aggregate.dart:149-154`

`_memberIds.remove(peerId)` result is discarded; no `_addEvent(MemberRemoved(...))` exists (contrast `addMember` at `:133-138`). Apps listening to `coordinator.events` never learn about removals — instead receiving the H4 replay of old events. Dartdoc and CLAUDE.md both claim the event is emitted.

### BLE transport (`packages/gossip_bluey`)

#### H9. Mesh simultaneous mutual connect → permanent silent bidirectional black hole

- `lib/src/application/services/connection_manager.dart:123-130`
- `lib/src/infrastructure/adapters/bluey_port_impl.dart:695-707` (`disconnectRole`, peripheral branch), `:304-315` (`writeRequests` handler)

There is **no pre-connect NodeId tie-break in this package** (scan candidates carry only `BleAddress`; NodeId is unknown until after connect). Duplicate resolution is per-side first-write-wins in `ConnectionRegistry.tryRegister` — nothing makes the two sides agree.

**Failure:** mesh mode; A and B discover each other and both call `connectAndIdentify` concurrently. On each side its own outgoing central connect registers first; the peer's inbound connection then surfaces as `PortPeerConnected(peer, peripheral)` → `DuplicateRejected` → `port.disconnectRole(peer, peripheral)`. The peripheral branch of `disconnectRole` (bluey has no per-client disconnect) only drops local bookkeeping — critically removing the `_clientAddressToNodeId` entry (`:698`) — **without severing the physical link**. Now A sends on its central link → GATT write lands on B's server → `writeRequests` finds no address→NodeId mapping → **silently drops** (`:310-314`; the "gossip will resync" comment is false — the mapping is only repopulated by a new `peerConnections` event, which never fires while the link stays up). Symmetric on B. Both registries report a live connection; 100% of gossip traffic in both directions is discarded forever.

#### H10. Stale disconnect events tear down the wrong (new) connection after fast reconnect — both roles

- Central: `bluey_port_impl.dart:443, 479-489` — `_registerCentralConnection` blindly overwrites `_centralConnections[target]`, `_centralNotifSubs[target]`, `_centralStateSubs[target]`; overwritten subscriptions are never cancelled (leak, still live); the state-change guard checks only `containsKey(target)`, not connection identity. Old link drops; before its `disconnected` event delivers, auto-connect re-establishes → old leaked sub fires → `_cleanupCentral(X)` destroys the **new** connection's bookkeeping and unregisters the live link.
- Peripheral: `bluey_port_impl.dart:286-301` — the `disconnections` handler resolves the *old* clientAddress to a NodeId, then removes `_peripheralClients[nodeId]` / `_writePayloadByNode[nodeId]` — the **new** client after a fast reconnect with a new address. Registry unregisters the live connection; subsequent writes hit a null decoder and vanish.

**Fix direction:** compare stored connection/client identity against the event's before cleanup.

#### H11. maxConnections cap rejection disconnects the wrong link

- `connection_manager.dart:105-115` + `bluey_port_impl.dart:526-534`

The cap check runs **before** the duplicate check and calls role-blind `port.disconnect(nodeId)`, which prefers the central role. At cap with X registered as central, a duplicate inbound peripheral event for X tears down the **active central link**; the unregistered duplicate peripheral link stays physically up (→ H9 black-hole state). Should be `port.disconnectRole(nodeId, role)`, with duplicate check before cap check. Sub-issue: a genuinely new peripheral-role peer rejected at cap keeps a live GATT link whose writes are silently dropped; it never learns it was rejected.

#### H12. `_registerCentralConnection` has no rollback on failure — leaked live connection

- `bluey_port_impl.dart:432-498`

`_centralConnections[target]` is set at `:443`; if subsequent awaits throw (`services()` fails on mid-discovery disconnect; missing gossip service/characteristic → StateError at `:466/:474`), the method throws with the entry stranded in the map — no state-change subscription installed, no `PortPeerConnected` emitted, physical link not disconnected. Never cleaned; a later `sendData(nodeId)` operates on a dead handle.

---

## 🟠 MEDIUM

### Core protocol

- **M1. TOCTOU defeats `_pendingDeltaRequests` dedup** — `gossip_engine.dart:676-705`: pending-check (`:679-687`) and pending-set (`:696`) are separated by `await _computeVersionVector` (`:689`); queued `DigestResponse` events interleave, both pass the check, duplicate `DeltaRequest`s are sent — the exact "sync loop bug" the map's doc comment says it prevents. Fix: set the flag before the await.
- **M2. Duplicate/stale `DeltaResponse`s surface duplicate `EntriesMerged` events; engine's idempotency assumption contradicts the `EntryRepository` contract** — `gossip_engine.dart:746-777`: `onEntriesMerged` fires unconditionally with `response.entries` even when `appendAll` skipped all duplicates → duplicated UI messages, false `containsOutOfOrderEntries`. Also `entry_repository.dart:66-85` says `append` *throws* on duplicates and `appendAll` is all-or-nothing — a spec-compliant SQLite impl would reject whole overlapping batches, dropping genuinely-new entries.
- **M3. Entry ordering ignores the documented author tiebreak → divergent state across peers** — `in_memory_entry_repository.dart:79-92`: `_findInsertIndex` compares timestamp only; HLC ties order by arrival. `LogEntry.compareTo` defines timestamp→author→sequence and `event_stream.dart:66-72` promises convergent order. Non-commutative materializers converge to different states on different peers.
- **M4. Every incoming message double-counted in peer metrics** — both engines call `recordMessageReceived` for every message on the shared `messagePort.incoming` stream (`gossip_engine.dart:401-407`, `failure_detector.dart:585-618`). All window/lifetime counts are 2×; malformed messages emit two `messageCorrupted` errors.
- **M5. Message subscriptions have no `onError`** — `failure_detector.dart:250-252`, `gossip_engine.dart:323`: a transport stream error becomes an uncaught zone error and cancels the subscription — SWIM/gossip message handling permanently dead, nothing emitted via ErrorCallback.
- **M6. Scheduler `timePort.delay(...).then` has no error handler** — `failure_detector.dart:497-502` (same shape in gossip engine): one delay error permanently kills the probe/gossip loop while `isRunning` still reports true.
- **M7. `FailureDetector.startListening` doesn't cancel the prior subscription** — `failure_detector.dart:250-252` (contrast `gossip_engine.dart:321-323`). Reachable via `pause()` → `start()`: two live subscriptions, every Ping answered twice, first subscription leaks past `stopListening`.
- **M8. Channels created/removed while paused never reach the GossipEngine after `resume()`** — `coordinator.dart:433-436, 472-475, 872-888`: `setChannels` is only called when state == running; `resume()` doesn't reload channels.
- **M9. `_handleEntriesMerged` adds to the events controller after awaits without rechecking `isClosed`** — `coordinator.dart:378-403`: checked at `:378`, two awaits, unconditional `add` at `:394` → StateError on dispose-during-merge. Every other emit site rechecks.
- **M10. `MaterializationService._initialize` is not reentrancy-guarded** — `materialization_service.dart:44-53, 138-141, 162-211`: a concurrent `getState()` + append can run two initializations; the first to *finish last* overwrites cached state/cursor with pre-append values and emits stale state; `save()` persists the stale state last.
- **M11. `Coordinator.dispose()` never disposes materializer state** — `coordinator.dart:896-922`: `MaterializationService.disposeAll()` exists but is only reachable via `removeChannel`; broadcast StreamControllers leak, listeners never get onDone.
- **M12. `getResourceUsage`/`channelsForPeer` iterate live map keys across awaits** — `coordinator.dart:498-509, 643-670`: `createChannel`/`removeChannel` completing between awaits → `ConcurrentModificationError`.
- **M13. `handleAck` matches pending pings by sequence only** — `failure_detector.dart:437-443`: no sender/target validation for direct pings; after a detector rebuild, stale queued Acks with colliding sequences mark the wrong peer alive and pollute its RTT estimate.
- **M14. PeerService persistence can write out of logical order** — `peer_service.dart:145-148, 197-212`: overlapping mutators on the same peer can persist an older snapshot after a newer one; surfaces on restart. Also `FailureDetector` mutates `peerRegistry` directly, bypassing `PeerService` — its status/contact changes are never persisted at all.

### BLE transport

- **M15. Send-queue removal on disconnect + no per-chunk registry check → frame interleaving / wrong-link disconnect after fast reconnect** — `connection_manager.dart:155-162, 213-263`: an in-flight `_sendChunked` checks the registry only at loop entry; after disconnect + fast auto-reconnect it can write the old frame's remaining chunks to the new link (decoder corruption on the receiver) or, on chunk failure, `port.disconnect` tears down the freshly re-established connection.
- **M16. `unawaited(port.disconnect/disconnectRole(...))` → unhandled async errors when adapter is off** — `connection_manager.dart:114, 129, 260`: these throw `BluetoothUnavailableException` via `_requireAdapterEnabled`; `unawaited` attaches no error handler → unhandled zone errors.
- **M17. DiscoveryService permanently wedged after adapter cycle** — `discovery_service.dart:25, 58-63`: no `onDone` on the scan subscription; after adapter off/on, `startDiscovery()` silently no-ops (`_sub != null`), `isRunning` lies, stale `currentCandidates` persist.
- **M18. AutoConnectPolicy `on StateError` conflates all StateErrors with the reentrancy guard** — `auto_connect_policy.dart:147-154`: `connectAndIdentify`'s "no scan-emitted device" StateError and `_registerCentralConnection`'s missing-service StateErrors are classified benign → **no backoff recorded** → hot retry storm on every advertisement (compounds with M17's stale candidates); real failures reduced to debug logs.
- **M19. Overlapping scan restart corrupts scan-state bookkeeping** — `bluey_port_impl.dart:601-611, 644-660`: `stopScan`'s post-await cleanup nulls the *new* scan's `_scanStateSub` (leaked, never cancellable) and force-sets scan state to `stopped` while scanning. Trigger: `stopDiscovery()` quickly followed by `startDiscovery()`.
- **M20. `targetConnections` soft cap raced by concurrent connect attempts** — `auto_connect_policy.dart:128-135`: cap checked before `await connectTo`; a scan burst of N candidates all pass before any completes → overshoot. (Hard cap is enforced synchronously in the event handler — safe.)
- **M21. iOS MAC rotation → double-connect to the same NodeId unregisters the surviving link** — `connection_manager.dart:85-95` (reentrancy guard is per-address only) + `bluey_port_impl.dart:443` (blind overwrite): two candidates for one peer, both connect; duplicate resolution disconnects the second and the resulting role-matched `PortPeerDisconnected` unregisters the entry for the first, still-live connection — orphaned.

---

## 🟡 LOW

### Core protocol

- **L1.** `Hlc.subtract` throws when result < 0; uncaught in `TimeBasedRetention` (`hlc.dart:120`, `retention_policy.dart:67-70`) — `compact()` throws instead of retaining everything when clock < maxAge.
- **L2.** `ChannelService.currentTimestamp` getter advances the HLC as a side effect without persisting clock state (`channel_service.dart:432-433`; used by `event_stream.dart:201`).
- **L3.** `MaterializationService.register` fires `dispose()` of the replaced state unawaited with no error handler (`materialization_service.dart:37`).
- **L4.** `EventStream.compact` returns `CompactionResult` with `oldBaseVersion`/`newBaseVersion` hardcoded to empty `VersionVector({})` (`event_stream.dart:221-222`) — fabricated data.
- **L5.** Fire-and-forget `saveClockState` with no error handling (`gossip_engine.dart:801-802`) — unhandled async zone error on storage failure; contrast `channel_service.dart:341` which awaits.
- **L6.** Pending-delta bookkeeping: flag set before the DeltaRequest is transmitted (send failure blocks re-request for the full 5 s); pending key `(channelId, streamId)` has no peer identity, so any peer's response clears a request addressed to another peer (`gossip_engine.dart:696, 748`).
- **L7.** Codec silently truncates out-of-range payload bytes mod 256 instead of rejecting (`protocol_codec.dart:353`) — `payload: [300, -1]` decodes "successfully" to `[44, 255]`.
- **L8.** Remotely-created streams silently skipped forever — `gossip_engine.dart:674`: `if (!channel.hasStream(...)) continue;` with no log/error; peer B's stream-S data never reaches A with zero observability.
- **L9.** Dead duplicate digest classes in `domain/results/digest.dart` (`:33, :56`) shadowing the protocol/values ones, with broken hashCode contracts (map identity hash vs deep `==`) — import-ambiguity trap.
- **L10.** `_probingHeldUntil` entries never removed on peer removal/expiry (`failure_detector.dart:151`); unbounded under churn.
- **L11.** `startListening()` double-call leaks the previous subscription (`failure_detector.dart:250-252`) — needs misuse to trigger (see M7 for the reachable path).
- **L12.** Indirect-ack RTT is a 2-hop measurement attributed to the target (`failure_detector.dart:686-698, :555`) — target's EWMA/adaptive timeout systematically inflated.
- **L13.** Per-peer RTT samples aren't clamped, unlike the global tracker (`peer_metrics.dart:59-75` vs RttTracker's [50 ms, 30 s]); first sample sets SRTT directly.
- **L14.** Pending-ping map entries can leak if an exception escapes between track and cleanup — no try/finally (`failure_detector.dart:286-300`).

### BLE transport

- **L15.** Frame-decoder false-magic recovery discards all 4 length bytes and rescans — a real magic beginning inside those bytes destroys the following valid frame (`frame_codec.dart:152-160`). Correct recovery: rescan from 1 byte past the false magic.
- **L16.** Decoder accepts length-0 frames and emits an empty message to the gossip layer (`frame_codec.dart:152, 169-181`); encoder rejects empty payloads so len == 0 only arises from corruption. (`len < 0` check is dead — `getUint32` is unsigned.)
- **L17.** `connectTo` resolves before registration is observable (`connection_manager.dart:91` + async broadcast dispatch) — immediate `send(nodeId, ...)` after a successful connect gets `ConnectionNotFoundError`.
- **L18.** `unawaited(server.respondToWrite(...))` error unhandled (`bluey_port_impl.dart:317-324`).
- **L19.** `PortConnectFailed` is never emitted anywhere and its handler is a silent `break` (`connection_manager.dart:187-189`); `metrics.recordConnectionFailed` is never invoked from any path.
- **L20.** `ConnectionManager.dispose` doesn't clear `_decoders`; an in-flight `_sendChunked` failing after dispose adds to the closed `_errors` controller → StateError (`connection_manager.dart:292-299`).
- **L21.** `discoverPeers` ignores its `serviceUuid` parameter (`bluey_port_impl.dart:390-403`) — deprecated path returns all bluey peers.

---

## Checked and found OK (selected)

- **HLC:** `HlcClock.now()`/`receive()` monotonicity correct in all branches (counter overflow → physical+1, physical clock backwards, `restore()` semantics); `Hlc` invariants, `compareTo`, `parse/tryParse` sound; 48-bit physical / 16-bit logical safe under JS 2^53.
- **VersionVector:** unknown-node → 0, `dominates`/`diff` edge cases, order-independent hashCode — all correct. (Constructor stores caller's map by reference — latent hazard only for third-party repositories returning live maps.)
- **Codec malformed-input paths:** empty/truncated/wrong-typed messages all throw and are caught + emitted as `messageCorrupted` — not silent.
- **Gossip round error path:** `catchError` + `whenComplete` reschedule cannot kill a running chain (the fork bug H2 is stop/start-specific).
- **SWIM:** late/duplicate Ack guards, intermediary sequence isolation, no self-selection as intermediary, `Future.any` timeout branch always resolves.
- **Frame codec happy paths:** endianness consistent, partial frames across arbitrary chunk boundaries, multiple frames per chunk, 64 KB seek cap, chunking arithmetic — all correct.
- **Per-peer send queue:** tail-identity chaining correctly serializes concurrent sends to one peer (the M15 issue is disconnect/reconnect-specific).
- **Hard `maxConnections` admission:** synchronous within one event handler — no race (the H11 issue is *which* link gets disconnected, not admission).
- **`startAdvertising` rollback, `BlueyPortImpl.dispose` idempotency, facade dispose ordering** — sound.

---

## Suggested fix priority

1. **H1** delta size budget/pagination (sync livelock — core purpose of the library)
2. **H2** scheduler generation tokens in both engines (traffic multiplication, reachable via routine pause/resume)
3. **H9 + H11 + H10 + H12** bluey connection-identity rework (black hole + wrong-link teardowns share a root cause: NodeId-keyed bookkeeping without connection identity)
4. **H3** indirect-probe recovery (`_recordPeerContact` on target in `_evaluateProbeOutcome`)
5. **H4 + H8** aggregate event lifecycle (clear-on-emit; add `MemberRemoved`)
6. **H5 + H6** repository semantics (append race + compaction VV regression — needs a design decision on tombstones/floors for VV after pruning)
7. **H7** coordinator start/stop interleave (transition after engines start, or guard with an epoch)
