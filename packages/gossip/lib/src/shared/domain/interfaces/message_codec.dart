import 'dart:typed_data';
import '../../../protocol/messages/protocol_message.dart'; // path updated in Task 5's move

/// Wire codec seam (Part 2 spec): each context implements this for its OWN
/// message family and answers null for foreign type bytes.
abstract interface class MessageCodec {
  Uint8List encode(ProtocolMessage message);

  /// Returns null when [bytes] carries a type byte outside this codec's
  /// family ("not mine"); throws only on genuinely malformed frames of its
  /// own family (preserving ProtocolCodec's current error behavior).
  ProtocolMessage? decode(Uint8List bytes);
}
