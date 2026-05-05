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

/// Reassembles framed bytes (4-byte BE length prefix + payload) arriving
/// in arbitrary chunk sizes.
///
/// Stateful: keep one decoder per connection. Surplus bytes from one frame
/// remain buffered for the next.
class FrameDecoder {
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  int? _expectedLength;

  /// Feeds [chunk] into the decoder and returns any complete payloads
  /// available now. Throws [FormatException] if the length prefix
  /// exceeds [kMaxFramePayload].
  List<Uint8List> feed(Uint8List chunk) {
    _buffer.add(chunk);
    final out = <Uint8List>[];

    while (true) {
      if (_expectedLength == null) {
        if (_buffer.length < kLengthPrefixSize) break;
        final all = _buffer.takeBytes();
        final view = ByteData.view(all.buffer, all.offsetInBytes);
        final len = view.getUint32(0, Endian.big);
        if (len > kMaxFramePayload) {
          throw FormatException(
            'frame length $len exceeds max $kMaxFramePayload',
          );
        }
        _expectedLength = len;
        // Re-add bytes after the prefix.
        if (all.length > kLengthPrefixSize) {
          _buffer.add(all.sublist(kLengthPrefixSize));
        }
        continue;
      }

      if (_buffer.length < _expectedLength!) break;
      final all = _buffer.takeBytes();
      final payload = Uint8List.sublistView(all, 0, _expectedLength!);
      out.add(Uint8List.fromList(payload));
      final remainder = all.sublist(_expectedLength!);
      _expectedLength = null;
      if (remainder.isNotEmpty) {
        _buffer.add(remainder);
      }
    }

    return out;
  }
}
