# Wire recon facts — v1 Dart / gossip-kt / v2 Dart / transports

Read-only recon to ground a wire-versioning design spec. All facts below are
sourced with `file:line` from:

- **v1 Dart** = `origin/main` @ `73f6a58` in this repo (verified:
  `git log origin/main -1 --format=%H` → `73f6a580dcc9bf510ea232a918cfa7705fffa364`).
- **v2 Dart** = `working-connection` (checked out) in this repo.
- **gossip-kt** = `feature/compaction` in `/Users/joel/git/neutrinographics/gossip-kt`.

---

## 1. v1 Dart codec (`origin/main:packages/gossip/lib/src/protocol/protocol_codec.dart`)

### 1a. Type-byte table

From `_typePing`..`_typeDeltaResponse` constants, `protocol_codec.dart:54-60`:

| Name | Byte |
|---|---|
| Ping | 0 |
| Ack | 1 |
| PingReq | 2 |
| DigestRequest | 3 |
| DigestResponse | 4 |
| DeltaRequest | 5 |
| DeltaResponse | 6 |

### 1b. Unknown first byte

`protocol_codec.dart:88-97` (`decode`): empty bytes → `throw ArgumentError('Cannot decode empty bytes')` (line 90). Any type byte not in the switch's cases → `default: throw ArgumentError('Unknown message type: $messageType')` (`protocol_codec.dart:250-251`). There is **no null return** anywhere in v1 — decode either succeeds or throws.

Call chain: both `GossipEngine` and `FailureDetector` independently subscribe to the *same* `messagePort.incoming` stream (`gossip_engine.dart:410` calls `_codec.decode`; `failure_detector.dart:589` calls `_codec.decode`), **each running its own single unified `ProtocolCodec()` instance** covering all 7 types (`failure_detector.dart:96`, `gossip_engine.dart:117`). Both wrap the decode call in `try/catch`:

- `GossipEngine._handleIncomingMessage` (`gossip_engine.dart:397-461`): catches, calls `_emitError(PeerSyncError(..., SyncErrorType.messageCorrupted, 'Malformed gossip message from $sender: $e', ...))` — non-fatal, single message dropped, loop continues (comment at `gossip_engine.dart:396-397`: "Malformed messages are silently ignored to prevent denial-of-service").
- `FailureDetector._handleIncomingMessage` (`failure_detector.dart:583-603`): same pattern, `_emitError(PeerSyncError(..., SyncErrorType.messageCorrupted, 'Malformed SWIM message from $sender: $e', ...))`.

Since v1 has one unified codec (no sibling-family split), and *both* engines run their own instance of the *same* codec on *every* inbound message, an unknown-type-byte frame throws in **both** places and is reported via `ErrorCallback` **twice** (once as "gossip message", once as "SWIM message") — never kills the receive loop, never silently drops without a trace.

### 1c. JSON decode tolerance

Every decoder reads named keys off a `Map<String, dynamic>` by key (`json['sender'] as String`, etc. — `protocol_codec.dart:257-353`); nothing iterates or validates the full key set. **Extra unknown keys (`"floor"`, `"hasMore"`) are silently ignored** — they're never looked up, so v1 tolerates additive fields for free.

`payload` as a base64 **string** instead of a JSON int array: `_decodeLogEntry` does `(json['payload'] as List).cast<int>()` (`protocol_codec.dart:353`). Casting a `String` to `List` throws a Dart `TypeError` ("type 'String' is not a subtype of type 'List<dynamic>'"), not `ArgumentError`. This propagates up through `_decodeLogEntry` → `_decodeLogEntries` → `_decodeDeltaResponse` → `_decodeMessageData` → `decode()`, uncaught inside the codec, and is caught by the **same** `try/catch` in `GossipEngine`/`FailureDetector` described above (they catch generic `Object`/`Exception` via bare `catch (e)`), so the net effect is identical to 1b: `PeerSyncError(messageCorrupted)` emitted, message dropped, loop survives.

### 1d. Message schemas (field names)

