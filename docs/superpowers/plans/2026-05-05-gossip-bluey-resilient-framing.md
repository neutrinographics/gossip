# gossip_bluey resilient framing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make gossip_bluey survive single-chunk drops on writes-without-response without tearing down the connection — combine a magic-prefix sync marker that lets the decoder re-align after corruption with a conservative iOS chunk size that reduces drop frequency.

**Architecture:** Wire format becomes `[magic 4][length 4][payload]`. Decoder is a state machine (`SEEKING_MAGIC` → `READING_LENGTH` → `READING_PAYLOAD`) that never throws — corruption causes byte-skipping until the next valid magic, reported via `FrameFeedResult.bytesDiscarded`. `BlueyPortImpl.chunkSizeFor` returns 100-byte chunks when iOS reports default MTU (workaround until bluey ships I325). `ConnectionService` records recoveries as a metric and logs at warning level instead of disconnecting.

**Tech Stack:** Dart 3, Flutter (gossip_bluey), bluey BLE library, melos, `flutter test`.

**Spec:** `docs/superpowers/specs/2026-05-05-gossip-bluey-resilient-framing-design.md`
**Bluey upstream:** I325 (`Connection.maxWritePayload`)

---

## File Structure

**Modified files only — no new files.**

- `packages/gossip_bluey/lib/src/infrastructure/codec/frame_codec.dart` — add `kMagic`, `FrameFeedResult`; change encoder to prepend magic; rewrite decoder as state machine.
- `packages/gossip_bluey/lib/src/application/observability/bluey_metrics.dart` — add `recordFrameRecovery(int)`, `frameRecoveries`, `bytesDiscarded`.
- `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart` — iOS-aware `chunkSizeFor` fallback.
- `packages/gossip_bluey/lib/src/application/services/connection_service.dart` — replace `try/catch` on `decoder.feed` with `FrameFeedResult`-aware logic; remove the disconnect-on-corruption path.
- `packages/gossip_bluey/test/infrastructure/codec/frame_codec_test.dart` — replace existing length-only tests with magic-prefix tests; add corruption-recovery tests.
- `packages/gossip_bluey/test/application/observability/bluey_metrics_test.dart` — add tests for the new counter.
- `packages/gossip_bluey/test/application/services/connection_service_test.dart` — add tests for recovery-on-corruption and no-disconnect-on-corruption.
- `packages/gossip_bluey/test/fakes/fake_bluey_port.dart` — add `chunkDropInjector` hook.

---

## Task 1: Update `FrameEncoder` to emit magic prefix

**Files:**
- Modify: `packages/gossip_bluey/lib/src/infrastructure/codec/frame_codec.dart`
- Modify: `packages/gossip_bluey/test/infrastructure/codec/frame_codec_test.dart`

This task changes the wire format. Existing tests will fail until they're updated to expect the magic prefix; we update the encoder and its tests together.

- [ ] **Step 1: Update encoder tests for the new format**

