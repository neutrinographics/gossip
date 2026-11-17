# Dart Digest Scoping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port digest scoping (roadmap item 10) to `packages/gossip` so a Dart request digests only the channels the peer has shown it holds and announces the rest under a byte budget, a response answers what was named, and the wire matches gossip-kt PR #20 byte for byte.

**Architecture:** Two pure domain services (`DigestScoping`, `DigestAnswering`) and one value (`PeerHoldings`) carry the rules; `DigestBudgeter` is rebuilt on the Kotlin model — sizes measured through the `MessageCodec` seam, every over-budget list rotated per peer by least-recently-sent item, an announce budget filled after the digests; `GossipEngine` orchestrates: learn holdings first, drop unheld channels at debug, scope, fit, send. No wire change: an announcement is a channel digest with an empty stream list, read back as an announcement.

**Tech Stack:** Dart 3 (`packages/gossip`, pure Dart, `dart test`), Melos monorepo. gossip-kt receives one vendored conformance vector.

**Spec:** `docs/superpowers/specs/2026-09-30-digest-scoping-rulings.md` (approved 2026-09-30). The Kotlin reference is gossip-kt `d902a61` (PR #20): `sync/domain/values/PeerHoldings.kt`, `sync/domain/services/DigestScoping.kt`, `DigestAnswering.kt`, `sync/application/DigestBudgeter.kt`, `DigestWindow.kt`, `DigestRotation.kt`, `PeerRotation.kt`, `Recency.kt`, `RotationKey.kt`, `GossipEngine.kt` (`handleDigestRequest`, `handleDigestResponse`, `heldAmong`, `requestFor`, `clearPendingRequests`, `clearPendingRequestsForPeer`), `SyncWireCommon.kt`. The worklist is the register rows under "Digest scoping" in `docs/backlog/kt-normalize-twin-divergences.md`.

## Design decisions for the Dart half (the short design, approved in the thread 2026-11-17)

Everything the rulings decide is taken as written. What the rulings leave to the Dart half:

- **Full port, one PR.** Scoping, answering, holdings, the announce budget, *and* the two budgeter flow-backs the register records (identity-based per-peer recency rotation; sizing through the codec seam, the 40-byte constant dropped) land together, as PR #20 did on Kotlin. Alternatives considered: scoping only with the positional cursors kept (leaves the twins' budgeters different machines and three register rows open); also extracting a Dart `PullPlanner` (the register calls that a separate low flow-back — out).
- **No state cell.** Dart is single-isolate (ADR-001); `PeerHoldings` and `DigestRotation` are plain fields on the engine and the budgeter, moved only by their pure transitions. Recorded on `docs/parity.md` as exemption E5, shaped like E4.
- **Same names.** `announced`, `namedChannels`, `PeerHoldings.of/learn/forget`, `DigestScoping.scope`, `DigestAnswering.answer`, `announceBudgetBytes`, `DigestWindow.select`, `Recency`, `RotationKey`, `PeerRotation`, `DigestRotation`; Dart keeps `digests` (not kt's `channelDigests`) per the register's naming row.
- **Response gathering adopts kt's**: our whole digest for every named held channel, streams answered in our digest's order (the register's "Where the response-scoping rule lives" row).
- **`handleDigestRequest(request)`** loses its `channels` parameter: the engine looks held channels up itself, because answering needs whole digests and debug-drops the rest.
- **Canonical announcement vector** authored here (`digestrequest-announced` in `v1-dart/` and `v2/`), vendored to gossip-kt's `v2/` in a second, tiny PR.
- **Out of scope:** the OpenDoorApp pin bump (follow-up in the normal course), `clearForChannel` wiring (its own register row), keyed-hash announcements, recency suppression.

## Global Constraints

- Boundary rule: a context imports `shared/` and itself only — `test/architecture/boundary_test.dart` must stay green after every task.
- No silent errors: every drop is logged (`debug` for an unheld named channel, `trace` for the planner-side backstop, `warning` for an unannounceable channel); oversized digests still reach `onError` as `protocolError`.
- Wire: no new key, no marker bump. An announcement renders as `{"channelId": <id>, "streams": []}` after the digests, in both dialects; byte-identical to kt's `SyncWireDialectsTest` expectation `{"sender":"n","digests":[{"channelId":"ch-1","streams":[{"streamId":"st-1","version":{"a":3}}]},{"channelId":"ch-2","streams":[]},{"channelId":"ch-3","streams":[]}]}`.
- Announce budget: default `1024`, `>= 0` required, `0` never announces; clamped to the room the digests left; not spent when the digests fill the message.
- Dart test names translate the kt ones and cite the kt file (parity convention 3), as kt's tests cite Dart's.
- Run from `packages/gossip/`: `dart test <file>`; `dart analyze`; `dart format lib test`. Commit after each task on branch `claude/project-thread-bwqg0s`.

## Review Focus

1. **A request from a peer on today's Dart (every channel digested, none announced) must fill holdings with all of them** so the next request back is already scoped — pinned in Task 10 ("an old-shape request fills holdings").
2. **A genuinely stream-less channel we hold, received as an announcement, must be answered with its empty digest and not erased by fitting** — pinned in Task 4 (answering) and Task 7 ("an empty channel digest survives the over-budget path").
3. **Two peers alternating against one hub must each be offered every announcement**, not the same half forever — pinned in Task 7 ("each peer has its own announce rotation").
4. **A channel created after first contact must be announced on the very next request, with no restart** — pinned in Task 9 and the join scenario in Task 11.
5. **Removing a peer and re-adding it must start its holdings and rotation over**, so a reconnected peer is announced everything again — pinned in Task 10.

---

### Task 1: `PeerHoldings` value

**Files:**
- Create: `lib/src/sync/domain/value_objects/peer_holdings.dart`
- Test: `test/sync/domain/value_objects/peer_holdings_test.dart`

**Interfaces:**
- Produces: `@immutable class PeerHoldings { final Map<NodeId, Set<ChannelId>> byPeer; static const PeerHoldings initial; Set<ChannelId> of(NodeId peer); PeerHoldings learn(NodeId peer, Iterable<ChannelId> named); PeerHoldings forget(NodeId peer); ==, hashCode, toString }`. `byPeer` and every set in it are unmodifiable views.

- [ ] **Step 1: Write the failing tests** — translate the seven cases of kt `PeerHoldingsTest.kt` one to one, citing it in the file header:
  - a peer that has shown nothing holds nothing (`initial.of(peer)` is empty)
  - learning a name adds it and keeps what was learned before
  - learning an empty list changes nothing and creates no entry (`== initial`, `byPeer` has no key)
  - a name learned once is never removed by a later message that omits it
  - forgetting a peer removes only that peer
  - forgetting an unknown peer is the same value (`==`)
  - every transition answers a new value and leaves its input untouched (snapshot `byPeer` before, call `learn` and `forget`, compare)
- [ ] **Step 2: Run** `dart test test/sync/domain/value_objects/peer_holdings_test.dart` — FAIL (file not found).
- [ ] **Step 3: Implement** the class per the Interfaces block; `learn` with an empty `named` returns `this`; `forget` of an unknown peer returns `this`. Doc comment: the spec's "Holdings" paragraph (only a name is evidence; holdings only grow; cleared with the peer; never persisted; sync's, not membership's).
- [ ] **Step 4: Run** the test — PASS. Run `dart test test/architecture/boundary_test.dart` — PASS.
- [ ] **Step 5: Commit** `feat(sync): PeerHoldings — what each peer has shown it holds, moved by pure transitions`.

---

### Task 2: Announcements on `DigestRequest`; `namedChannels` on both digest messages

**Files:**
- Modify: `lib/src/sync/domain/messages/digest_request.dart`
- Modify: `lib/src/sync/domain/messages/digest_response.dart`
- Test: `test/sync/domain/messages/digest_request_test.dart` (create)

**Interfaces:**
- Produces: `DigestRequest({required NodeId sender, required List<ChannelDigest> digests, List<ChannelId> announced = const []})`; `Set<ChannelId> get namedChannels` on `DigestRequest` (digested ∪ announced) and on `DigestResponse` (digested only).

- [ ] **Step 1: Write the failing tests** — translate kt `DigestRequestTest.kt`: a request names its digested and its announced channels alike; a request announces nothing unless told to; a response names only what it digests.
- [ ] **Step 2: Run** `dart test test/sync/domain/messages/digest_request_test.dart` — FAIL (no `announced`).
- [ ] **Step 3: Implement** the field and the two getters. Doc on `announced`: "Channels we hold and the peer has not shown it holds: named, not digested — *if you hold this too, show me your digest.*" Doc on `DigestResponse.namedChannels`: "a response answers, it never announces".
- [ ] **Step 4: Run** the test — PASS. Run `dart test` — PASS (the default keeps every existing constructor call valid, including OpenDoorApp's translator test later).
- [ ] **Step 5: Commit** `feat(sync): a DigestRequest announces the channels it does not digest; both digest messages name their channels`.

---

### Task 3: `DigestScoping` (domain service)

**Files:**
- Create: `lib/src/sync/domain/services/digest_scoping.dart`
- Test: `test/sync/domain/services/digest_scoping_test.dart`

**Interfaces:**
- Produces: `@immutable class ScopedDigests { final List<ChannelDigest> digests; final List<ChannelId> announced; const ScopedDigests({required this.digests, required this.announced}); }` and `abstract final class DigestScoping { static ScopedDigests scope(List<ChannelDigest> ours, Set<ChannelId> shown); }` — both in `digest_scoping.dart` (the result type is the service's own tiny value, as kt nests `Scoped`).

- [ ] **Step 1: Write the failing tests** — translate kt `DigestScopingTest.kt`'s five cases: shown → digest / not shown → announcement; a peer that has shown nothing is announced everything; a shown channel we no longer hold is neither; order is ours within each list; a digest with no streams for a shown channel is still a digest here.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** `scope` as a single partition of `ours` by `shown`, order preserved. Doc: the spec's `DigestScoping` paragraph (pure; knows no byte; fitting is the budgeter's).
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(sync): DigestScoping — a digest for each channel the peer has shown, an announcement for the rest`.

---

### Task 4: `DigestAnswering` (domain service)

**Files:**
- Create: `lib/src/sync/domain/services/digest_answering.dart`
- Test: `test/sync/domain/services/digest_answering_test.dart`

**Interfaces:**
- Produces: `abstract final class DigestAnswering { static List<ChannelDigest> answer(DigestRequest request, List<ChannelDigest> ours); }`.

- [ ] **Step 1: Write the failing tests** — translate kt `DigestAnsweringTest.kt`'s nine cases: an announced channel we hold is answered with our whole digest; an announced channel with no streams is answered with its empty digest; a digested channel is answered with the named streams we hold only; a named stream we do not hold is skipped; omits streams the requester already dominates, and the channel when none survives (this one originates in Dart's `gossip_engine_digest_filter_test.dart` — say so); a channel both announced and digested is answered as digested, once; a channel of ours the request did not name never appears; a named channel we did not gather is skipped; order is the request's — digested first, then announced — and within a channel our digest's order.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** `answer` with kt's algorithm (index `ours` by channel; walk `request.digests`, keep each of our streams that is named and not dominated by the requester's vector, emit the channel only when something survives; then each `announced` not already answered, whole). Doc: the spec's `DigestAnswering` paragraph.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(sync): DigestAnswering — answer what the request named and nothing else`.

---

### Task 5: Codec — announcement ↔ empty stream list, and the canonical vector

**Files:**
- Modify: `lib/src/sync/infrastructure/sync_message_codec.dart` (`_encodeChannelDigests` call sites for the request at ~98, request decode at ~235, `_decodeChannelDigests` at ~324)
- Modify: `test/sync/infrastructure/sync_message_codec_test.dart`
- Modify: `test/wire_vectors/wire_vectors_test.dart` (vector tables at ~151 and ~220, the v1-dart/v2 file lists)
- Create (generated): `test/wire_vectors/v1-dart/digestrequest-announced.frame`, `test/wire_vectors/v2/digestrequest-announced.frame`; regenerate both `checksums.txt`.
- Docs: `test/wire_vectors/README.md` (one line per set naming the new vector and what it pins).

**Interfaces:**
- Consumes: Task 2's `announced`.
- Produces: `encode(DigestRequest)` renders `announced` as `{"channelId": id, "streams": []}` entries appended after the digests inside the existing `digests` array; `decode` of a request partitions entries with an empty `streams` list into `announced` (wherever they sit), of a response leaves them as digests with no streams.

- [ ] **Step 1: Write the failing codec tests** in `sync_message_codec_test.dart`, a new group `announcements`, translating kt `SyncWireDialectsTest.kt`'s two cases: (a) the exact JSON above after the type byte for v1 (`bytes.sublist(1)`) and after `[0xF2][type]` for v2 (`bytes.sublist(2)`); (b) for every encoder × decoder version pair, a request with one digest and `announced: [ch-2]` round-trips equal, and a response with `ChannelDigest(ch-2, [])` round-trips equal ("a response never announces"). Also: a request whose empty-stream entry sits *before* a digested one still decodes it as announced (decoder rule, not position).
- [ ] **Step 2: Run** `dart test test/sync/infrastructure/sync_message_codec_test.dart --name announcements` — FAIL.
- [ ] **Step 3: Implement**: a private `_encodeRequestChannels(List<ChannelDigest>, List<ChannelId>)` and `_decodeRequestChannels(List<dynamic>) → ({List<ChannelDigest> digests, List<ChannelId> announced})` on the facade (Dart's helpers live on the facade; the register already records the layout difference from kt's `SyncWireCommon`). The response paths are unchanged.
- [ ] **Step 4: Run** the codec test file — PASS.
- [ ] **Step 5: Add the vector.** In `wire_vectors_test.dart` add `'digestrequest-announced': DigestRequest(sender: nodeA, digests: digestsFixture(), announced: [ChannelId('channel-announced-1'), ChannelId('channel-announced-2')])` to both the v1-dart and v2 tables and file lists; set `regenerate = true`; run `dart test test/wire_vectors/wire_vectors_test.dart` (fails by design); inspect both new `.frame` files against spec §7.2/§7.3 and the JSON above; set `regenerate = false`; run again — PASS. Update the README per the file's own instructions.
- [ ] **Step 6: Run** `dart test` — PASS.
- [ ] **Step 7: Commit** `feat(sync): an announcement rides the wire as a channel digest with no streams; canonical digestrequest-announced vector`.

---

### Task 6: The budgeter's mechanism — `RotationKey`, `Recency`, `PeerRotation`, `DigestRotation`, `DigestWindow`

**Files:**
- Create: `lib/src/sync/application/rotation_key.dart`, `recency.dart`, `peer_rotation.dart`, `digest_rotation.dart`, `digest_window.dart`
- Test: `test/sync/application/digest_window_test.dart`, `test/sync/application/recency_test.dart`

**Interfaces:**
- Produces:
  - `@immutable class RotationKey { final ChannelId channel; final StreamId? stream; const RotationKey(this.channel, [this.stream]); ==, hashCode }`
  - `@immutable class Recency { final Map<RotationKey, int> lastSent; final int next; static const initial; int? sentAt(RotationKey key); Recency stamp(Iterable<RotationKey> keys); }` — each stamped key takes `next`, `next+1`, … in order.
  - `@immutable class PeerRotation { final Recency request, response, announce; const PeerRotation({request = Recency.initial, …}); PeerRotation copyWith({…}); }`
  - `@immutable class DigestRotation { final Map<NodeId, PeerRotation> byPeer; static const initial; PeerRotation of(NodeId); DigestRotation with_(NodeId, PeerRotation) — name it `withPeer`; DigestRotation forget(NodeId); }`
  - `class Window<T> { final List<T> selected; final List<T> oversized; final int usedBytes; }` and `abstract final class DigestWindow { static Window<T> select<T>({required List<T> items, required List<int> costs, required List<RotationKey> keys, required Recency recency, required int budget}); }` — order by `recency.sentAt(key) ?? -1` ascending, ties by list index; the longest prefix whose costs fit, charging one separator byte for every selected item after the first; stop at the first item that does not fit the room left; an item whose bare cost exceeds `budget` is skipped and reported, never selected. Throws `ArgumentError` when the three lists differ in length.

- [ ] **Step 1: Write the failing tests** — `digest_window_test.dart` translates kt `DigestWindowTest.kt`'s twelve cases (everything fits — never-sent in list order; a previously sent item goes after the never-sent ones; among sent items the one sent longest ago goes first; a window that does not fit stops at the first item over the room left; stopping does not look past it for a smaller item; successive windows stamped by their selection cover every item; an item alone over the budget is skipped and reported; no items; a zero budget selects nothing and reports every item; an item whose cost equals the budget is selected alone; two items that each fill the budget select one and stop; the window charges one separator between the items it selects — `usedBytes` is the sum plus `selected.length - 1`). `recency_test.dart`: `stamp` assigns consecutive sequences in order and leaves the input untouched; `sentAt` of an unstamped key is null; `DigestRotation.forget` removes only that peer and `of` an unknown peer is `PeerRotation()`.
- [ ] **Step 2: Run** both files — FAIL.
- [ ] **Step 3: Implement** the five files. Doc comments carry kt's "why" (identity not position; per peer; never pruned to the current list; the window owns the separators).
- [ ] **Step 4: Run** — PASS; `dart test test/architecture/boundary_test.dart` — PASS.
- [ ] **Step 5: Commit** `feat(sync): the budgeter's mechanism — a window over sized items, rotated per peer by least-recently-sent item`.

---

### Task 7: `DigestBudgeter` rebuilt on the codec seam with an announce budget

**Files:**
- Modify: `lib/src/sync/application/digest_budgeter.dart` (rewrite; `OversizedDigest` stays in this file)
- Modify: `lib/src/sync/infrastructure/sync_message_codec.dart` — delete `encodedStreamDigestSize` (its only callers were the budgeter and its tests)
- Modify: `test/sync/application/digest_budgeter_test.dart` (rewrite), `test/sync/infrastructure/sync_message_codec_test.dart` (delete the `encodedStreamDigestSize` test at ~1118)

**Interfaces:**
- Consumes: Task 3's `ScopedDigests`; Task 6's mechanism; `MessageCodec.encode`.
- Produces:
  - `DigestBudgeter({required MessageCodec codec, required NodeId localNode, required int maxMessageBytes, required int announceBudgetBytes})` with public `final int maxMessageBytes, announceBudgetBytes`.
  - `FittedRequest fitRequest(ScopedDigests scoped, NodeId peer)` → `class FittedRequest { List<ChannelDigest> digests; List<ChannelId> announced; List<OversizedDigest> oversized; List<ChannelId> unannounceable; }`
  - `FittedResponse fitResponse(List<ChannelDigest> digests, NodeId peer)` → `class FittedResponse { List<ChannelDigest> digests; List<OversizedDigest> oversized; }`
  - `void forget(NodeId peer)`; `void reset()`.
  - Cost model (kt's, exactly): `base = encode(DigestRequest(sender: localNode, digests: [])).length`; a stream item costs `encode(request with that one stream in its channel).length - base`; an empty channel digest is an item of its own costing `encode(request with ChannelDigest(ch, [])).length - base`; an announcement costs `encode(DigestRequest(digests: [], announced: [id])).length - base`. Whole-fit fast path on the request side only (sends whole, stamps nothing, `bytes = whole - base`). Announce budget `= min(announceBudgetBytes, maxMessageBytes - base - digestBytes) - (digests selected ? 1 : 0)`; `<= 0` or no announcements → none; if the cheapest announcement exceeds the budget → none, nothing reported, nothing stamped; `unannounceable` = oversized announcements whose cost `> announceBudgetBytes`. Only stream items are reported oversized.

- [ ] **Step 1: Rewrite the failing tests** — translate kt `DigestBudgeterTest.kt`'s 25 cases (names listed in the kt file; keep Dart's existing five where they coincide, under the new signatures): fits-whole passes through and moves no rotation; over-budget request rotates and wraps; a request stamps only the request list and a response only the response list; per-peer request rotation; per-peer response rotation; alternating response lists each answered in full; a request list that loses and regains items still offers every unoffered item; announcements shown between windows are not skipped past; alone-over-budget stream skipped and reported, rest go; fitted request/response always encode within `maxMessageBytes` (encode the resulting `DigestRequest`/`DigestResponse` through the same codec and assert `<=`); announcements under budget all go in order and are all stamped; over budget rotate with no repeat before the cycle completes; per-peer announce rotation; one peer's requests do not touch another's announce rotation; budget zero never announces, reports nothing, moves nothing; not spent when digests fill the message; an announcement alone over the announce budget is skipped and reported; a positive budget below every cost announces nothing round after round; a budget above the room is clamped; exact-fit stream never reported oversized; exact-fit window encodes to exactly `maxMessageBytes`; exact-fit announcement announced not reported; an announcement after selected digests is charged the separator; an empty channel digest survives the over-budget path. Use `SyncMessageCodec(wireVersion: WireVersion.v2)` as the seam and 36-character ids where kt does.
- [ ] **Step 2: Run** `dart test test/sync/application/digest_budgeter_test.dart` — FAIL (signatures).
- [ ] **Step 3: Implement** the rewrite per the Interfaces block, with `DigestRotation _rotation = DigestRotation.initial` as a plain field (no cell — ADR-001). Delete `encodedStreamDigestSize` and its test. `dart analyze` must report no unused members.
- [ ] **Step 4: Run** the budgeter test and `dart analyze` — PASS / clean. (`gossip_engine*` tests break here on the budgeter's constructor; Task 9 restores them — do not run the full suite yet.)
- [ ] **Step 5: Commit** `feat(sync): DigestBudgeter sizes through the codec seam, rotates per peer by recency, and fills an announce budget after the digests`.

---

### Task 8: `announceBudgetBytes` in `CoordinatorConfig`

**Files:**
- Modify: `lib/src/coordinator/coordinator_config.dart` (field beside `maxMessageBytes`, default `1024`)
- Modify: `lib/src/coordinator/coordinator.dart:331` (pass `announceBudgetBytes: cfg.announceBudgetBytes` to the engine — compiles only after Task 9; land the config here, the wiring line in Task 9)
- Test: `test/coordinator/coordinator_config_test.dart` (add to the existing file, or create)

**Interfaces:**
- Produces: `final int announceBudgetBytes;` default `1024`; the constructor `assert(announceBudgetBytes >= 0, 'announceBudgetBytes must not be negative')` (CoordinatorConfig is `const`-constructible; an `assert` is the validation style a const constructor allows — if the file validates elsewhere today, follow that).

- [ ] **Step 1: Write the failing tests**: the default is `1024`; `-1` is rejected (`throwsA(isA<AssertionError>())`); `0` is accepted.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** with kt's doc text: bytes a request may spend announcing channels the peer has not shown; 0 never announces; default 1 KB, about fifteen ids; clamped to the room the message budget leaves; a budget below one announcement's cost (~66 bytes for a 36-character id) never announces, silently.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(coordinator): announceBudgetBytes — the bytes a request may spend naming channels the peer has not shown`.

---

### Task 9: Engine send side — scope, fit, announce

**Files:**
- Modify: `lib/src/sync/application/gossip_engine.dart` (`_digestBudgeter` construction ~388; `_buildDigestRequest` ~779; `syncWithPeer` ~814; the round's send ~721; `_logOutgoingMessage` ~1076; constructor gains `int announceBudgetBytes = defaultAnnounceBudgetBytes`)
- Modify: `lib/src/coordinator/coordinator.dart:331` (the wiring line from Task 8)
- Modify: `test/sync/application/gossip_engine_test_harness.dart` (optional `int? announceBudgetBytes` on both `create` paths)
- Modify: `test/sync/application/gossip_engine_digest_budget_test.dart` (the request-side cases now go through `ScopedDigests` with every channel shown — pre-learn holdings by delivering a response naming the channels, or assert on announcements instead; keep every behaviour they pin)
- Test: `test/sync/application/gossip_engine_scoping_test.dart` (create)

**Interfaces:**
- Consumes: Tasks 1, 3, 7, 8.
- Produces: `static const int defaultAnnounceBudgetBytes = 1024;` `PeerHoldings _holdings = PeerHoldings.initial;` `Future<DigestRequest> _buildDigestRequest(NodeId peer)` = gather `generateDigest` for every channel → `DigestScoping.scope(all, _holdings.of(peer))` → `_digestBudgeter.fitRequest(scoped, peer)` → report oversized via `onError`, report each unannounceable with `_log(LogLevel.warning, 'cannot announce <id>: its name alone exceeds announceBudgetBytes=<n>')` → `DigestRequest(sender, digests, announced)`. The budgeter is built with `codec: _codec` (the seam, no cast). SEND trace line reads `… ${digests.length} channels + ${announced.length} announced ($size bytes)`.

- [ ] **Step 1: Write the failing tests** in `gossip_engine_scoping_test.dart`, translating the send-side cases of kt `GossipEngineTest.kt`: a request to a peer that has shown nothing announces every channel and digests none; once a peer has shown a channel (deliver a `DigestResponse` from it naming the channel — holdings are learned in Task 10, so this case stays red until then; mark it `skip:` with the reason and unskip in Task 10), the next request digests it and announces the rest; a round's request is scoped the same way as `syncWithPeer`'s; a hub over the announce budget names every channel to a peer across successive requests (40 channels of 36-character ids, default budget — collect the union of `announced` over rounds, expect all 40, and no round repeats a channel before the cycle completes); an announce budget of zero sends digests only; a channel whose name alone exceeds the budget is warned about (budget 50, assert a `warning:` line in `h.logs`). Read the request the engine sent off the harness's bus/peer port and decode it with the harness codec.
- [ ] **Step 2: Run** `dart test test/sync/application/gossip_engine_scoping_test.dart` — FAIL.
- [ ] **Step 3: Implement** per the Interfaces block; thread `announceBudgetBytes` through the harness and the coordinator.
- [ ] **Step 4: Run** the scoping test, the digest-budget test and `dart test` — PASS except the one skipped case.
- [ ] **Step 5: Commit** `feat(sync): a request digests the channels the peer has shown and announces the rest under the announce budget`.

---

### Task 10: Engine receive side — learn, drop unheld at debug, answer, forget

**Files:**
- Modify: `lib/src/sync/application/gossip_engine.dart` (`_onDigestRequest` ~925, `_sharedDigests` ~963 (delete), `_onDigestResponse`, `_handleDigestRequest` ~1114 (delete), `handleDigestRequest` ~1179 (new signature), `handleDigestResponse`, `_computeDeltaRequests` ~1296 (the `protocolError` → trace backstop), `stop()` ~534, `clearPendingRequestsForPeer` ~1714, the RECV trace line)
- Modify: `test/sync/application/gossip_engine_test.dart:320` (the unknown-channel case becomes "a response naming a channel we do not hold is dropped at debug, not an error")
- Modify: `test/sync/application/gossip_engine_digest_filter_test.dart` (call `handleDigestRequest(request)`; cases stay)
- Modify: `test/sync/application/gossip_engine_scoping_test.dart` (unskip; add the receive-side cases)

**Interfaces:**
- Produces:
  - `Future<DigestResponse> handleDigestRequest(DigestRequest request)` — learns `request.namedChannels` into `_holdings` first; `_heldAmong(sender, named)` returns the held `ChannelAggregate`s in named order and logs `debug` `'dropping <id> named by <peer8>: not a channel of ours'` for each other; gathers `generateDigest` for each held; `DigestAnswering.answer(request, ours)`; `fitResponse(answer, sender)`; oversized → `onError`.
  - `_onDigestRequest` reciprocates from `request.digests.where(held)` only (announcements pull nothing); `_sharedDigests` is gone.
  - `Future<List<PullRequest>> handleDigestResponse(DigestResponse response)` — learns first, then pulls for the held digests; the unknown-channel branch in `_computeDeltaRequests` becomes the `trace` backstop (`'ignoring digest for unknown channel <id> from <peer8>'`), no `onError`.
  - `stop()` adds `_holdings = PeerHoldings.initial; _digestBudgeter.reset();` `clearPendingRequestsForPeer(peer)` adds `_holdings = _holdings.forget(peer); _digestBudgeter.forget(peer);`.
  - RECV trace: `'RECV DigestRequest from <peer8>: N channels + M announced'`.

- [ ] **Step 1: Write the failing tests** (translate kt `GossipEngineTest.kt`'s receive-side cases): a request's names teach the sender's holdings before anything else (deliver a request naming an unheld channel; the next request to that sender digests nothing and announces… assert via the *following* request that the held one is digested); a response's names teach holdings too; an announced channel we hold is answered with our whole digest; an announced channel we hold with no streams is still answered, empty, when the answer has to be fitted (tiny `maxMessageBytes`); a digested channel is answered scoped to the named streams and dominance-filtered; a named channel we do not hold is dropped at debug, appears nowhere in the response, and is not an error (`h.errors` empty, a `debug:` line in `h.logs`); the reciprocal pull is planned from the request's held digests only — an announcement pulls nothing; a response naming a channel we do not hold is dropped at debug while the held ones are still pulled; an old-shape request (every channel digested, none announced) fills holdings with all of them; removing a peer (`clearPendingRequestsForPeer`) forgets its holdings so the next request announces again, and forgets its rotation so announcements start over; a stop forgets every peer's holdings and resets the rotation. Rewrite `gossip_engine_test.dart:320` as the debug-drop pin.
- [ ] **Step 2: Run** the three files — FAIL.
- [ ] **Step 3: Implement** per the Interfaces block.
- [ ] **Step 4: Run** `dart test` — PASS; `dart analyze` clean; `dart format lib test`.
- [ ] **Step 5: Commit** `feat(sync): every name teaches holdings; a named channel we do not hold is dropped at debug; holdings are cleared with the peer`.

---

### Task 11: Scenario pins — the join, a hub over budget, the mixed fleet

**Files:**
- Create: `test/integration/sync/digest_scoping_test.dart`
- Modify: `test/support/test_network.dart` only if `TestNetwork.create` cannot already take a `CoordinatorConfig` (it can: `config:`).

- [ ] **Step 0 (before Task 1 is merged — run once on `main`, do not commit):** the rulings' mixed-fleet pin "an announcement to a responder on today's code produces no answer and no error". Write a throwaway test on `main` that delivers, through `InMemoryMessagePort`, a hand-built v2 frame carrying `{"channelId":"<held>","streams":[]}` to today's engine with a channel of that id; assert the response carries no digests and `errors` is empty. Record the command and its PASS in the PR body under *Mixed fleet*. (After this branch the same bytes are answered, which is the point; the pin cannot live in the suite.)
- [ ] **Step 1: Write the two scenarios**, translating kt `integration/DigestScopingTest.kt` onto `TestNetwork` (`createChannel`/`createStream`/`write`/`runRounds`/`hasConverged`, errors via `coordinator_builder`'s `onError` or the node's recorded errors):
  - a channel created on one side after first contact is shared within a round of the other side creating it — phone and server share `user-1`; phone creates `group-9` and writes; three rounds later the server has no `group-9` channel; the server creates it; `hasConverged(group-9)` within a few rounds; no errors.
  - a hub with more channels than the announce budget still converges every shared channel — 40 hub-only channels with 36-character ids plus one shared; both write to the shared one; converged; no errors.
- [ ] **Step 2: Run** `dart test test/integration/sync/digest_scoping_test.dart` — PASS (these are pins on the whole; a failure is a Task 9/10 defect, fix there).
- [ ] **Step 3: Run** the mixed-membership suites that exist today: `dart test test/integration/sync/topology_sync_test.dart test/integration/sync/churn_sync_test.dart test/sync/application/gossip_engine_channel_scope_test.dart` — PASS.
- [ ] **Step 4: Commit** `test(sync): the join and a hub over the announce budget converge under scoped digests`.

---

### Task 12: Docs truth pass, register, roadmap, PR

**Files:**
- Modify: `docs/backlog/kt-normalize-twin-divergences.md` — rows *Unknown-channel digests* (close: "Closed (2026-11-xx): Dart drops at debug, gossip PR #…"), *Digest scoping — the whole feature* (close), *Where the response-scoping rule lives* (close), *Rotation of over-budget lists* (close), *How the budgeter measures bytes* (close; record what the separator check found), *Unannounceable announcements* (close), *The budgeter's mechanism* (note Dart extracted `DigestWindow` and declined the cell → parity E5).
- Modify: `docs/parity.md` — add row E5: Dart keeps `PeerHoldings` and `DigestRotation` as plain fields where kt holds them in `SynchronizedState` cells; ADR-001; not a flow-back.
- Modify: `docs/roadmap.md` item 10 — Dart half merged (PR, commit, test count), next = app pin bump + production meeting read; `docs/backlog/engine-scope-digests-to-shared-groups.md` status likewise.
- Modify: root `CLAUDE.md` core-package key components — one line: `PeerHoldings` / `DigestScoping` / `DigestAnswering` / `DigestBudgeter` and what each owns.
- Sweep: `grep -rn "carries ALL the sender's channels\|non-shared channel\|_channelEnvelopeOverheadBytes\|encodedStreamDigestSize\|two independent cursors" lib test docs` — every hit rewritten or confirmed true.

- [ ] **Step 1: Sweep prose** with the grep above; no retired claim survives.
- [ ] **Step 2: Full gate**: `melos run analyze` and `melos run test` from the repo root — PASS; record the gossip package's test count.
- [ ] **Step 3: Byte table**: in a throwaway test (not committed), encode the request a 41-channel node sends a peer that has shown one channel, before (main) and after; record both sizes in the PR body with the kt figure (4386 → ~1000 bytes).
- [ ] **Step 4: Commit** `docs: Dart digest scoping — register rows closed, parity E5, roadmap item 10`.
- [ ] **Step 5: Push and open the PR** from `claude/project-thread-bwqg0s` in `neutrinographics/gossip` with the required attribution header, the rulings link, the byte table, the mixed-fleet note from Task 11 step 0, the test count, and the hand-off: OpenDoorApp pin bump; gossip-kt vendoring PR (Task 13). Assign and request review from da1nerd; subscribe to PR activity.

---

### Task 13: gossip-kt — vendor the announcement vector

**Files (repo `gossip-kt`, branch `claude/project-thread-bwqg0s`):**
- Copy: `packages/gossip/test/wire_vectors/v2/digestrequest-announced.frame` → `src/test/resources/wire/v2/digestrequest-announced.frame`
- Modify: `src/test/resources/wire/v2/checksums.txt` (add the sha256 line, sorted by filename — verify against the Dart manifest's line, byte for byte)
- Modify: `src/test/kotlin/com/neutrinographics/gossip/wire/WireVectorConformanceTest.kt` — add `"digestrequest-announced" to DigestRequest(sender = nodeA, channelDigests = digests(), announced = listOf(ChannelId("channel-announced-1"), ChannelId("channel-announced-2")))` to `v2Vectors`, a `v2 digestrequest-announced decodes and re-encodes byte-exact` test via `assertV2RoundTrip`, and the file in whatever list the checksum test walks.

- [ ] **Step 1: Copy the frame and add the test** — run `./gradlew :test --tests '*WireVectorConformanceTest*'` — FAIL (manifest mismatch) until the checksum line is added.
- [ ] **Step 2: Add the checksum line**; run again — PASS. Run `./gradlew :test --tests '*architecture*'` — PASS.
- [ ] **Step 3: Commit** `test(wire): vendor the canonical digestrequest-announced vector from gossip <commit>`; push; open the PR with the attribution header, linking the gossip PR; assign and request review; subscribe.

---

## Self-review

- **Spec coverage:** ruling 1 → Tasks 3, 7, 9; ruling 2 → Tasks 4, 7, 10; ruling 3 → Task 10 (learn first, debug, no error; `gossip_engine_test.dart:320` rewritten); ruling 4 → Task 10 (stop and peer removal; the stale-name limit exercised by Task 3's "shown but no longer held"); ruling 5 → Task 8 (default, bounds) and Task 7 ("not spent when digests fill the message", clamp); ruling 6 → Task 5 (both dialects, response never split, canonical vector) and Task 13 (vendored); ruling 7 → this is the Dart half; the pin bump is the hand-off. Placement table → every piece in the layer named (value objects, messages, services in domain; budgeter and mechanism in application; codec in infrastructure; budget value in config). Pins: value (1), scoping (3), answering (4), budgeting (6–7), engine (9–10), the join (11), mixed fleet (10's old-shape request + 11 step 0), wire (5), parity (citations in every test file; register closed in 12).
- **Step scan:** every code step names a signature and a file; test steps name the cases; no "handle edge cases".
- **Type consistency:** `ScopedDigests(digests, announced)`; `FittedRequest(digests, announced, oversized, unannounceable)`; `FittedResponse(digests, oversized)`; `DigestWindow.select({items, costs, keys, recency, budget}) → Window(selected, oversized, usedBytes)`; `DigestRotation.of/withPeer/forget`; `PeerHoldings.of/learn/forget`; `handleDigestRequest(request)`; `announceBudgetBytes` on config, engine, budgeter, harness — used with the same names throughout.
- **Review Focus:** each of the five lines has its test in the task named.
- **Proportion:** the plan cites kt's tests by name instead of transcribing them; bodies appear only for the cost model and the window rule, which the signatures do not determine.
