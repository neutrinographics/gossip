# gossip_bluey: resilient framing — magic-prefix sync marker + iOS-aware chunk size

**Status:** Design
**Date:** 2026-05-05
**Type:** Bug fix (hardware-test follow-up)
**Builds on:** `2026-05-05-gossip-bluey-peripheral-address-dedup-design.md`
**Bluey upstream:** I325 (`Connection.maxWritePayload`)

## Problem

After landing the peripheral-side address-dedup fix, hardware testing showed connections persist for ~2 minutes of normal traffic before breaking with:

```
Frame decode error: NodeId(...) - frame length 942956845 exceeds max 32768
Peer disconnected: <peer>
```

The bad length `0x3834612D` decodes as ASCII `"84a-"` — a substring of the peer's NodeId UUID embedded in some recent message payload. The byte stream had slipped out of alignment by ≥4 bytes, and the decoder treated payload bytes as a new length prefix.

Two compounding causes:

1. **Tiny chunks on iOS.** `BlueyPortImpl.chunkSizeFor` derives chunk size from `Connection.mtu`, which on iOS is **always 23** (default — bluey doesn't surface the platform-negotiated value; see I325). With chunkSize=20 and a typical 200-byte gossip message, that's 10 chunks/message. At observed traffic (~6 msg/s), that's ~60 writes/s. Over a 2-minute connection, ~7,200 writes.

2. **Writes-without-response have no link-layer ACK.** `BlueyPortImpl.sendData` writes via `dataChar.write(data, withResponse: false)`. Each write is fire-and-forget at the BLE layer. Even with low individual drop rates, ~7,200 writes saturate the probability that *some* drop happens.

A single dropped chunk corrupts the byte stream forever — the decoder reads N expected bytes, gets a payload that's actually N-K bytes long, and the next "length prefix" is read from the middle of the previous payload.

The current decoder behavior on `FormatException` is to call `port.disconnect(nodeId)`, tearing down the entire connection. This is heavy-handed: corruption indicates a misaligned byte stream, not a dead BLE link.

## Goals

- **Survive write drops gracefully**: a dropped chunk causes at most a few lost messages, not a connection tear-down. Gossip's anti-entropy will re-sync within ~1 second on the next round.
- **Reduce drop frequency** by using a chunk size appropriate for iOS without depending on the bluey upstream change (I325) landing first.
- **Keep current performance**: no per-write ACK round-trip cost (writes-with-response, option **B** from earlier brainstorming, is rejected for this iteration).
- **Stay DDD-clean**: changes confined to `infrastructure/codec/`, `infrastructure/adapters/`, `application/observability/`, and `application/services/`. No domain layer changes.

## Non-goals

- Switching the central send path to writes-with-response. Performance trade-off was deemed not worth it given gossip's tolerance for occasional message loss.
- Switching the peripheral notify path to indications. Same reasoning.
- Recovering specific *messages* lost in a corruption event. Gossip's anti-entropy provides eventual delivery via re-sync.
- Replacing the bluey upstream MTU work (I325). The chunk-size workaround here is a temporary measure that should be removed once I325 lands.

## High-level approach

Two changes, independent but complementary:

**A.1 — iOS-aware conservative chunk size.** When the peer is on iOS and the negotiated MTU appears to be the BLE default (23), assume the platform negotiated higher and use a conservative 100-byte chunk size — well below iOS's typical 158-185 byte `maximumWriteValueLength` minimum. On Android, continue using the negotiated MTU. This is a workaround until bluey ships `Connection.maxWritePayload` (I325); when that lands, swap this logic to use the new API.

**C — Magic-prefix framing with corruption recovery.** Change the wire format from `[length 4 bytes][payload]` to `[magic 4 bytes][length 4 bytes][payload]`. The decoder verifies the magic on every frame; on mismatch, it scans forward byte-by-byte until it finds the next valid magic, discards the skipped bytes, and continues. The connection stays up; only the in-flight frame(s) at the moment of the drop are lost.

## Frame format

### Wire format

```
+-----------------+-----------------+--------------------+
| magic (4 bytes) | length (4 bytes)| payload (N bytes)  |
| 0x47 53 50 31   | uint32 BE       |                    |
+-----------------+-----------------+--------------------+
```

The magic value is `0x47535031`, ASCII `"GSP1"` ("Gossip Sync Protocol v1"). Choosing printable ASCII makes hex dumps readable; the version digit lets us evolve the format later. False-positive collision rate inside payloads is ~1/2³² per byte position (~0.00005% per typical 200-byte message); the decoder's recovery loop handles the rare case where it accidentally re-syncs inside a payload by hitting the next misalignment immediately and skipping again.

Total framing overhead is 8 bytes per frame, vs. 4 today. For typical 200-byte gossip messages, that's a 2% wire overhead — negligible.

### Encoder

`FrameEncoder.encode(payload, mtuPayloadSize)`:

1. Allocate a `Uint8List` of `(8 + payload.length)` bytes.
2. Write magic at offset 0–3, length at offset 4–7 (big-endian uint32), payload at offset 8.
3. Split into chunks of `mtuPayloadSize`, return list.

Validation unchanged: `payload.isEmpty` and `payload.length > kMaxFramePayload` (32 KB) still throw `ArgumentError`. `mtuPayloadSize` minimum bumps from `kLengthPrefixSize + 1` (5) to `kMagicSize + kLengthPrefixSize + 1` (9), since a chunk smaller than the magic+length header would be useless.

### Decoder

`FrameDecoder.feed(chunk)` becomes a small state machine:

```
states: SEEKING_MAGIC | READING_LENGTH | READING_PAYLOAD
```

- **SEEKING_MAGIC**: scan the buffer byte-by-byte for the magic `0x47535031`. If found at offset N, discard bytes `[0, N)` (record `N` as bytes-discarded for metrics) and transition to `READING_LENGTH`. If not found and < 4 bytes remain at the buffer's tail, keep them (might be a partial magic across chunks).
- **READING_LENGTH**: when ≥ 4 bytes available, consume the length, transition to `READING_PAYLOAD`. If `length > kMaxFramePayload`, the magic was a false positive — log it, discard the magic+length we just consumed, transition back to `SEEKING_MAGIC`.
- **READING_PAYLOAD**: when ≥ length bytes available, consume the payload, emit the message, transition to `SEEKING_MAGIC` for the next frame.

The decoder no longer throws `FormatException` — it can always make forward progress (in the worst case by discarding bytes). Bytes discarded are reported via a new return field on `feed`:

```dart
class FrameFeedResult {
  final List<Uint8List> messages;
  final int bytesDiscarded;  // only counts bytes skipped during SEEKING_MAGIC
  const FrameFeedResult(this.messages, this.bytesDiscarded);
}

FrameFeedResult feed(Uint8List chunk);
```

`messages` is the same list previously returned. `bytesDiscarded` is `0` for the steady-state happy path; only non-zero when corruption recovery happens. The application layer uses it for metrics and logging.

### Backwards compatibility

Not needed. Wire format change is atomic — both peers must run the new build. No coexistence layer, no fallback to the old format.

## Chunk-size policy

`BlueyPortImpl.chunkSizeFor(NodeId)` becomes platform-aware:

```dart
int chunkSizeFor(NodeId nodeId) {
  final mtu = _mtuByNode[nodeId];
  if (mtu == null) return _defaultChunkSize;        // 20 — pre-MTU-known
  // ATT payload = MTU - 3 (ATT header). Subtract a safety margin.
  final attBased = mtu - 3 - _safetyMargin;

  // iOS workaround: bluey does not surface the platform-negotiated MTU
  // through Connection.mtu (it stays at 23 forever). When we see the
  // BLE-default value, assume iOS has negotiated higher and use a
  // conservative chunk size that fits within the typical
  // maximumWriteValueLength minimum (158+ on iOS 13+). 100 bytes is
  // safely below that on all known hardware.
  //
  // TODO(I325): once bluey exposes Connection.maxWritePayload, drop
  // this workaround and use it directly.
  if (mtu == _bleDefaultMtu && _bluey.capabilities.platformKind ==
      bluey.PlatformKind.ios) {
    return _iosFallbackChunkSize;  // 100
  }
  return attBased < _defaultChunkSize ? _defaultChunkSize : attBased;
}

static const int _bleDefaultMtu = 23;
static const int _iosFallbackChunkSize = 100;
```

This affects iOS-as-central writes (the case in our hardware test). Android-as-central (where MTU is properly negotiated and stored) is unchanged. iOS-as-peripheral uses `notifyTo` which has its own size limits that bluey already handles correctly.

## Observability

Add to `BlueyMetrics`:

```dart
int _frameRecoveries = 0;
int _bytesDiscarded = 0;

void recordFrameRecovery(int bytesDiscarded) {
  _frameRecoveries++;
  _bytesDiscarded += bytesDiscarded;
}

int get frameRecoveries => _frameRecoveries;
int get bytesDiscarded => _bytesDiscarded;
```

Surfaced via `BlueyTransport.metrics` so app-level dashboards (gossip_chat's metrics view) can show recovery counts.

`ConnectionService._onPortEvent` (`PortPeerData` case) replaces the current tear-down with metric+log:

```dart
case PortPeerData(:final nodeId, :final data):
  final decoder = _decoders[nodeId];
  if (decoder == null) return;
  metrics.recordFrameReceived();
  metrics.recordBytesReceived(data.length);
  final result = decoder.feed(data);
  if (result.bytesDiscarded > 0) {
    metrics.recordFrameRecovery(result.bytesDiscarded);
    onLog?.call(
      LogLevel.warning,
      'frame decoder recovered from corruption on $nodeId; '
      'discarded ${result.bytesDiscarded} bytes',
    );
  }
  for (final m in result.messages) {
    metrics.recordMessageReceived();
    _incoming.add(IncomingMessage(...));
  }
```

No `FormatException` catch needed — the decoder's contract is now "always returns; never throws on malformed input." `port.disconnect(nodeId)` is removed from this path.

## DDD layering

| Concern | Layer | Component |
|---|---|---|
| Wire format (magic + length + payload) | Infrastructure | `FrameEncoder`, `FrameDecoder` |
| Decoder state machine and corruption recovery | Infrastructure | `FrameDecoder` |
| Recovery observability counters | Application | `BlueyMetrics` |
| iOS-aware chunk-size fallback | Infrastructure | `BlueyPortImpl.chunkSizeFor` |
| Acting on `FrameFeedResult` (recording metrics, logging, never disconnecting) | Application | `ConnectionService._onPortEvent` |

No domain types change. No new ports. The codec's public type changes from `List<Uint8List> feed(...)` to `FrameFeedResult feed(...)`, but `FrameFeedResult` is itself an infrastructure-layer value.

## Edge cases

- **Magic appears in a payload**. The encoder doesn't escape payload bytes — magic collision is possible. False-positive rate per byte position is 1/2³² ≈ 0.00005% per 200-byte message. When the decoder is in `SEEKING_MAGIC` and collides on payload bytes, it'll then read garbage as a length. If that length is implausible (>32 KB), it bounces back to `SEEKING_MAGIC` immediately. If the length happens to be plausible, the decoder waits for that many bytes — eventually hitting the *next* real magic (which won't match a length-aligned position), bouncing back. Worst case: a few extra messages discarded. No infinite loops.
- **Partial magic across chunk boundaries**. The decoder must keep up to 3 unmatched bytes at the buffer tail in `SEEKING_MAGIC` mode. Standard scanning logic.
- **Very large discard count**. If the byte stream is fundamentally garbage (no magic ever appears), the decoder accumulates indefinitely. Bound: cap the SEEKING_MAGIC buffer at, say, 64 KB; beyond that, drop the oldest half. (Gossip messages are ≤32 KB so a 64 KB buffer is comfortably above any single-frame size.)
- **Decoder reset on disconnect**. Existing logic clears `_decoders[nodeId]` on `PortPeerDisconnected`. Unchanged. New connections start fresh in `SEEKING_MAGIC`.
- **iOS chunk-size fallback when MTU is 23 but the peer is *actually* limited to 23 (e.g., a tiny BLE peripheral that didn't negotiate up)**. Writing 100-byte chunks to such a peer would fail at the platform level. We accept this risk: gossip_bluey only talks to other gossip_bluey peers, which will always negotiate sensibly.

## Test plan

### Unit tests

**`FrameEncoder`** (`test/infrastructure/codec/frame_codec_test.dart`):

1. **Magic prefix appears at the start of every frame.** Encode a 1-byte payload with chunk size 9 (minimum); verify the resulting bytes start with `0x47 53 50 31`.
2. **Length follows the magic.** Encode a 100-byte payload; assert bytes 4-7 are `0x00 00 00 64` (100 in big-endian).
3. **Total framed length is `8 + payload.length`.** Existing length-only assertion updated.
4. **`mtuPayloadSize < 9` throws ArgumentError.** Updated minimum.

**`FrameDecoder`**:

5. **Happy path: a single complete frame is emitted.** Feed `[magic][length=5][hello]`; assert one message returned, `bytesDiscarded == 0`.
6. **Multiple frames in one chunk are all emitted.** Feed two frames concatenated.
7. **Frame split across chunks.** Feed magic+length in chunk 1, payload in chunk 2; assert one message after both chunks.
8. **Garbage prefix is discarded.** Feed `[garbage 7 bytes][magic][length=3][abc]`; assert one message and `bytesDiscarded == 7`.
9. **Corruption mid-stream: missing bytes from a payload cause re-sync at next magic.** Feed frame A truncated by 5 bytes, then frame B intact; assert frame A is *not* emitted, frame B *is* emitted, `bytesDiscarded > 0`.
10. **Implausible length triggers re-scan.** Feed `[magic][length=0xFFFFFFFF][...real frame...]`; assert the bogus length doesn't cause `FormatException`; the next real magic is found and its frame is emitted.
11. **Partial magic across chunks does not falsely match.** Feed `[0x47 0x53]` then `[0x50 0x31][length=...][payload]`; assert clean emission.
12. **Buffer cap prevents unbounded growth.** Feed 100 KB of garbage with no magic; assert the decoder discards old bytes (buffer length stays ≤ 64 KB).

**`BlueyMetrics`** (`test/application/observability/bluey_metrics_test.dart`):

13. **`recordFrameRecovery` increments counters.** New test; assert `frameRecoveries++` and `bytesDiscarded += N`.

**`BlueyPortImpl.chunkSizeFor`** (`test/infrastructure/adapters/bluey_port_impl_test.dart` if it exists, else direct on the impl):

14. **Returns 100 on iOS when MTU is the BLE default (23).** Stub `_bluey.capabilities.platformKind = ios`, set `_mtuByNode[id] = 23`, expect 100.
15. **Returns the negotiated MTU-derived value when MTU > 23 on iOS.** With `mtu = 100`, expect 96 (100 - 3 - 1).
16. **Returns the negotiated MTU-derived value on Android regardless.** With `mtu = 23` on Android (unlikely but defensible), expect 20 (default chunk size). With `mtu = 247` on Android, expect 243.

**`ConnectionService` `PortPeerData` handler** (`test/application/services/connection_service_test.dart`):

17. **Frame recovery doesn't disconnect.** Drive a `PortPeerData` event with bytes that the decoder reports as `bytesDiscarded > 0`; assert no `port.disconnect` call, metric is incremented, log emitted at warning level.
18. **Recovered frames after a corruption event are emitted as IncomingMessages.** Same scenario; assert the *valid* messages from the same `feed` call are emitted.

### Integration test (using `FakeBlueyPort`)

19. **Sustained traffic with injected mid-stream corruption converges.** Run a two-fake setup, drop one chunk mid-conversation (via a new `FakeBlueyPort` injector), assert the connection stays up, the metric records the recovery, and subsequent messages flow.

### Hardware verification (manual)

20. **Two-device run for ≥10 minutes with active typing/messaging.** Same hardware setup that previously failed. Expect:
    - Connection stays up; no `Frame decode error: ... exceeds max 32768` followed by disconnect.
    - `BlueyMetrics.frameRecoveries` may be non-zero (occasional drops still happen) — but the connection persists.
    - Gossip-level message delivery may have ~few-percent loss, recovered via anti-entropy within seconds.

## Files touched

**New behavior, modified files (no new files):**

- `packages/gossip_bluey/lib/src/infrastructure/codec/frame_codec.dart`
  - Add `kMagic = 0x47535031` constant.
  - Add `FrameFeedResult` value type.
  - Update `FrameEncoder.encode` to emit magic prefix.
  - Rewrite `FrameDecoder.feed` as a state machine returning `FrameFeedResult`. Remove `FormatException`-throwing path.
- `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart`
  - Update `chunkSizeFor` with iOS fallback. Add `_iosFallbackChunkSize`, `_bleDefaultMtu` constants.
- `packages/gossip_bluey/lib/src/application/observability/bluey_metrics.dart`
  - Add `recordFrameRecovery(int)`, `frameRecoveries`, `bytesDiscarded` getters.
- `packages/gossip_bluey/lib/src/application/services/connection_service.dart`
  - Replace `try/catch` on `decoder.feed` with `FrameFeedResult`-aware logic. Remove `port.disconnect` from this path.
- `packages/gossip_bluey/test/infrastructure/codec/frame_codec_test.dart`
  - Tests 1-12 above; replaces existing tests for old format.
- `packages/gossip_bluey/test/application/observability/bluey_metrics_test.dart`
  - Test 13.
- `packages/gossip_bluey/test/application/services/connection_service_test.dart`
  - Tests 17-18.
- `packages/gossip_bluey/test/fakes/fake_bluey_port.dart`
  - Add `injectChunkDrop` test hook for integration test 19.

No facade (`BlueyTransport`) public API change.

## Out of scope

- Switching to writes-with-response (option B). Performance trade-off rejected for this iteration; reconsider only if A.1 + C don't sufficiently reduce the corruption rate in production.
- Switching peripheral-side notifications to indications. Same reasoning.
- Bluey upstream `Connection.maxWritePayload` work — tracked in I325. When that lands, the iOS workaround in `chunkSizeFor` is replaced with a one-liner.
- Any framing-level retransmission protocol. Gossip's anti-entropy provides eventual delivery; framing layer doesn't need to.