- `Ping`/`Ack`: `{sender, sequence}` (`protocol_codec.dart:136-142`)
- `PingReq`: `{sender, sequence, target}` (`:144-150`)
- `DigestRequest`/`DigestResponse`: `{sender, digests}`; each digest = `{channelId, streams}`; each stream digest = `{streamId, version}`; `version` = `{nodeIdString: seqInt}` (`:154-166`, `:188-214`)
- `DeltaRequest`: `{sender, channelId, streamId, since}` — `since` is a version-vector map (`:168-175`)
- `DeltaResponse`: `{sender, channelId, streamId, entries}` — `entries` = list of `{author, sequence, timestamp: {physicalMs, logical}, payload: [int,...]}` (`:177-184`, `:220-230`)

---

## 2. gossip-kt codec (`feature/compaction:.../messages/ProtocolCodec.kt`)

### 2a. Type-byte table

`ProtocolCodec.kt:328-334` (companion object constants):

| Name | Byte |
|---|---|
| TYPE_PING | 0 |
| TYPE_ACK | 1 |
| TYPE_PING_REQ | 2 |
| TYPE_DIGEST_REQUEST | 3 |
| TYPE_DIGEST_RESPONSE | 4 |
| TYPE_DELTA_REQUEST | 5 |
| TYPE_DELTA_RESPONSE | 6 |

Identical byte assignment to v1 Dart, confirmed independently by golden-style tests `ProtocolCodecTest.kt:277-317` (`assertEquals(0, bytes[0])` … `assertEquals(6, bytes[0])`).

### 2b. Unknown first byte

`ProtocolCodec.kt:61-72` (`decode`): empty data → `return null` (line 62). Everything else — bad type byte, malformed JSON, missing required key (via `!!` null-assertion NPE) — is caught by a blanket `try { ... } catch (_: Exception) { null }` (`:64-71`) and turned into a **null return**, never a thrown exception out of `decode`. Confirmed unknown-type-byte behavior at the dispatch `when`: `decodeMessageData`'s `else -> null` (`:232`), which is actually redundant with the outer catch but documents intent directly.

Call chain: `Coordinator.start()` (`Coordinator.kt:285-303`) is the **single** production call site of `codec.decode(msg.data)` (`Coordinator.kt:290`) inside `messagePort.incoming.collect { ... }`. If `decoded != null`, it's dispatched via `routeMessage` (`Coordinator.kt:292`, `356`); if null, nothing happens — no log, no `onError` call, completely silent. The *outer* `try/catch` around the whole block (`Coordinator.kt:293-301`) only fires if `codec.decode` itself throws, which it structurally cannot (its own try/catch swallows everything) — so that outer catch is effectively dead code for decode failures; it would only fire on an exception thrown by `routeMessage` itself. `FailureDetector.decodeMessage` (`FailureDetector.kt:332`) is a second `codec.decode` wrapper but is **only called from tests** (`FailureDetectorTest.kt:740,753,771,784`), not from production message routing.

### 2c. JSON decode tolerance

Same shape as v1 Dart's tolerance but via manual `JsonObject`/`jsonPrimitive` key reads (`json["sender"]!!.jsonPrimitive.content`, etc., e.g. `ProtocolCodec.kt:235-269`) — nothing iterates the object's key set, so extra unknown keys are ignored for free. `payload` as a base64 string instead of a JSON array: `decodeLogEntry` does `json["payload"]!!.jsonArray...` (`:323`); kotlinx.serialization's `.jsonArray` extension throws `IllegalArgumentException` if the element isn't a `JsonArray`. That exception is caught by `decode`'s blanket `catch (_: Exception)` (`:69`), so the **entire message decode returns null** — the whole `DeltaResponse` is dropped, not just the malformed entry.

### 2e. JSON mechanism / unknown-key stance

kotlinx.serialization's `Json` object is used only for **untyped tree parsing**: `Json.parseToJsonElement(jsonStr).jsonObject` (`:67`) plus manual `JsonPrimitive`/`JsonObject`/`JsonArray` extension reads. It never calls `Json.decodeFromString<T>()` against a `@Serializable` data class, so `Json { ignoreUnknownKeys = ... }` never enters the picture — unknown keys are tolerated **structurally**, by never being looked at, identically to v1/v2 Dart's manual-map-read style. (No `Json` config block exists anywhere in this file.)

