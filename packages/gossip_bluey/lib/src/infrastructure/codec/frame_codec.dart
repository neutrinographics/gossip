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

  /// True when the decoder sits exactly between frames: no partial frame
  /// bytes buffered. Used by the control-frame dispatch to ensure GSP2
  /// detection never fires on bytes that belong inside a GSP1 payload.
  bool get isAtFrameBoundary =>
      _state == _DecoderState.seekingMagic && _buffer.isEmpty;

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
            if (scan.length >= _seekingBufferCap) {
              // Way too much garbage — drop the oldest half.
              final dropTo = scan.length ~/ 2;
              totalDiscarded += dropTo;
              _buffer.clear();
              _buffer.add(scan.sublist(dropTo));
            }
            return FrameFeedResult(out, totalDiscarded);
          }
          if (matchIdx > 0) {
            totalDiscarded += matchIdx;
          }
          _buffer.clear();
          // Drop bytes up to and including the magic; re-add the
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
          // len == 0 is implausible too: the encoder rejects empty
          // payloads, so a zero-length frame is corruption — emitting an
          // empty message would blow up gossip deserialization.
          if (len > kMaxFramePayload || len == 0) {
            // Implausible length — the magic was a false positive.
            // Re-scan from ONE byte past the false magic's start: a real
            // magic may begin inside the bytes we consumed (e.g. a stray
            // "GSP1" in garbage immediately followed by a real frame,
            // whose own magic IS this false frame's "length" bytes).
            // Discarding all 4 length bytes would destroy that frame.
            totalDiscarded += 1;
            _buffer.clear();
            _buffer.add(
              Uint8List.fromList([...kMagicBytes.sublist(1), ...all]),
            );
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
