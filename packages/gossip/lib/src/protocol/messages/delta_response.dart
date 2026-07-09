import '../../domain/value_objects/node_id.dart';
import '../../domain/value_objects/channel_id.dart';
import '../../domain/value_objects/stream_id.dart';
import '../../domain/value_objects/log_entry.dart';
import '../../domain/value_objects/version_vector.dart';
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

  /// Whether the sender truncated this response to fit the size budget and
  /// still has more deliverable entries for this stream. When true, the
  /// requester immediately issues a continuation [DeltaRequest] with its
  /// advanced version vector, draining a backlog at link speed instead of
  /// one page per periodic round.
  final bool hasMore;

  /// Per-author compaction floor, for authors where the requester asked
  /// for entries the sender has compacted away (requested position below
  /// the sender's floor).
  ///
  /// A requester whose version vector is below an author's floor can never
  /// obtain the range (this sender pruned it by retention policy); it
  /// should adopt the floor as truncated history so the entries above it
  /// merge contiguously instead of being dropped forever. Empty when the
  /// requester's position is serviceable (the common case).
  final VersionVector floor;

  const DeltaResponse({
    required NodeId sender,
    required this.channelId,
    required this.streamId,
    required this.entries,
    this.hasMore = false,
    this.floor = VersionVector.empty,
  }) : super(sender);
}