### 2f. Decode failure mid-message

As in 2b: any exception during decode (bad type byte, corrupt JSON, missing key, wrong-shaped payload) is caught **inside** `ProtocolCodec.decode` and turned into `null`. The single production consumer, `Coordinator.start()`'s `collect` block (`Coordinator.kt:285-303`), sees `null` and does nothing — the receive loop (a `collect` coroutine over the incoming `Flow`) is never killed, and **no error is emitted or logged** for a malformed frame. This differs sharply from both Dart dialects, which always report via `ErrorCallback`.

---

## 3. v2 Dart codecs (`working-connection`)

### 3a. WireTypes table

`packages/gossip/lib/src/shared/domain/value_objects/wire_types.dart:5-19`:

| Name | Byte | Owner |
|---|---|---|
| ping | 0 | membership |
| ack | 1 | membership |
| pingReq | 2 | membership |
| digestRequest | 3 | sync |
| digestResponse | 4 | sync |
| deltaRequest | 5 | sync |
| deltaResponse | 6 | sync |

`known` = union of both families = `{0,1,2,3,4,5,6}` (`wire_types.dart:30`), machine-verified by `packages/gossip/test/shared/domain/value_objects/wire_types_test.dart:5-12` (partition has no overlap, covers exactly `{0..6}`).

### 3b. Byte-for-byte comparison, all three dialects

| Message | v1 Dart | v2 Dart (`WireTypes`) | gossip-kt |
|---|---|---|---|
| Ping | 0 | 0 | 0 |
| Ack | 1 | 1 | 1 |
| PingReq | 2 | 2 | 2 |
| DigestRequest | 3 | 3 | 3 |
| DigestResponse | 4 | 4 | 4 |
| DeltaRequest | 5 | 5 | 5 |
| DeltaResponse | 6 | 6 | 6 |

**All three dialects agree byte-for-byte on the type-byte table.** No message type exists in one dialect but not another — the set of 7 message types is identical across v1 Dart, v2 Dart, and gossip-kt.

### 3c. Unknown-byte contract

