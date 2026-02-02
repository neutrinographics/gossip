import '../../domain/value_objects/node_id.dart';
import '../values/channel_digest.dart';
import 'protocol_message.dart';

/// Anti-entropy response containing recipient's sync state digests.
///
/// [DigestResponse] is sent in reply to a [DigestRequest]. The recipient
/// includes its own sync state digests, allowing the original requester to:
/// 1. Compare digests to identify which entries it's missing
/// 2. Send [DeltaRequest] messages for missing data
///
/// This is step 2 of the 4-step anti-entropy protocol.
///
/// Message flow:
/// ```
/// Node A → [DigestRequest] → Node B
/// Node B → [DigestResponse(my digests)] → Node A  ← This message
/// Node A → [DeltaRequest(I need entries)] → Node B
/// Node B → [DeltaResponse(here are entries)] → Node A
/// ```
class DigestResponse extends ProtocolMessage {
  /// Compact summaries of sender's sync state per channel/stream.
  ///
  /// The original requester compares these digests with its own to
  /// identify missing entries.
  final List<ChannelDigest> digests;

  const DigestResponse({required NodeId sender, required this.digests})
    : super(sender);
}
