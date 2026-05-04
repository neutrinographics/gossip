import 'dart:typed_data';

/// Maximum gossip message payload. Anything larger is rejected.
const int kMaxFramePayload = 32 * 1024;

/// Length prefix size in bytes (big-endian uint32).
const int kLengthPrefixSize = 4;

/// Encodes a gossip payload into MTU-sized chunks for sequential writes.
abstract final class FrameEncoder {
  /// Returns the chunks to write, in order.
  ///
  /// [mtuPayloadSize] is the per-chunk byte budget — i.e. the negotiated
  /// MTU minus 3 for the ATT header (and any safety margin the caller wants
  /// to subtract). Must be at least [kLengthPrefixSize] + 1.
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
    if (mtuPayloadSize <= kLengthPrefixSize) {
      throw ArgumentError.value(
        mtuPayloadSize,
        'mtuPayloadSize',
        'must exceed length prefix size ($kLengthPrefixSize)',
      );
    }

    final framed = Uint8List(kLengthPrefixSize + payload.length);
    final view = ByteData.view(framed.buffer);
    view.setUint32(0, payload.length, Endian.big);
    framed.setRange(kLengthPrefixSize, framed.length, payload);

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
