import '../../domain/value_objects/node_id.dart';
import '../../domain/value_objects/channel_id.dart';
import '../../domain/value_objects/stream_id.dart';
import '../../domain/value_objects/version_vector.dart';
import 'protocol_message.dart';

/// Request for missing entries in a specific stream.
///
/// [DeltaRequest] asks a peer to send entries that the requester doesn't
/// have yet. The [since] version vector specifies what the requester already
/// has, allowing the recipient to compute the delta (difference) and send
/// only missing entries.
///
/// This is step 3 of the 4-step anti-entropy protocol, sent after comparing
/// digests to identify gaps.
///
/// Message flow:
/// ```
/// Node A → [DigestRequest] → Node B
/// Node B → [DigestResponse] → Node A
/// Node A → [DeltaRequest(since=VV)] → Node B  ← This message
/// Node B → [DeltaResponse(entries)] → Node A
/// ```
class DeltaRequest extends ProtocolMessage {
  /// The channel containing the stream.
  final ChannelId channelId;

  /// The stream to synchronize.
  final StreamId streamId;

  /// Version vector indicating what the sender already has.
  ///
  /// The recipient responds with entries where sequence > since[author]
  /// for each author. This efficiently identifies only the missing entries.
  final VersionVector since;

  const DeltaRequest({
    required NodeId sender,
    required this.channelId,
    required this.streamId,
    required this.since,
  }) : super(sender);
}
