import 'dart:typed_data';
import 'package:gossip/src/protocol/messages/protocol_message.dart'; // path updated in Task 5's move

/// Wire codec seam (Part 2 spec): each context implements this for its OWN
/// message family and answers null for foreign type bytes.
abstract interface class MessageCodec {
  Uint8List encode(ProtocolMessage message);

  /// Returns null when [bytes] carries a type byte owned by a *known
  /// sibling* context ("not mine" — routine traffic sharing the transport,
  /// e.g. membership frames arriving at the sync codec). Throws when
  /// [bytes] is empty, when the type byte belongs to NO known context
  /// (genuinely corrupt — implementations check this via
  /// `WireTypes.known`), or on a malformed frame of its own family —
  /// preserving `ProtocolCodec`'s current error behavior in every case.
  ProtocolMessage? decode(Uint8List bytes);
}
