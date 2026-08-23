import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';
import 'package:gossip/src/shared/domain/interfaces/protocol_message.dart';
import 'package:gossip/src/sync/domain/messages/delta_request.dart';

/// Anti-entropy response containing recipient's sync state digests.
///
/// [DigestResponse] is sent in reply to a `DigestRequest`. The recipient
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
