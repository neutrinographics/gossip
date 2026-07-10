import 'dart:typed_data';

/// Magic prefix for CONTROL frames, ASCII "GSP2". Data frames keep the
/// "GSP1" magic byte-for-byte unchanged; a receiver without GSP2 support
/// treats a control frame as garbage and scan-recovers past it (existing,
/// tested FrameDecoder behavior), so new→old control frames are harmlessly
/// ignored. No version negotiation needed.
const List<int> kControlMagicBytes = [0x47, 0x53, 0x50, 0x32];

/// Wire values for [ConnectionRejectedFrame.reason].
enum RejectionReason {
  /// The remote is at its connection cap.
  capacity(0x01);

  const RejectionReason(this.wire);

  final int wire;

  static RejectionReason? fromWire(int byte) {
    for (final r in RejectionReason.values) {
      if (r.wire == byte) return r;
    }
    return null;
  }
}

/// A decoded control frame. Currently only rejection exists; the sealed
/// hierarchy leaves room for future control types without another wire
/// format change.
sealed class ControlFrame {
  const ControlFrame();
}

/// "Your connection was rejected — close your link." Sent by a device
/// that cannot keep an inbound peripheral link (it has no per-client
/// peripheral disconnect API); the receiving central CAN close the link
/// and must do so (COR3-21).
final class ConnectionRejectedFrame extends ControlFrame {
  final RejectionReason reason;
  const ConnectionRejectedFrame(this.reason);
}

/// Wire type byte for [ConnectionRejectedFrame].
const int _kTypeConnectionRejected = 0x01;

/// Encodes/decodes GSP2 control frames.
///
/// Wire format mirrors GSP1: `[magic 4 bytes]["length" u32 BE][payload]`
/// where the payload is `[type u8][type-specific bytes]`. Control frames
/// are always sent as a single write well under any MTU, so [tryParse]
/// requires the input to be EXACTLY one frame — a prefix match with
/// trailing bytes is not a control frame.
abstract final class ControlFrameCodec {
  static Uint8List encodeRejection(RejectionReason reason) {
    const payloadLength = 2; // type + reason
    final bytes = Uint8List(kControlMagicBytes.length + 4 + payloadLength);
    bytes.setRange(0, kControlMagicBytes.length, kControlMagicBytes);
    ByteData.view(bytes.buffer, bytes.offsetInBytes)
        .setUint32(kControlMagicBytes.length, payloadLength, Endian.big);
    bytes[8] = _kTypeConnectionRejected;
    bytes[9] = reason.wire;
    return bytes;
  }

  /// Returns the decoded control frame when [data] is exactly one valid
  /// GSP2 frame, or null otherwise (including unknown type/reason bytes —
  /// forward compatibility demands unknowns be ignored, not errored).
  static ControlFrame? tryParse(Uint8List data) {
    const headerSize = 8; // magic + length
    if (data.length < headerSize + 1) return null;
    for (var i = 0; i < kControlMagicBytes.length; i++) {
      if (data[i] != kControlMagicBytes[i]) return null;
    }
    final declared = ByteData.view(data.buffer, data.offsetInBytes)
        .getUint32(kControlMagicBytes.length, Endian.big);
    if (data.length != headerSize + declared) return null;
    switch (data[headerSize]) {
      case _kTypeConnectionRejected:
        if (declared != 2) return null;
        final reason = RejectionReason.fromWire(data[headerSize + 1]);
        if (reason == null) return null;
        return ConnectionRejectedFrame(reason);
      default:
        return null;
    }
  }
}
