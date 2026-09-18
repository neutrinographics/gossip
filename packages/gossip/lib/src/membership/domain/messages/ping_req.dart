import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/interfaces/protocol_message.dart';

/// A relay request from the retired indirect-probing protocol.
///
/// Still decoded because deployed peers on older builds send it; this
/// library never sends one and ignores those it receives. The type stays
/// in the wire vocabulary (type byte 2, and the `pingreq` conformance
/// vectors) until the next dialect revision retires the encoder — see the
/// retirement decision record in `docs/superpowers/specs/`.
class PingReq extends ProtocolMessage {
  /// Sequence number the requester would have matched a forwarded Ack to.
  final int sequence;

  /// The node the requester wanted probed on its behalf.
  final NodeId target;

  const PingReq({
    required NodeId sender,
    required this.sequence,
    required this.target,
  }) : super(sender);
}
