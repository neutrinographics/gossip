import '../../domain/value_objects/node_id.dart';
import '../../domain/value_objects/channel_id.dart';
import '../../domain/value_objects/stream_id.dart';
import '../../domain/value_objects/log_entry.dart';
import 'protocol_message.dart';

/// Response containing the requested missing entries.
///
/// [DeltaResponse] is sent in reply to a [DeltaRequest] and contains the
/// actual log entries that the requester is missing. The recipient computed
/// the delta by comparing the request's [since] version vector with its own
/// state and sends only entries the requester doesn't have.
///
/// This is step 4 (final step) of the anti-entropy protocol. Once received,
/// the requester merges these entries into its local store, completing the
/// sync round.
///
/// Message flow:
/// ```
/// Node A → [DigestRequest] → Node B
/// Node B → [DigestResponse] → Node A
/// Node A → [DeltaRequest(since=VV)] → Node B
/// Node B → [DeltaResponse(entries)] → Node A  ← This message
/// ```
class DeltaResponse extends ProtocolMessage {
  /// The channel containing the stream.
  final ChannelId channelId;

  /// The stream being synchronized.
  final StreamId streamId;

  /// The missing entries requested.
  ///
  /// Contains only entries where sequence > requester's version vector
  /// for each author. May be empty if the requester is already up-to-date.
  final List<LogEntry> entries;

  const DeltaResponse({
    required NodeId sender,
    required this.channelId,
    required this.streamId,
    required this.entries,
  }) : super(sender);
}
