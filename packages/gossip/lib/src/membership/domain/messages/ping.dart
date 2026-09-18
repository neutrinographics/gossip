import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/interfaces/protocol_message.dart';

/// Direct probe message for failure detection.
///
/// [Ping] is sent periodically to a randomly selected peer to check if it's
/// still reachable. The target should respond with an Ack message containing
/// the same sequence number.
///
/// If no Ack is received within the timeout, the failure detector holds
/// the ping open for one more timeout (the grace window) before counting
/// a failure.
///
/// Message flow:
/// ```
/// Sender → [Ping(seq=1)] → Target
/// Target → [Ack(seq=1)] → Sender
/// ```
class Ping extends ProtocolMessage {
  /// Sequence number for matching with corresponding Ack.
  ///
  /// Used to correlate responses with requests when multiple probes are
  /// in flight simultaneously.
  final int sequence;

  const Ping({required NodeId sender, required this.sequence}) : super(sender);
}
