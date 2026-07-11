/// Why a peer rejected an inbound connection via a GSP2 control frame.
///
/// Pure domain value object: no dependency on the wire codec. The
/// infrastructure layer (`ControlFrameCodec`) maps these to/from wire
/// bytes; the domain layer (`ConnectionRejectedByPeerError`) references
/// this type directly, never the codec.
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