In `packages/gossip_bluey/test/infrastructure/codec/frame_codec_test.dart`, replace the existing `FrameEncoder` group (lines 6–55 or so — keep the file's imports and the `void main()` wrapper):

```dart
  group('FrameEncoder', () {
    // Magic 0x47535031 == ASCII "GSP1"
    const magic = [0x47, 0x53, 0x50, 0x31];

    test('emits a single chunk when payload + magic + length fits the MTU', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final chunks = FrameEncoder.encode(payload, mtuPayloadSize: 100);
      expect(chunks, hasLength(1));
      expect(chunks.first, hasLength(8 + 5));
      // magic
      expect(chunks.first.sublist(0, 4), equals(magic));
      // length prefix: big-endian 5
      expect(chunks.first.sublist(4, 8), equals([0, 0, 0, 5]));
      // payload
      expect(chunks.first.sublist(8), equals([1, 2, 3, 4, 5]));
    });

    test('splits across multiple chunks when payload exceeds MTU', () {
      // mtuPayloadSize = 12. Magic + length prefix take 8 bytes of the
      // first chunk. Payload = 20 bytes. First chunk carries 8 header
      // bytes + 4 payload bytes; remaining 16 payload bytes need
      // ceil(16/12) = 2 chunks.
      final payload = Uint8List.fromList(List.generate(20, (i) => i));
      final chunks = FrameEncoder.encode(payload, mtuPayloadSize: 12);
      expect(chunks, hasLength(3));
      expect(chunks[0], hasLength(12));
      expect(chunks[0].sublist(0, 4), equals(magic));
      expect(chunks[0].sublist(4, 8), equals([0, 0, 0, 20]));
      expect(chunks[0].sublist(8), equals([0, 1, 2, 3]));
      expect(chunks[1], hasLength(12));
      expect(chunks[1], equals([4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]));
      expect(chunks[2], hasLength(4));
      expect(chunks[2], equals([16, 17, 18, 19]));
    });

    test('throws on empty payload', () {
      expect(
        () => FrameEncoder.encode(Uint8List(0), mtuPayloadSize: 20),
        throwsArgumentError,
      );
    });

    test('throws when mtuPayloadSize is too small to hold magic + length', () {
      // magic + length = 8 bytes; need at least one byte of payload room
      // in the first chunk.
      expect(
        () => FrameEncoder.encode(Uint8List.fromList([1]), mtuPayloadSize: 8),
        throwsArgumentError,
      );
    });

    test('rejects payloads larger than 32KB', () {
      final payload = Uint8List(32 * 1024 + 1);
      expect(
        () => FrameEncoder.encode(payload, mtuPayloadSize: 100),
        throwsArgumentError,
      );
    });
  });
```

- [ ] **Step 2: Run encoder tests to verify they fail**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/infrastructure/codec/frame_codec_test.dart -P "" 2>&1 | tail -20
```
(Or simply `flutter test test/infrastructure/codec/frame_codec_test.dart`.)

Expected: encoder tests FAIL — output bytes don't start with the magic.

- [ ] **Step 3: Update `FrameEncoder.encode` and constants**

In `packages/gossip_bluey/lib/src/infrastructure/codec/frame_codec.dart`, replace the constants and `FrameEncoder` class. The `FrameDecoder` class stays as-is for now — Task 3 rewrites it.

```dart
import 'dart:typed_data';

/// Maximum gossip message payload. Anything larger is rejected.
const int kMaxFramePayload = 32 * 1024;

/// Magic prefix at the start of every frame, ASCII "GSP1" (Gossip Sync
/// Protocol v1). Lets the decoder re-align after a byte-stream
/// corruption by scanning forward for the next valid prefix.
const List<int> kMagicBytes = [0x47, 0x53, 0x50, 0x31];

/// Length of the magic prefix in bytes.
const int kMagicSize = 4;

/// Length prefix size in bytes (big-endian uint32).
const int kLengthPrefixSize = 4;

/// Total framing overhead per frame: magic + length prefix.
const int kFrameHeaderSize = kMagicSize + kLengthPrefixSize;

/// Encodes a gossip payload into MTU-sized chunks for sequential writes.
abstract final class FrameEncoder {
  /// Returns the chunks to write, in order.
  ///
  /// Wire format: `[magic 4 bytes][length 4 bytes BE][payload N bytes]`,
  /// then chunked at [mtuPayloadSize] bytes per chunk.
  ///
  /// [mtuPayloadSize] is the per-chunk byte budget — the negotiated MTU
  /// minus 3 for the ATT header (and any safety margin the caller wants
  /// to subtract). Must exceed [kFrameHeaderSize] (8 bytes); a chunk
  /// smaller than the header would be useless.
  ///
  /// Throws [ArgumentError] if [payload] is empty, larger than
  /// [kMaxFramePayload], or [mtuPayloadSize] is too small.
  static List<Uint8List> encode(
    Uint8List payload, {
    required int mtuPayloadSize,
  }) {
    if (payload.isEmpty) {
      throw ArgumentError.value(payload, 'payload', 'must be non-empty');
    }
    if (payload.length > kMaxFramePayload) {
      throw ArgumentError.value(
        payload.length,
        'payload.length',
        'exceeds 32KB max',
      );
    }
    if (mtuPayloadSize <= kFrameHeaderSize) {
      throw ArgumentError.value(
        mtuPayloadSize,
        'mtuPayloadSize',
        'must exceed frame header size ($kFrameHeaderSize)',
      );
    }

    final framed = Uint8List(kFrameHeaderSize + payload.length);
    framed.setRange(0, kMagicSize, kMagicBytes);
    final view = ByteData.view(framed.buffer, framed.offsetInBytes);
    view.setUint32(kMagicSize, payload.length, Endian.big);
    framed.setRange(kFrameHeaderSize, framed.length, payload);

    final chunks = <Uint8List>[];
    var offset = 0;
    while (offset < framed.length) {
      final end = (offset + mtuPayloadSize).clamp(0, framed.length);
      chunks.add(framed.sublist(offset, end));
      offset = end;
    }
    return chunks;
  }
}
```

(Leave the `FrameDecoder` class below this exactly as it currently is — Task 3 replaces it.)

- [ ] **Step 4: Run encoder tests to verify they pass**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/infrastructure/codec/frame_codec_test.dart 2>&1 | tail -8
```

Expected: encoder tests PASS. Decoder tests will FAIL (because the encoder now emits bytes the old decoder doesn't understand). That's fine — Task 3 fixes the decoder.

- [ ] **Step 5: Commit**

```bash
cd /Users/joel/git/neutrinographics/gossip
git add packages/gossip_bluey/lib/src/infrastructure/codec/frame_codec.dart \
        packages/gossip_bluey/test/infrastructure/codec/frame_codec_test.dart
git commit -m "feat(gossip_bluey): FrameEncoder emits magic prefix \"GSP1\" before length+payload

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

The decoder is now broken end-to-end (encoder emits new format, decoder parses old format). Task 2 introduces the new return type, Task 3 rewrites the decoder to match. Don't run the full suite until Task 3.

---

## Task 2: Add `FrameFeedResult` value type

Introduces the new return type for `FrameDecoder.feed`. Trivial type addition; no behavior change yet — Task 3 rewrites the decoder body to actually return it.

**Files:**
- Modify: `packages/gossip_bluey/lib/src/infrastructure/codec/frame_codec.dart`

- [ ] **Step 1: Append `FrameFeedResult` after `FrameEncoder`**

In `packages/gossip_bluey/lib/src/infrastructure/codec/frame_codec.dart`, before the `FrameDecoder` class, add:

```dart
/// Result of a single [FrameDecoder.feed] call.
///
/// [messages] is the list of complete payloads decoded from the
/// accumulated buffer (possibly empty). [bytesDiscarded] is the total
/// number of bytes the decoder skipped during corruption-recovery
/// scanning in this call (zero in the steady state).
final class FrameFeedResult {
  final List<Uint8List> messages;
  final int bytesDiscarded;
  const FrameFeedResult(this.messages, this.bytesDiscarded);

  /// Convenience: result with no recovery and no messages.
  static const empty = FrameFeedResult(<Uint8List>[], 0);
}
```

- [ ] **Step 2: Verify it compiles**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter analyze lib/src/infrastructure/codec/frame_codec.dart 2>&1 | tail -5
```

Expected: clean (no errors). The class isn't used yet.

- [ ] **Step 3: Commit**

```bash
cd /Users/joel/git/neutrinographics/gossip
git add packages/gossip_bluey/lib/src/infrastructure/codec/frame_codec.dart
git commit -m "feat(gossip_bluey): add FrameFeedResult value type for decoder return

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Rewrite `FrameDecoder` as a state machine with corruption recovery

The big behavioral change. Replace the existing decoder with one that scans for the magic, reads the length, reads the payload, and never throws — corruption recovery happens by skipping bytes until the next magic.

**Files:**
- Modify: `packages/gossip_bluey/lib/src/infrastructure/codec/frame_codec.dart`
- Modify: `packages/gossip_bluey/test/infrastructure/codec/frame_codec_test.dart`

- [ ] **Step 1: Add failing decoder tests for the new behavior**

Replace the existing `FrameDecoder` group in `packages/gossip_bluey/test/infrastructure/codec/frame_codec_test.dart` with:

```dart
  group('FrameDecoder', () {
    const magic = [0x47, 0x53, 0x50, 0x31];

    /// Helper: build a single complete frame on the wire.
    Uint8List frame(List<int> payload) {
      final out = BytesBuilder()
        ..add(magic)
        ..add([
          (payload.length >> 24) & 0xFF,
          (payload.length >> 16) & 0xFF,
          (payload.length >> 8) & 0xFF,
          payload.length & 0xFF,
        ])
        ..add(payload);
      return out.toBytes();
    }

    test('happy path: a single complete frame is emitted', () {
      final dec = FrameDecoder();
      final result = dec.feed(frame([1, 2, 3, 4, 5]));
      expect(result.messages, hasLength(1));
      expect(result.messages.first, equals([1, 2, 3, 4, 5]));
      expect(result.bytesDiscarded, equals(0));
    });

    test('multiple frames in one chunk are all emitted', () {
      final dec = FrameDecoder();
      final combined = BytesBuilder()
        ..add(frame([1, 2, 3]))
        ..add(frame([4, 5, 6, 7]));
      final result = dec.feed(combined.toBytes());
      expect(result.messages, hasLength(2));
      expect(result.messages[0], equals([1, 2, 3]));
      expect(result.messages[1], equals([4, 5, 6, 7]));
      expect(result.bytesDiscarded, equals(0));
    });

    test('frame split across chunks emits once both have arrived', () {
      final dec = FrameDecoder();
      final whole = frame([10, 20, 30, 40]);
      // split somewhere in the middle of the payload
      final r1 = dec.feed(whole.sublist(0, 9));
      final r2 = dec.feed(whole.sublist(9));
      expect(r1.messages, isEmpty);
      expect(r2.messages, hasLength(1));
      expect(r2.messages.first, equals([10, 20, 30, 40]));
      expect(r1.bytesDiscarded, equals(0));
      expect(r2.bytesDiscarded, equals(0));
    });

    test('garbage prefix is discarded; subsequent frame is emitted', () {
      final dec = FrameDecoder();
      final input = BytesBuilder()
        ..add([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11]) // 7 garbage bytes
        ..add(frame([1, 2, 3]));
      final result = dec.feed(input.toBytes());
      expect(result.messages, hasLength(1));
      expect(result.messages.first, equals([1, 2, 3]));
      expect(result.bytesDiscarded, equals(7));
    });

    test('corruption mid-stream: missing bytes from a payload cause re-sync at next magic', () {
      final dec = FrameDecoder();
      // Frame A is 12 bytes total (magic 4 + length 4 + payload 4).
      // Truncate to 9 bytes (simulating 3 bytes lost).
      final a = frame([0xAA, 0xBB, 0xCC, 0xDD]);
      final aTruncated = a.sublist(0, 9);
      final b = frame([1, 2, 3]);
      final input = BytesBuilder()
        ..add(aTruncated)
        ..add(b);
      final result = dec.feed(input.toBytes());
      // A's payload is incomplete and B's magic re-syncs the decoder.
      // A is silently lost; B is emitted.
      expect(result.messages, hasLength(1));
      expect(result.messages.first, equals([1, 2, 3]));
      expect(result.bytesDiscarded, greaterThan(0));
    });

    test('implausible length triggers re-scan, not exception', () {
      final dec = FrameDecoder();
      // A frame whose length field claims 0xFFFFFFFF bytes — impossible,
      // exceeds kMaxFramePayload. Decoder must reject and re-scan.
      final bogus = Uint8List.fromList([
        ...magic,
        0xFF, 0xFF, 0xFF, 0xFF,
      ]);
      final good = frame([42]);
      final result = dec.feed(BytesBuilder()..add(bogus)..add(good)..toBytes());
      expect(result.messages, hasLength(1));
      expect(result.messages.first, equals([42]));
      expect(result.bytesDiscarded, greaterThan(0));
    });

    test('partial magic across chunks does not falsely match', () {
      final dec = FrameDecoder();
      // First chunk: only the first two bytes of the magic.
      final r1 = dec.feed(Uint8List.fromList([0x47, 0x53]));
      // Second chunk: the rest of the magic + length + payload.
      final r2 = dec.feed(Uint8List.fromList([
        0x50, 0x31,
        0x00, 0x00, 0x00, 0x03,
        0x77, 0x88, 0x99,
      ]));
      expect(r1.messages, isEmpty);
      expect(r1.bytesDiscarded, equals(0));
      expect(r2.messages, hasLength(1));
      expect(r2.messages.first, equals([0x77, 0x88, 0x99]));
      expect(r2.bytesDiscarded, equals(0));
    });

    test('bounded buffer prevents unbounded growth on garbage stream', () {
      final dec = FrameDecoder();
      // Feed 100 KB of garbage that doesn't contain the magic anywhere.
      // Use a byte that isn't part of magic to avoid accidental matches.
      final garbage = Uint8List(100 * 1024)..fillRange(0, 100 * 1024, 0x55);
      final result = dec.feed(garbage);
      expect(result.messages, isEmpty);
      // bytesDiscarded should reflect that the decoder dropped old bytes
      // when the buffer cap was hit. Exact value depends on the cap; we
      // just assert it's non-trivially large (>= 32 KB) — proving the
      // decoder isn't accumulating the full 100 KB.
      expect(result.bytesDiscarded, greaterThanOrEqualTo(32 * 1024));
    });
  });
}
```

(Replace the existing `FrameDecoder` group; keep the file's `FrameEncoder` group from Task 1 above it.)

- [ ] **Step 2: Run decoder tests to verify they fail**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/infrastructure/codec/frame_codec_test.dart 2>&1 | tail -15
```

Expected: most decoder tests FAIL — the existing decoder doesn't understand the magic prefix. Some may fail with exceptions complaining about the new `feed` return type (`FrameFeedResult` vs `List<Uint8List>`). All expected.

- [ ] **Step 3: Replace `FrameDecoder` body**

In `packages/gossip_bluey/lib/src/infrastructure/codec/frame_codec.dart`, replace the existing `FrameDecoder` class with the state-machine version:

```dart
enum _DecoderState { seekingMagic, readingLength, readingPayload }

/// Reassembles framed bytes (magic + 4-byte BE length + payload)
/// arriving in arbitrary chunk sizes. Recovers from byte-stream
/// corruption by scanning forward for the next valid magic.
///
/// Stateful: keep one decoder per connection.
class FrameDecoder {
  /// Maximum bytes retained in [_buffer] while the decoder is in
  /// SEEKING_MAGIC state with no match. If exceeded, the decoder
  /// discards the oldest half of the buffer (reporting them as
  /// bytesDiscarded). Bound chosen to comfortably exceed the largest
  /// possible single frame (32 KB payload + 8 byte header).
  static const int _seekingBufferCap = 64 * 1024;

  final BytesBuilder _buffer = BytesBuilder(copy: false);
  _DecoderState _state = _DecoderState.seekingMagic;
  int _expectedLength = 0;

  /// Feeds [chunk] into the decoder and returns any complete payloads
  /// available now plus the number of bytes discarded during corruption
  /// recovery in this call.
  FrameFeedResult feed(Uint8List chunk) {
    _buffer.add(chunk);
    final out = <Uint8List>[];
    var totalDiscarded = 0;

    while (true) {
      switch (_state) {
        case _DecoderState.seekingMagic:
          final scan = _buffer.toBytes();
          final matchIdx = _findMagic(scan);
          if (matchIdx < 0) {
            // No magic found yet. Keep at most kMagicSize - 1 bytes at
            // the tail (might be a partial magic spanning a chunk
            // boundary), and discard the rest if we're over the cap.
            final toKeep = scan.length < kMagicSize ? scan.length : kMagicSize - 1;
            if (scan.length - toKeep > 0) {
              if (scan.length - toKeep >= _seekingBufferCap ~/ 2) {
                // Way too much garbage — drop half the buffer.
                final dropTo = scan.length - toKeep - (_seekingBufferCap ~/ 2);
                totalDiscarded += dropTo;
                _buffer.clear();
                _buffer.add(scan.sublist(dropTo));
                continue;
              }
            }
            // Not over the cap. Just preserve the whole buffer and wait
            // for more bytes.
            return FrameFeedResult(out, totalDiscarded);
          }
          if (matchIdx > 0) {
            totalDiscarded += matchIdx;
          }
          _buffer.clear();
          // Drop bytes up to and including the magic; we'll re-add the
          // post-magic remainder.
          if (scan.length > matchIdx + kMagicSize) {
            _buffer.add(scan.sublist(matchIdx + kMagicSize));
          }
          _state = _DecoderState.readingLength;
          continue;

        case _DecoderState.readingLength:
          if (_buffer.length < kLengthPrefixSize) {
            return FrameFeedResult(out, totalDiscarded);
          }
          final all = _buffer.takeBytes();
          final view = ByteData.view(all.buffer, all.offsetInBytes);
          final len = view.getUint32(0, Endian.big);
          if (len > kMaxFramePayload || len < 0) {
            // Implausible length — magic was a false-positive. Discard
            // those 4 length bytes (already consumed) and re-scan.
            totalDiscarded += kLengthPrefixSize;
            if (all.length > kLengthPrefixSize) {
              _buffer.add(all.sublist(kLengthPrefixSize));
            }
            _state = _DecoderState.seekingMagic;
            continue;
          }
          _expectedLength = len;
          if (all.length > kLengthPrefixSize) {
            _buffer.add(all.sublist(kLengthPrefixSize));
          }
          _state = _DecoderState.readingPayload;
          continue;

        case _DecoderState.readingPayload:
          if (_buffer.length < _expectedLength) {
            return FrameFeedResult(out, totalDiscarded);
          }
          final all = _buffer.takeBytes();
          final payload = Uint8List.sublistView(all, 0, _expectedLength);
          out.add(Uint8List.fromList(payload));
          if (all.length > _expectedLength) {
            _buffer.add(all.sublist(_expectedLength));
          }
          _expectedLength = 0;
          _state = _DecoderState.seekingMagic;
          continue;
      }
    }
  }

  /// Returns the index of the first occurrence of [kMagicBytes] in
  /// [haystack], or -1 if not found.
  static int _findMagic(Uint8List haystack) {
    if (haystack.length < kMagicSize) return -1;
    final last = haystack.length - kMagicSize;
    for (var i = 0; i <= last; i++) {
      if (haystack[i] == kMagicBytes[0] &&
          haystack[i + 1] == kMagicBytes[1] &&
          haystack[i + 2] == kMagicBytes[2] &&
          haystack[i + 3] == kMagicBytes[3]) {
        return i;
      }
    }
    return -1;
  }
}
```

Delete the old `FrameDecoder` class entirely; the rewrite replaces it.

- [ ] **Step 4: Run decoder tests to verify they pass**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/infrastructure/codec/frame_codec_test.dart 2>&1 | tail -15
```

Expected: all encoder + decoder tests PASS.

- [ ] **Step 5: Run analyzer**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter analyze lib/src/infrastructure/codec/frame_codec.dart 2>&1 | tail -5
```

Expected: clean.

- [ ] **Step 6: Commit**

```bash
cd /Users/joel/git/neutrinographics/gossip
git add packages/gossip_bluey/lib/src/infrastructure/codec/frame_codec.dart \
        packages/gossip_bluey/test/infrastructure/codec/frame_codec_test.dart
git commit -m "feat(gossip_bluey): FrameDecoder is a state machine with magic-prefix recovery

Decoder no longer throws FormatException; corruption is reported via
FrameFeedResult.bytesDiscarded so the application layer can record a
metric and log without tearing down the connection.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Add `BlueyMetrics.recordFrameRecovery`

**Files:**
- Modify: `packages/gossip_bluey/lib/src/application/observability/bluey_metrics.dart`
- Modify: `packages/gossip_bluey/test/application/observability/bluey_metrics_test.dart`

- [ ] **Step 1: Add failing test**

In `packages/gossip_bluey/test/application/observability/bluey_metrics_test.dart`, add a new test inside the existing `group('BlueyMetrics', ...)`:

```dart
    test('recordFrameRecovery accumulates count and discarded byte total', () {
      final m = BlueyMetrics();
      expect(m.frameRecoveries, equals(0));
      expect(m.bytesDiscarded, equals(0));

      m.recordFrameRecovery(7);
      m.recordFrameRecovery(13);

      expect(m.frameRecoveries, equals(2));
      expect(m.bytesDiscarded, equals(20));
    });
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/application/observability/bluey_metrics_test.dart 2>&1 | tail -8
```

Expected: FAIL — `frameRecoveries`, `bytesDiscarded`, `recordFrameRecovery` not defined.

- [ ] **Step 3: Add the counter to `BlueyMetrics`**

In `packages/gossip_bluey/lib/src/application/observability/bluey_metrics.dart`, add the field, getter, and method (place them next to the other byte/frame counters for cohesion):

```dart
/// Counters for monitoring `BlueyTransport` health and throughput.
class BlueyMetrics {
  int _connectedPeerCount = 0;
  int _totalConnectionsEstablished = 0;
  int _totalConnectionsFailed = 0;
  int _totalBytesSent = 0;
  int _totalBytesReceived = 0;
  int _totalMessagesSent = 0;
  int _totalMessagesReceived = 0;
  int _totalFramesSent = 0;
  int _totalFramesReceived = 0;
  int _frameRecoveries = 0;
  int _bytesDiscarded = 0;

  int get connectedPeerCount => _connectedPeerCount;
  int get totalConnectionsEstablished => _totalConnectionsEstablished;
  int get totalConnectionsFailed => _totalConnectionsFailed;
  int get totalBytesSent => _totalBytesSent;
  int get totalBytesReceived => _totalBytesReceived;
  int get totalMessagesSent => _totalMessagesSent;
  int get totalMessagesReceived => _totalMessagesReceived;
  int get totalFramesSent => _totalFramesSent;
  int get totalFramesReceived => _totalFramesReceived;
  int get frameRecoveries => _frameRecoveries;
  int get bytesDiscarded => _bytesDiscarded;

  void setConnectedPeerCount(int n) => _connectedPeerCount = n;
  void recordConnectionEstablished() => _totalConnectionsEstablished++;
  void recordConnectionFailed() => _totalConnectionsFailed++;
  void recordBytesSent(int n) => _totalBytesSent += n;
  void recordBytesReceived(int n) => _totalBytesReceived += n;
  void recordMessageSent() => _totalMessagesSent++;
  void recordMessageReceived() => _totalMessagesReceived++;
  void recordFrameSent() => _totalFramesSent++;
  void recordFrameReceived() => _totalFramesReceived++;

  /// Records a frame-decoder corruption recovery event. [bytesDiscarded]
  /// is the number of bytes the decoder skipped while scanning for the
  /// next valid frame magic; non-zero indicates a probable lost write.
  void recordFrameRecovery(int bytesDiscarded) {
    _frameRecoveries++;
    _bytesDiscarded += bytesDiscarded;
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/application/observability/bluey_metrics_test.dart 2>&1 | tail -8
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/joel/git/neutrinographics/gossip
git add packages/gossip_bluey/lib/src/application/observability/bluey_metrics.dart \
        packages/gossip_bluey/test/application/observability/bluey_metrics_test.dart
git commit -m "feat(gossip_bluey): BlueyMetrics.recordFrameRecovery for corruption-recovery observability

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Update `ConnectionService._onPortEvent` to handle `FrameFeedResult`

`ConnectionService` currently calls `decoder.feed(data)` inside a `try/catch FormatException` and disconnects on corruption. After Tasks 1–3, `feed` returns a `FrameFeedResult` and never throws. Update the handler.

**Files:**
- Modify: `packages/gossip_bluey/lib/src/application/services/connection_service.dart`
- Modify: `packages/gossip_bluey/test/application/services/connection_service_test.dart`

- [ ] **Step 1: Add failing tests**

In `packages/gossip_bluey/test/application/services/connection_service_test.dart`, add the following tests inside the existing `group('ConnectionService', ...)` (place them after the existing decoder/data-related tests):

```dart
    test(
      'frame recovery does not disconnect; logs and increments metric',
      () async {
        final network = FakeBlueyNetwork();
        final localPort = FakeBlueyPort(localNodeId: localId, network: network);
        final remotePort = FakeBlueyPort(
          localNodeId: remoteId,
          network: network,
        );
        final metrics = BlueyMetrics();
        final svc = ConnectionService(
          localNodeId: localId,
          port: localPort,
          registry: ConnectionRegistry(),
          metrics: metrics,
          serviceUuid: serviceUuid,
        );
        final logs = <_LogEntry>[];
        ConnectionService(
          // dummy disposed below; structured this way so we can read svc's
          // own onLog. Instead, register onLog on the actual svc:
          localNodeId: localId,
          port: localPort,
          registry: ConnectionRegistry(),
          metrics: BlueyMetrics(),
          serviceUuid: serviceUuid,
          onLog: (level, msg, [e, st]) => logs.add(_LogEntry(level, msg)),
        ).dispose();
        // (the line above is a placeholder — the real onLog wiring is below)

        // ... fixture setup omitted for brevity; the actual implementation
        // of this test in the plan uses the simpler form below ...
        expect(true, isTrue);
      },
      skip: 'replaced below — see real test',
    );
```

(Discard the above stub; here's the **actual** test to add — replace any earlier draft with this:)

```dart
    test(
      'frame recovery: PortPeerData with corrupted bytes does not disconnect '
      'and increments BlueyMetrics.frameRecoveries',
      () async {
        final network = FakeBlueyNetwork();
        final localPort = FakeBlueyPort(localNodeId: localId, network: network);
        final remotePort = FakeBlueyPort(
          localNodeId: remoteId,
          network: network,
        );
        final metrics = BlueyMetrics();
        final logs = <String>[];
        final svc = ConnectionService(
          localNodeId: localId,
          port: localPort,
          registry: ConnectionRegistry(),
          metrics: metrics,
          serviceUuid: serviceUuid,
          onLog: (level, msg, [e, st]) {
            if (level == LogLevel.warning) logs.add(msg);
          },
        );

        await localPort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'Local',
          localNodeId: localId,
        );
        await remotePort.connect(localId);
        await Future<void>.delayed(Duration.zero);
        expect(svc.registry.contains(remoteId), isTrue);

        // Inject 7 bytes of garbage followed by a valid frame for a
        // 3-byte payload. The decoder should discard the garbage,
        // emit the message, and the service should record the
        // recovery.
        const magic = [0x47, 0x53, 0x50, 0x31];
        final payload = [0xAA, 0xBB, 0xCC];
        final corruptedThenValid = Uint8List.fromList([
          0xDE, 0xAD, 0xBE, 0xEF, 0x12, 0x34, 0x56,         // 7 garbage
          ...magic,
          0x00, 0x00, 0x00, payload.length,
          ...payload,
        ]);

        // Synthesize the inbound data event by pushing it onto the
        // remote port's events stream targeted at us — easiest: have
        // the remote-as-central send via sendData. The fake's sendData
        // emits PortPeerData(localNodeId, bytes) on local's events.
        await remotePort.sendData(localId, corruptedThenValid);
        await Future<void>.delayed(Duration.zero);

        // Connection still up.
        expect(svc.registry.contains(remoteId), isTrue);
        // Recovery metric incremented with the right count.
        expect(metrics.frameRecoveries, equals(1));
        expect(metrics.bytesDiscarded, equals(7));
        // A warning was logged.
        expect(logs, isNotEmpty);
        expect(logs.first, contains('discarded 7 bytes'));

        await svc.dispose();
        await remotePort.dispose();
      },
    );
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/application/services/connection_service_test.dart --plain-name "frame recovery" 2>&1 | tail -15
```

Expected: FAIL — current handler throws `FormatException` is gone (after Task 3), so the new contract isn't met yet; or fails because `metrics.frameRecoveries` is never incremented.

- [ ] **Step 3: Update the `PortPeerData` handler**

In `packages/gossip_bluey/lib/src/application/services/connection_service.dart`, replace the existing `PortPeerData` case (currently has the `try/catch FormatException` and `unawaited(port.disconnect(nodeId))`):

```dart
      case PortPeerData(:final nodeId, :final data):
        final decoder = _decoders[nodeId];
        if (decoder == null) {
          // Data from a peer we don't know about — ignore.
          return;
        }
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
          _incoming.add(IncomingMessage(
            sender: nodeId,
            bytes: m,
            receivedAt: _clock.now(),
          ));
        }
```

Remove any `on FormatException` block, the `_errors.add(FrameDecodeError(...))` call, and the `unawaited(port.disconnect(nodeId))` from this path. The `FrameDecodeError` type may have other call sites; do **not** delete the type itself in this task.

If the file has an unused import for `FrameDecodeError` after the edit, leave it — Task 7 (final verification) catches and cleans up.

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/application/services/connection_service_test.dart --plain-name "frame recovery" 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 5: Run the full ConnectionService test file**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/application/services/connection_service_test.dart 2>&1 | tail -5
```

Expected: PASS for all existing tests (none should depend on the disconnect-on-corruption behavior).

- [ ] **Step 6: Commit**

```bash
cd /Users/joel/git/neutrinographics/gossip
git add packages/gossip_bluey/lib/src/application/services/connection_service.dart \
        packages/gossip_bluey/test/application/services/connection_service_test.dart
git commit -m "feat(gossip_bluey): ConnectionService records frame recovery instead of disconnecting

The PortPeerData handler now consumes FrameFeedResult: corruption is
logged at warning level and recorded via metrics.recordFrameRecovery;
the connection stays up. Gossip's anti-entropy will re-sync any
messages lost in the corruption window.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: iOS-aware `chunkSizeFor`

**Files:**
- Modify: `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart`

This adapter wraps the real bluey library, so it isn't unit-tested in isolation. Verification is via the analyzer + the existing integration tests + hardware run.

- [ ] **Step 1: Update `chunkSizeFor`**

In `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart`, replace the existing `chunkSizeFor` method (currently around line 305) with:

```dart
  /// Default ATT payload when MTU is unknown (BLE 4.0 default MTU 23
  /// minus 3-byte ATT header).
  static const int _defaultChunkSize = 20;

  /// Conservative fallback chunk size on iOS when the platform-
  /// negotiated MTU isn't surfaced through bluey's Connection.mtu
  /// (always 23 on iOS — see bluey backlog I325). 100 bytes is well
  /// below the typical iOS maximumWriteValueLength minimum (158+ on
  /// iOS 13+) and is safe on all known hardware.
  ///
  /// TODO(I325): once bluey exposes Connection.maxWritePayload, drop
  /// this branch and use the new API directly.
  static const int _iosFallbackChunkSize = 100;

  /// BLE-default ATT MTU. iOS reports this from Connection.mtu even
  /// after auto-negotiating higher; we use it as a sentinel for "MTU
  /// unknown on iOS" and fall back to [_iosFallbackChunkSize].
  static const int _bleDefaultMtu = 23;

  @override
  int chunkSizeFor(NodeId nodeId) {
    final mtu = _mtuByNode[nodeId];
    if (mtu == null) return _defaultChunkSize;
    if (mtu == _bleDefaultMtu &&
        _bluey.capabilities.platformKind == bluey.PlatformKind.ios) {
      return _iosFallbackChunkSize;
    }
    final size = mtu - 3 - _safetyMargin;
    return size < _defaultChunkSize ? _defaultChunkSize : size;
  }
```

(Existing `_defaultChunkSize` and `_safetyMargin` constants stay where they are; the new `_iosFallbackChunkSize` and `_bleDefaultMtu` go alongside them. The placement above shows them grouped — replicate that grouping in the actual file by moving the existing `_defaultChunkSize` declaration if needed for cohesion.)

- [ ] **Step 2: Run analyzer + test suite**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter analyze 2>&1 | tail -5
flutter test 2>&1 | tail -3
```

Expected: analyzer clean; tests pass.

- [ ] **Step 3: Commit**

```bash
cd /Users/joel/git/neutrinographics/gossip
git add packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart
git commit -m "fix(gossip_bluey): use 100-byte chunks on iOS when MTU appears at default

iOS's CoreBluetooth auto-negotiates MTU but doesn't surface it through
bluey's Connection.mtu (it stays at 23 forever). Fall back to a
conservative 100-byte chunk size in that case, well below the typical
maximumWriteValueLength minimum on iOS 13+. Workaround until bluey
ships Connection.maxWritePayload (I325).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Add `chunkDropInjector` test hook + integration test

Defense-in-depth test that exercises the full corruption-recovery flow under the fake transport.

**Files:**
- Modify: `packages/gossip_bluey/test/fakes/fake_bluey_port.dart`
- Modify: `packages/gossip_bluey/test/application/services/connection_service_test.dart` (or a new integration-test file under `test/integration/`)

- [ ] **Step 1: Add the test hook to `FakeBlueyPort`**

In `packages/gossip_bluey/test/fakes/fake_bluey_port.dart`, near the other test hooks (the `Function?` fields), add:

```dart
  /// Test hook: when set and returns true for a payload, the fake
  /// silently drops it from `sendData`. Used to simulate a single
  /// dropped chunk on writes-without-response.
  bool Function(NodeId target, Uint8List data)? chunkDropInjector;
```

Then in the existing `sendData` method (currently delivers the bytes via `remote._events.add(PortPeerData(...))`), add the injector check at the top:

```dart
  @override
  Future<void> sendData(NodeId nodeId, Uint8List data) async {
    final remote = network.lookup(nodeId);
    if (remote == null ||
        (!_connectedAsCentral.contains(nodeId) &&
            !_connectedAsPeripheral.contains(nodeId))) {
      throw StateError('no connection to $nodeId');
    }
    if (chunkDropInjector?.call(nodeId, data) ?? false) {
      // Silently drop — simulates a write-without-response that was
      // never delivered. Returns success to the sender (matching real
      // BLE behaviour: writes-without-response have no ACK).
      return;
    }
    if (!remote._events.isClosed) {
      remote._events.add(PortPeerData(nodeId: localNodeId, data: data));
    }
  }
```

- [ ] **Step 2: Add the integration test**

In `packages/gossip_bluey/test/application/services/connection_service_test.dart`, add a new test inside the existing `group('ConnectionService', ...)`:

```dart
    test(
      'sustained traffic with one dropped chunk: connection persists, '
      'metric records the recovery, subsequent messages flow',
      () async {
        final network = FakeBlueyNetwork();
        final localPort = FakeBlueyPort(localNodeId: localId, network: network);
        final remotePort = FakeBlueyPort(
          localNodeId: remoteId,
          network: network,
        );
        final localMetrics = BlueyMetrics();
        final localSvc = ConnectionService(
          localNodeId: localId,
          port: localPort,
          registry: ConnectionRegistry(),
          metrics: localMetrics,
          serviceUuid: serviceUuid,
        );
        final remoteSvc = ConnectionService(
          localNodeId: remoteId,
          port: remotePort,
          registry: ConnectionRegistry(),
          metrics: BlueyMetrics(),
          serviceUuid: serviceUuid,
        );

        await localPort.startAdvertising(
          serviceUuid: serviceUuid,
          displayName: 'Local',
          localNodeId: localId,
        );
        await remotePort.connect(localId);
        await Future<void>.delayed(Duration.zero);

        // Set the fake's per-write payload size deliberately small so a
        // single message gets chunked across multiple writes — and we
        // can drop one of them mid-message.
        remotePort.chunkSize = 12;  // 8-byte header + 4 bytes payload per chunk

        // Capture incoming messages on the local side.
        final incoming = <IncomingMessage>[];
        final sub = localSvc.incomingMessages.listen(incoming.add);

        // Drop the first sendData chunk from remote → local for any
        // payload we send while the injector is enabled. After one drop,
        // disable.
        var dropsRemaining = 1;
        remotePort.chunkDropInjector = (_, __) {
          if (dropsRemaining > 0) {
            dropsRemaining--;
            return true;
          }
          return false;
        };

        // Send message 1 — its first chunk gets dropped, so the rest of
        // its bytes will look like garbage to local's decoder.
        await remoteSvc.sendGossipMessage(
          localId,
          Uint8List.fromList(List.generate(20, (i) => i)),
        );
        // Send message 2 — chunks are intact; the decoder should
        // discard the leftover misaligned bytes from message 1, find
        // message 2's magic, and emit it.
        await remoteSvc.sendGossipMessage(
          localId,
          Uint8List.fromList([0xCA, 0xFE, 0xBA, 0xBE]),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // Connection still up.
        expect(localSvc.registry.contains(remoteId), isTrue);
        // Message 2 was emitted; message 1 was lost.
        expect(incoming, hasLength(1));
        expect(incoming.first.bytes, equals([0xCA, 0xFE, 0xBA, 0xBE]));
        // Recovery was recorded.
        expect(localMetrics.frameRecoveries, greaterThanOrEqualTo(1));
        expect(localMetrics.bytesDiscarded, greaterThan(0));

        await sub.cancel();
        await localSvc.dispose();
        await remoteSvc.dispose();
        await remotePort.dispose();
      },
    );
```

- [ ] **Step 3: Run the integration test**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test test/application/services/connection_service_test.dart --plain-name "sustained traffic with one dropped chunk" 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 4: Run the full gossip_bluey suite**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter test 2>&1 | tail -5
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/joel/git/neutrinographics/gossip
git add packages/gossip_bluey/test/fakes/fake_bluey_port.dart \
        packages/gossip_bluey/test/application/services/connection_service_test.dart
git commit -m "test(gossip_bluey): chunkDropInjector + integration test for corruption recovery

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Final verification

- [ ] **Step 1: Run the full melos test suite**

```bash
cd /Users/joel/git/neutrinographics/gossip
melos run test 2>&1 | tail -8
```

Expected: SUCCESS across all packages.

- [ ] **Step 2: Run melos analyze**

```bash
cd /Users/joel/git/neutrinographics/gossip/packages/gossip_bluey
flutter analyze 2>&1 | tail -3
```

Expected: `No issues found!`. If any imports got orphaned by Task 5's removal of the `FormatException`/`FrameDecodeError` path, prune them now and amend the commit.

- [ ] **Step 3: Run melos format**

```bash
cd /Users/joel/git/neutrinographics/gossip
melos run format 2>&1 | tail -5
```

If any files were reformatted:

```bash
git status
git add -A
git commit -m "chore: melos format

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 4: Smoke-build gossip_chat**

```bash
cd /Users/joel/git/neutrinographics/gossip/examples/gossip_chat
flutter analyze 2>&1 | tail -5
```

Expected: clean (or only pre-existing unrelated warnings).

- [ ] **Step 5: Hardware verification (manual)**

Reproduce the failing scenario from the prior hardware run:

1. Install the new gossip_chat build on Android + iOS.
2. Both devices launch gossip_chat, join the same group.
3. Send messages in both directions (Android → iOS, iOS → Android).
4. **Run for ≥10 minutes** of active typing/messaging.
5. Watch each device's diagnostic log.

**Pass criteria:**
- No `Frame decode error: ... exceeds max ...` followed by `Peer disconnected:`.
- The connection stays up for the full observation window.
- `BlueyMetrics.frameRecoveries` may report a non-zero value (occasional drops still happen, just bounded). That's expected. Each recovery should correspond to a warning log line.
- Gossip-level message delivery may drop a few percent on corruption events — re-sync via anti-entropy should cover within a second or two.

**Fail criteria:**
- Connection still tears down. Re-investigate.
- `frameRecoveries` climbing rapidly (≥1/second). Indicates the chunk-size workaround isn't sufficient on the hardware in question; may need to reconsider option B (writes-with-response) or a smaller iOS fallback chunk.

---

## Self-Review

**Spec coverage:**
- Magic prefix `0x47535031` in encoded frames → Task 1 ✓
- `FrameFeedResult` value type → Task 2 ✓
- Decoder state machine `SEEKING_MAGIC` → `READING_LENGTH` → `READING_PAYLOAD` → Task 3 ✓
- Decoder skips garbage and reports `bytesDiscarded` → Task 3 step 1 (tests) and step 3 (impl) ✓
- Buffer cap on garbage stream → Task 3 (`_seekingBufferCap = 64 KB`) and corresponding test ✓
- Implausible length triggers re-scan, not exception → Task 3 ✓
- iOS-aware chunk size fallback → Task 6 ✓
- `BlueyMetrics.recordFrameRecovery` → Task 4 ✓
- `ConnectionService` records the metric, logs warning, no longer disconnects → Task 5 ✓
- `chunkDropInjector` test hook → Task 7 step 1 ✓
- Integration test for sustained-traffic recovery → Task 7 step 2 ✓
- Hardware verification → Task 8 step 5 ✓

**Placeholder scan:** The only `TODO` in the plan is `TODO(I325)` inside the chunkSizeFor implementation, which is a deliberate code marker pointing at the bluey upstream ticket — it's the right kind of TODO and stays.

**Type consistency:**
- `FrameFeedResult { messages, bytesDiscarded }` defined in Task 2, used in Task 3 (`feed` return), Task 5 (consumed by `_onPortEvent`).
- `kMagicBytes`, `kMagicSize`, `kFrameHeaderSize` defined in Task 1, used in Task 3.
- `BlueyMetrics.frameRecoveries`, `BlueyMetrics.bytesDiscarded`, `BlueyMetrics.recordFrameRecovery(int)` defined in Task 4, used in Task 5 and Task 7.
- `chunkDropInjector` defined in Task 7 step 1, used in Task 7 step 2.

No spec requirement is missing a task. Plan is internally consistent and ready to execute.
