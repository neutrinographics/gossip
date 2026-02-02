import '../../domain/value_objects/node_id.dart';
import 'protocol_message.dart';

/// SWIM indirect probe request via an intermediary peer.
///
/// [PingReq] is sent when a direct [Ping] to a target fails. The sender
/// asks an intermediary peer to probe the target on its behalf. This helps
/// distinguish between:
/// - **Target failure**: Neither direct nor indirect probe succeeds
/// - **Network partition**: Direct probe fails but indirect probe succeeds
///
/// The intermediary sends a [Ping] to the target and forwards any [Ack]
/// back to the original sender.
///
/// Message flow:
/// ```
/// Sender → [PingReq(target=C)] → Intermediary
/// Intermediary → [Ping] → Target
/// Target → [Ack] → Intermediary
/// Intermediary → [Ack] → Sender
/// ```
///
/// If the intermediary receives an [Ack] from the target, it proves the
/// target is alive and the sender has a network partition problem.
class PingReq extends ProtocolMessage {
  /// Sequence number for matching responses.
  final int sequence;

  /// The node to be probed indirectly.
  ///
  /// The intermediary (message recipient) should send a [Ping] to this
  /// node and forward any [Ack] back to the sender.
  final NodeId target;

  const PingReq({
    required NodeId sender,
    required this.sequence,
    required this.target,
  }) : super(sender);
}
