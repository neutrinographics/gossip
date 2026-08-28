# Recon: does the vendored gossip-kt copy in opendoor-api diverge from standalone main?

Date: 2026-08-28
Scope: read-only recon, no code changes.

## 1. Provenance

`/Users/joel/git/neutrinographics/opendoor-api` is a git repo. `gossip-kt` is a
proper **git submodule** (`.gitmodules`: `url = git@github.com:neutrinographics/gossip-kt.git`,
`path = gossip-kt`), wired into the Gradle build as a **composite build**
(`settings.gradle.kts`: `includeBuild("gossip-kt")`;
`build.gradle.kts`: `implementation("com.neutrinographics:gossip-kt:0.1.0-SNAPSHOT")`).
There is no second, independently-copied set of gossip source files anywhere
under `opendoor-api/src` — the only gossip-kt code the server builds against
is the submodule checkout.

The submodule is pinned at `5255d744208e4c580371112c9ccdf8c3329436d7`
(`git submodule status` → `5255d74... gossip-kt (v0.1.0-SNAPSHOT-22-g5255d74)`),
working tree clean, no local patches. The pin was last moved by opendoor-api
commit `c54be47` ("updated submodule", 2026-03-28); the four preceding
submodule-touching commits (2026-03-27, "Feat/upgrade gossip" etc.) were
earlier pin bumps as gossip-kt evolved.

**Key finding: `5255d74` is not an old point standalone main has since moved
past — it *is* standalone main's current tip.**

```
git -C gossip-kt merge-base --is-ancestor 5255d74 main   → true
git -C gossip-kt log --oneline 5255d74..main             → (empty, 0 commits)
```

Standalone `gossip-kt` main is currently checked out at `feature/compaction`
locally, but `main` itself (via `git show main:<path>`, no checkout touched)
resolves to exactly `5255d74`.

## 2. Full-tree diff: vendored vs. standalone main

```
git -C gossip-kt archive main | tar -x -C /tmp/kt-main
diff -rq /Users/joel/git/neutrinographics/opendoor-api/gossip-kt/src /tmp/kt-main/src   → no output, exit 0
diff -rq .../opendoor-api/gossip-kt /tmp/kt-main (excluding .git/.gradle/build/.kotlin/.idea) → no output
```

**Zero differing, added, or removed files.** The vendored copy is byte-for-byte
identical to standalone `main` across the entire repository, not just `src`.
There is no divergence to harvest — the two are the same commit, full stop.

## 3. Delta schema in the vendored copy

Read directly from
`opendoor-api/gossip-kt/src/main/kotlin/com/neutrinographics/gossip/messages/GossipMessages.kt`
and `ProtocolCodec.kt` (working tree, pinned at 5255d74):

```kotlin
// Structure: channelId -> streamId -> authorNodeId -> sinceSequence
data class DeltaRequest(
    override val sender: NodeId,
    val channelDeltas: Map<ChannelId, Map<StreamId, Map<NodeId, Int>>>,
) : ProtocolMessage()

// Structure: channelId -> streamId -> list of entries
data class DeltaResponse(
    override val sender: NodeId,
    val entries: Map<ChannelId, Map<StreamId, List<LogEntry>>>,
) : ProtocolMessage()
```

`ProtocolCodec.encode/decode`: wire format is `[type byte][UTF-8 JSON payload]`
(type 0–6 as documented in the class kdoc). `DeltaRequest`/`DeltaResponse` are
encoded via `encodeChannelDeltas`/`encodeChannelEntries`, which nest
`JsonObject`s keyed by `channelId.value` → `streamId.value` → (version-vector
map / entry array) — genuinely nested/batched JSON, not flat. `LogEntry.payload`
(a `ByteArray`) is encoded as a **JSON array of ints** (`JsonArray(entry.payload.map { JsonPrimitive(it.toInt()) })`),
not base64.

**Verdict: the vendored copy's schema is batched/nested, matching standalone
main exactly — it does *not* match Dart's flat per-(channel,stream) schema.**
The premise that the vendored copy itself has been patched to the flat shape
is false; there is no such patch anywhere in the tree (confirmed by the §2 diff).

## 4. How they actually interoperate (the real answer)

Since the wire schemas are genuinely incompatible and the vendored gossip-kt
is unmodified, the compatibility must live outside gossip-kt. It does:
`OpenDoorApp/lib/features/sync/infrastructure/gossip/protocol_translator.dart`
is a dedicated `ProtocolTranslator` class, instantiated by
`websocket_connection_service.dart` (`final ProtocolTranslator _translator = ProtocolTranslator();`,
used at the send/receive boundary via `translateOutgoing`/`translateIncoming`).
Its doc comment states the intent directly:

```
/// Translates between Dart gossip wire format and Kotlin gossip-kt wire format.
/// ...
/// Incompatibilities handled:
/// - DeltaRequest (5): Dart per-stream vs Kotlin batched channelDeltas
/// - DeltaResponse (6): Dart per-stream vs Kotlin batched entries
/// - PingReq (2): Kotlin adds originalRequester field
```

Outgoing (Dart → Kotlin): pulls `channelId`/`streamId`/`since` (or `entries`)
out of the flat Dart payload and re-nests them as
`{channelDeltas: {channelId: {streamId: since}}}` (mirror for DeltaResponse's
`entries`), and injects `originalRequester` for PingReq. Incoming (Kotlin →
Dart): walks the nested `channelDeltas`/`entries` maps and **fans a single
batched Kotlin message out into N flat per-(channel,stream) Dart messages**.
This is a hand-written, deliberate compatibility shim — not an accident of a
stale build. Git history confirms it was added alongside
`f6192619 "configure mobile app to sync with the api ... "` in OpenDoorApp,
i.e. purpose-built when API sync was introduced, well before the pinned Dart
commit 73f6a58 (2026-05-09).

So: nothing is "wrong" or divergent in the vendored gossip-kt — the app-side
translator is the actual interop layer, and it is why sync "just works" today
despite the two libraries' in-memory schemas disagreeing.

## 5. Other divergent files

None — §2's diff was empty. There is nothing else to summarize or flag as a
fix the standalone repo lacks; vendored == standalone main bit-for-bit.

## 6. Vendored copy's test suite

Gradle wrapper exists at `opendoor-api/gossip-kt/gradlew`. Ran
`./gradlew test --console=plain` from that directory:

```
BUILD SUCCESSFUL in 29s
4 actionable tasks: 4 executed
```

Aggregated JUnit XML under `build/test-results`: **563 tests, 0 failures.**

## 7. OpenDoorApp's transport to the server

The mobile app talks to the API over a **plain WebSocket**
(`WebSocketChannel.connect(Uri.parse(syncUrl))` in
`websocket_connection_service.dart`), managed by `WebSocketConnectionService`
— connect/handshake lifecycle, single-subscription-safe stream handling, and
exponential-backoff auto-reconnect (1s → 2s → ... capped at 30s, reset after
30s of stable connection). Outbound `MessagePort` bytes are run through
`ProtocolTranslator.translateOutgoing` before being sent on the socket;
inbound frames are run through `translateIncoming` (which may fan one Kotlin
message into several Dart messages) before being handed to the gossip engine.
This sits behind `WebSocketTransportAdapter`/`WebSocketMessagePort`, one of
several transports composed via `composite_message_port.dart` (alongside the
Nearby Connections adapter for local mesh sync).