`sync_message_codec.dart:39-59` and `membership_message_codec.dart:30-49` (identical pattern, each context's own codec):

- Empty bytes → throw `ArgumentError('Cannot decode empty bytes')`.
- Type byte in **this codec's own family** (`WireTypes.sync` or `WireTypes.membership`) → decode normally.
- Type byte **not in this codec's family but in `WireTypes.known`** (i.e. belongs to the sibling context) → **return null** ("not mine", routine — the sibling codec on the other subscription will handle it).
- Type byte **not in `WireTypes.known` at all** → throw `ArgumentError('Unknown message type: $messageType')` — genuinely corrupt.

This is machine-documented in the shared interface `message_codec.dart:5-17` and mirrors v2's split-codec architecture: `Coordinator` wires `SyncMessageCodec()` into `GossipEngine` (`coordinator.dart:316`) and `MembershipMessageCodec()` into `FailureDetector` (`coordinator.dart:334`), and — same as v1 — **both engines subscribe independently to the full `messagePort.incoming` stream** (`gossip_engine.dart:590`, `failure_detector.dart:369`), each running its *own* codec on every inbound message. Consequence: a byte in the sibling's range decodes to `null` in one codec (silently ignored, per `failure_detector.dart:706-709`'s comment "Foreign-family frame ... not ours to handle. Routine traffic, not an error") while the other codec decodes it for real; a byte outside `known` entirely makes **both** codecs throw, so (same as v1) a truly-unknown byte is reported via `ErrorCallback` **twice** — once from `GossipEngine._handleIncomingMessage`'s catch (`gossip_engine.dart:817-843`), once from `FailureDetector._decodeIncomingMessage`'s catch (`failure_detector.dart:719-742`).

**This double-report-on-unknown-byte behavior is a direct constraint on any version-prefix design**: introducing a new leading byte that neither codec recognizes will fire two `PeerSyncError(messageCorrupted)` emissions per frame until both `WireTypes.known` (or equivalent) is taught about it.

### 3d. Field-name comparison v1 vs v2

Byte-identical schemas for `Ping`, `Ack`, `PingReq`, `DigestRequest`, `DigestResponse`, `DeltaRequest` (`sync_message_codec.dart:87-108` vs v1 `protocol_codec.dart:136-175` — same key names, same nesting). The only divergence is `DeltaResponse`:

- v1: `{sender, channelId, streamId, entries}` where each entry's `payload` is a JSON int array.
- v2: `{sender, channelId, streamId, entries, hasMore, [floor]}` (`sync_message_codec.dart:110-121`) — `hasMore` is always present; `floor` is emitted only when non-empty (comment at `:117-118`: "Omitted when empty ... legacy decoders ignore unknown keys"). Each entry's `payload` is now a **base64 string** (`sync_message_codec.dart:167`), not an int array.

No renames anywhere — purely additive fields (`hasMore`, `floor`) plus the payload encoding change. Decode side: `hasMore` absent → defaults to `false` (`:263`); `floor` absent → `VersionVector.empty` (`:265-267`), so v2 decoding a v1-shaped `DeltaResponse` (no `hasMore`/`floor`) works with sane defaults — confirmed by test `sync_message_codec_test.dart:309-322` ("a legacy DeltaResponse without hasMore decodes to false").

### 3e. Legacy-payload (JSON int array) decode coverage

`_decodePayload` (`sync_message_codec.dart:319-335`) accepts both a base64 `String` and a legacy `List<int>` (validating each byte is `0-255`, throwing `ArgumentError` otherwise — `:327-329`). This dual-format decode is used in **exactly one place**: `_decodeLogEntry`'s `payload` field (`:309`), which is reached only from `DeltaResponse.entries` (via `_decodeLogEntries` → `_decodeDeltaResponse`, `:255-268`). **No other message type carries raw payload bytes** — `DigestRequest`/`DigestResponse`/`DeltaRequest` never touch `_decodePayload`, so the legacy-format tolerance is DeltaResponse-entries-only, not a codec-wide affordance. Confirmed by test `sync_message_codec_test.dart:324-348` ("still decodes legacy int-list payloads").

---

## 4. Transport byte-space constraints (`working-connection`)

### 4a. `gossip_nearby` — `WireDispatcher` / `HandshakeCodec`

`gossip_nearby` wraps the **entire** core-codec-encoded frame (the `WireTypes`-byte + JSON bytes described above) inside its own outer envelope with a *separate* leading byte:

- `MessageType.handshake = 0x01`, `MessageType.gossip = 0x02` (`handshake_codec.dart:9,12`; `WireFormat.typeOffset = 0`, `handshake_codec.dart:18`).
- `WireDispatcher.classify(bytes)` reads exactly `bytes[WireFormat.typeOffset]` — i.e. `bytes[0]` of the **raw inbound wire frame** — and nothing else (`wire_dispatcher.dart:20-25`; the doc comment states it is "the ONLY place outside `HandshakeCodec` that may read the wire layout").
- `ConnectionService._onPayloadReceived` (`connection_service.dart:463-497`) switches on `classify()`'s result: `0x01` → handshake path, `0x02` → `_handleGossipMessage` (which unwraps via `HandshakeCodec.unwrapGossipMessage`, stripping exactly 1 byte — `handshake_codec.dart:149-153` — before the remainder reaches the core `MessagePort.incoming` stream and thus the `WireTypes` byte). Any **other** first byte (`0x00`, `0x03`-`0xFF`, including `0xF0`-`0xFF`) falls to `default: _log(LogLevel.warning, 'Unknown message type: $messageType from $id')` (`connection_service.dart:494-496`) — **logged only, not surfaced via `ErrorCallback`, and silently dropped** (no further processing).
- Because this outer byte is stripped before the payload reaches the core codec, the core `WireTypes` byte (0-6, or any future version-marker byte occupying that same first-byte position) is **never** compared against `0x01`/`0x02` — they live in different framing layers. A version marker placed at the *front of the inner gossip payload* (i.e., the byte position `WireTypes` currently occupies) does not collide with Nearby's outer envelope at all.

### 4b. `gossip_bluey` — `FrameEncoder` / `FrameDecoder` (`frame_codec.dart`)

Pure length-prefix framing: `[magic 4 bytes "GSP1" = 0x47,0x53,0x50,0x31][length u32 BE][payload]` (`frame_codec.dart:6-18`). `FrameDecoder.feed` (`:116-198`) only scans for the 4-byte magic and reads the length prefix; **it never inspects the payload's first byte or any byte inside the payload**. Decoded payloads are handed straight up: `ConnectionManager` emits `IncomingMessage(sender: nodeId, bytes: m, ...)` for each `m` in `decoder.feed(data).messages` (`connection_manager.dart:463-474`) with zero interpretation of `m[0]`. There's also a sibling GSP2 **control**-frame magic (`0x47,0x53,0x50,0x32`, `control_frame_codec.dart:13`) used for a distinct out-of-band rejection message, but it's a different 4-byte magic sequence at the *frame* level, not a reservation on the *payload's* first byte — a payload legitimately starting with byte `0x47` is unaffected. **Conclusion: bluey reserves nothing in the payload's byte-0 position; any value 0x00-0xFF is safe there.**

### 4c. Safe version-marker range

Collecting every value reserved at the **position a version-marker byte would occupy** (i.e., the front of what's handed to the core protocol codec — after Nearby's outer envelope is stripped, or as bluey's opaque payload's first byte):

- v1 Dart type bytes: `{0,1,2,3,4,5,6}`
- v2 Dart `WireTypes.known`: `{0,1,2,3,4,5,6}` (identical)
- gossip-kt type bytes: `{0,1,2,3,4,5,6}` (identical)
- gossip_nearby: reserves `0x01`/`0x02` only in its *outer* envelope layer, a position the version marker would not occupy (see 4a) — no additional exclusion at the core-codec byte-0 position.
- gossip_bluey: no reservation at all (see 4b).

**Safe range: `0x07`-`0xFF` (7-255)** — 249 unclaimed values — at the byte position `WireTypes` currently occupies, unclaimed by any of v1 Dart, v2 Dart, gossip-kt, or either transport's framing layer.

---

## 5. Existing golden/conformance tests

### v2 Dart — inline literal wire-pinning tests (no external fixture files)

- `packages/gossip/test/sync/infrastructure/sync_message_codec_test.dart` (611 lines): a dedicated `group('encode-side wire pinning', ...)` at line 405 pins, **by hand-copied literal** (not read from `WireTypes` or the codec itself — see the rationale comment at `:406-412`), the type byte + exact JSON key set for `DigestRequest` (byte 3, `:413-424`), `DigestResponse` (byte 4, `:426-436`), `DeltaRequest` (byte 5, `:438-451`), `DeltaResponse` (byte 6, `:453-462`), plus nested-payload goldens for digest/version-vector shape (from `:465` onward) and an `Hlc`+base64-payload golden for `DeltaResponse` entries (`:528-560`, asserting `entry['payload']` equals the literal string `'AQID'` — base64 of `[1,2,3]`). Legacy-compat tests: "a legacy DeltaResponse without hasMore decodes to false" (`:309-322`), "still decodes legacy int-list payloads" (`:324-348`), and a rejection test for out-of-range legacy payload bytes (`:376-401`, "out-of-range bytes are corruption, not data to mod-256"). All fixtures are **inline byte literals built in-test** via `Uint8List.fromList([typeByte, ...utf8.encode(jsonEncode(map))])` — no separate fixture files, no golden-file-on-disk pattern.
- `packages/gossip/test/membership/infrastructure/membership_message_codec_test.dart` (139 lines): same `group('encode-side wire pinning', ...)` pattern at line 48, pinning `Ping` (byte 0, `:57-65`), `Ack` (byte 1, `:66-74`), `PingReq` (byte 2, `:75-`).
- `packages/gossip/test/shared/domain/value_objects/wire_types_test.dart`: machine-checks the `WireTypes` partition itself (no overlap, exact `{0..6}` coverage) — not a wire-bytes golden per se, but the invariant the goldens above depend on.

No `test/**/golden/` or `test/**/fixtures/` directories or `.golden`/binary fixture files exist anywhere under `packages/gossip/test` — search for `golden`/`fixture` directory or filename patterns returned nothing; all "golden" behavior lives as inline literals inside `_test.dart` files as described above.

### gossip-kt — round-trip tests only, no cross-language goldens

`src/test/kotlin/com/neutrinographics/gossip/sync/ProtocolCodecTest.kt` exists and does pin type bytes via literal assertions (`assertEquals(0, bytes[0])` through `assertEquals(6, bytes[0])`, lines 277-317) and has explicit decode-failure tests (`decode returns null for unknown type byte` `:257-259`, `decode returns null for corrupted JSON` `:262-265`, `decode returns null for valid type but malformed payload` `:267-270`). However these are **all encode-then-decode round-trips or single-language byte-0 pins** — there is no fixture shared with or copied from the Dart codebase, no hard-coded JSON-string golden, and no test that decodes a literal byte sequence produced by the Dart codec (or vice versa). A `grep -rli "golden|fixture"` over `src/test` in gossip-kt returned no hits. **gossip-kt has zero cross-language conformance tests today.**

---

## 6. kt JSON payload cross-check — DeltaResponse with one entry

**v1 Dart** (`protocol_codec.dart:177-184`, `:220-230`) would emit, for a `DeltaResponse(sender: 'n1', channelId: 'ch1', streamId: 's1', entries: [LogEntry(author: 'n1', sequence: 1, timestamp: Hlc(1000, 0), payload: [1,2,3])])`:

```json
{
  "sender": "n1",
  "channelId": "ch1",
  "streamId": "s1",
  "entries": [
    {
      "author": "n1",
      "sequence": 1,
      "timestamp": {"physicalMs": 1000, "logical": 0},
      "payload": [1, 2, 3]
    }
  ]
}
```

**gossip-kt today** (`ProtocolCodec.kt:144-149`, `:192-219`; message shape from `GossipMessages.kt:58-61`) would emit, for the *structurally different* `DeltaResponse(sender = n1, entries = mapOf(channelId to mapOf(streamId to listOf(entry))))`:

```json
{
  "sender": "n1",
  "entries": {
    "ch1": {
      "s1": [
        {
          "author": "n1",
          "sequence": 1,
          "timestamp": {"physicalMs": 1000, "logical": 0},
          "payload": [1, 2, 3]
        }
      ]
    }
  }
}
```

**These are NOT byte-compatible today, and the divergence is structural, not cosmetic.** Field-by-field:

- `NodeId` representation: identical — plain JSON string, both sides (`msg.sender.value` in v1 `protocol_codec.dart:222`; `msg.sender.value` in kt `ProtocolCodec.kt:209` inside `encodeLogEntry`; top-level `sender` field the same in both). **No divergence.**
- `Hlc`/timestamp representation: identical — nested object `{"physicalMs": ..., "logical": ...}` in both (`protocol_codec.dart:224-227` vs `ProtocolCodec.kt:211-216`), same field names, same nesting (`physicalMs` maps to `Long` in kt `Hlc.kt:17` vs `int` in Dart, but JSON has no int/long distinction). **No divergence.**
- `payload` byte representation: **identical today** — both emit a raw JSON int array (`protocol_codec.dart:228`: `entry.payload.toList()`; `ProtocolCodec.kt:217`: `JsonArray(entry.payload.map { JsonPrimitive(it.toInt()) })`). Note this means **kt has no base64 support at all** — only v2 Dart introduced base64 (§3d/3e); kt would fail to decode a base64-string payload from v2 Dart (`.jsonArray` throws `IllegalArgumentException` on a `JsonPrimitive`, caught by `decode`'s blanket catch, **entire message dropped as null** — see §2c).
- **Envelope/shape**: **diverges** — v1 Dart's `DeltaRequest`/`DeltaResponse` are scoped to a *single* `channelId`+`streamId` pair per message (flat top-level fields, `protocol_codec.dart:168-184`); gossip-kt's `DeltaRequest`/`DeltaResponse` are batched across **all** channels and streams in one message via nested `Map<ChannelId, Map<StreamId, ...>>` structures with no top-level `channelId`/`streamId`/`since` keys at all (`GossipMessages.kt:44-61`; wire encode at `ProtocolCodec.kt:137-149`, `:180-202`). A v1-Dart-shaped `DeltaResponse` JSON (with top-level `channelId`/`streamId`, flat `entries` array) fails to decode against gossip-kt's decoder, which looks for `json["entries"]!!.jsonObject` (`ProtocolCodec.kt:269`) — a Dart `entries` (JSON array) is not a `JsonObject`, so `.jsonObject` throws, caught, decode returns null. Same failure in reverse: v1 Dart's `_decodeDeltaResponse` does `json['channelId'] as String` (`protocol_codec.dart:307`), which throws `TypeError`/`null` cast failure against kt's envelope (no top-level `channelId` key at all), uncaught inside the codec, propagating to the engine's catch-and-report path (§1b).

This is independent of, and larger than, the base64-vs-int-array divergence the task anticipated — it's a **request/response envelope shape mismatch on `DeltaRequest`/`DeltaResponse`** that predates any version-prefix work.

---

## Summary

**Type-byte tables (identical across all three dialects):**

| Message | v1 Dart | v2 Dart | gossip-kt |
|---|---|---|---|
| Ping | 0 | 0 | 0 |
| Ack | 1 | 1 | 1 |
| PingReq | 2 | 2 | 2 |
| DigestRequest | 3 | 3 | 3 |
| DigestResponse | 4 | 4 | 4 |
| DeltaRequest | 5 | 5 | 5 |
| DeltaResponse | 6 | 6 | 6 |

**Tolerance answers:**

1. v1 Dart tolerates unknown extra JSON keys? **Yes** (manual key-by-key `Map` reads, `protocol_codec.dart:257-353`).
2. v1 Dart tolerates a base64-string `payload` in place of an int array? **No** — throws a `TypeError` on the `as List` cast (`protocol_codec.dart:353`), caught one layer up by `GossipEngine`/`FailureDetector` and reported as `PeerSyncError(messageCorrupted)`; the message is dropped, the loop survives.
3. gossip-kt tolerates unknown extra JSON keys? **Yes** (manual `JsonObject` key reads via `kotlinx.serialization`'s untyped tree API, never a `@Serializable`-class strict decode — `ProtocolCodec.kt:235-269`).
4. gossip-kt tolerates a base64-string `payload`? **No** — `.jsonArray` throws `IllegalArgumentException` on a `JsonPrimitive`, caught internally by `decode`'s blanket catch (`ProtocolCodec.kt:64-71`), and the **entire message** (not just the entry) silently becomes `null` with zero error reporting at the only production call site (`Coordinator.kt:285-303`).

**Safe version-marker byte range:** `0x07`-`0xFF` (7-255) — unclaimed by v1/v2 Dart type bytes, gossip-kt type bytes, gossip_nearby's outer envelope (`0x01`/`0x02`, a different framing layer that the marker wouldn't occupy), and gossip_bluey (which never inspects the payload at all).

**Most surprising finding:** gossip-kt's `DeltaRequest`/`DeltaResponse` wire schema is **already structurally incompatible** with both Dart dialects — it's not a superficial field-rename or an additive-field situation like v1→v2's `hasMore`/`floor`, but a wholesale shape change from "one message per channel+stream pair" (Dart, both versions) to "one message batching all channels/streams as nested maps" (kt, `GossipMessages.kt:44-61`). Any version-prefix / dialect-negotiation design has to treat gossip-kt's `DeltaRequest`/`DeltaResponse` as an entirely separate schema to translate, not just a payload-encoding variant — while `Ping`/`Ack`/`PingReq`/`DigestRequest`/`DigestResponse` remain field-compatible across all three dialects today.
