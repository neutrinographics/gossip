import 'dart:typed_data';

import 'handshake_codec.dart' show HandshakeCodec, MessageType, WireFormat;

/// Protocol-layer byte classification (ARCH3-3).
///
/// The ONLY place outside [HandshakeCodec] that may read the wire
/// layout. The application layer receives a message type value and never
/// touches byte offsets.
///
/// [MessageType] is a namespace of `static const int` wire values (not a
/// Dart `enum`), so [classify] returns `int`: the same value that was
/// previously read inline via `bytes[WireFormat.typeOffset]`. Callers
/// compare the result against the [MessageType] constants.
///
/// Precondition (matches the previous inline call site): `bytes` must be
/// non-empty. The caller (`ConnectionService`) already guards against
/// empty payloads before dispatch.
class WireDispatcher {
  int classify(Uint8List bytes) {
    // Moved verbatim from ConnectionService._onPayloadReceived's dispatch
    // site (bytes[WireFormat.typeOffset]) — no guard existed at that exact
    // line beyond the caller's pre-existing `bytes.isEmpty` check.
    return bytes[WireFormat.typeOffset];
  }
}
