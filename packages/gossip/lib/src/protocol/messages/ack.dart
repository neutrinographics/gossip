import '../../domain/value_objects/node_id.dart';
import 'protocol_message.dart';

/// SWIM acknowledgment response to a direct probe.
///
/// [Ack] is sent in response to a [Ping] message to confirm that the sender
/// is alive and reachable. The sequence number matches the original [Ping]
/// to correlate the response.
///
/// Receiving an [Ack] resets the target's failed probe count and confirms
/// reachability status.
///
/// Message flow:
/// ```
/// Prober → [Ping(seq=1)] → Target
/// Target → [Ack(seq=1)] → Prober
/// ```
class Ack extends ProtocolMessage {
  /// Sequence number matching the original Ping.
  ///
  /// Used to correlate this acknowledgment with the corresponding probe
  /// request, especially when multiple probes are in flight.
  final int sequence;

  const Ack({required NodeId sender, required this.sequence}) : super(sender);
}
