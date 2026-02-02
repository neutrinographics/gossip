import '../../domain/value_objects/node_id.dart';
import 'protocol_message.dart';

/// SWIM direct probe message for failure detection.
///
/// [Ping] is sent periodically to a randomly selected peer to check if it's
/// still reachable. The target should respond with an [Ack] message containing
/// the same sequence number.
///
/// If no [Ack] is received within the timeout period, the failure detector
/// initiates an indirect probe via [PingReq] to distinguish between target
/// failure and network partition.
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
