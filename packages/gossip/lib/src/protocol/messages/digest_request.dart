import '../../domain/value_objects/node_id.dart';
import '../values/channel_digest.dart';
import 'protocol_message.dart';

/// Anti-entropy request containing sender's sync state digests.
///
/// [DigestRequest] initiates the gossip anti-entropy protocol. The sender
/// includes digests (compact summaries) of its current sync state for each
/// channel and stream. The recipient uses these digests to:
/// 1. Identify which entries the sender is missing
/// 2. Respond with its own digests via [DigestResponse]
///
/// Digests contain version vectors summarizing the highest sequence number
/// seen per author, enabling efficient delta computation without transmitting
/// entire logs.
///
/// Message flow (anti-entropy round):
/// ```
/// Node A → [DigestRequest(my digests)] → Node B
/// Node B → [DigestResponse(my digests)] → Node A
/// Node A → [DeltaRequest(I need X-Y)] → Node B
/// Node B → [DeltaResponse(entries X-Y)] → Node A
/// ```
class DigestRequest extends ProtocolMessage {
  /// Compact summaries of sender's sync state per channel/stream.
  ///
  /// Each digest contains version vectors indicating what the sender
  /// has already received. The recipient uses this to identify missing entries.
  final List<ChannelDigest> digests;

  const DigestRequest({required NodeId sender, required this.digests})
    : super(sender);
}
