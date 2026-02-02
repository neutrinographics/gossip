import '../../domain/value_objects/node_id.dart';

/// Base class for all wire protocol messages.
///
/// [ProtocolMessage] is the parent of all messages exchanged between peers
/// over the network. The protocol includes two categories of messages:
/// - **SWIM messages**: Failure detection (Ping, Ack, PingReq)
/// - **Gossip messages**: Anti-entropy (DigestRequest, DigestResponse, DeltaRequest, DeltaResponse)
///
/// Every message includes the sender's [NodeId] for peer identification and
/// routing responses.
///
/// Messages are serialized to bytes by [ProtocolCodec] using a compact format:
/// - Byte 0: Message type identifier
/// - Remaining bytes: JSON-encoded message fields
abstract class ProtocolMessage {
  /// The node that sent this message.
  final NodeId sender;

  const ProtocolMessage(this.sender);
}
