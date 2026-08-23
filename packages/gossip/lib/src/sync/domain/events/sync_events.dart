import 'package:gossip/src/shared/domain/events/domain_event.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/sync/domain/value_objects/compaction_result.dart';

/// Sealed family root for domain events emitted by the sync context
/// (channels, streams, and entry synchronization).
///
/// Every sync-context event extends [SyncEvent], which itself extends the
/// shared [DomainEvent] base. Consumers of the public `Stream<DomainEvent>`
/// are unaffected by this split — they still see every event, regardless of
/// which context family it belongs to.
sealed class SyncEvent extends DomainEvent {
  const SyncEvent({required super.occurredAt});
}

// ─────────────────────────────────────────────────────────────
// Channel Events
// ─────────────────────────────────────────────────────────────

/// Emitted when a new channel is created.
///
/// Fired when: `Channel` aggregate is instantiated and persisted.
final class ChannelCreated extends SyncEvent {
  final ChannelId channelId;

  const ChannelCreated(this.channelId, {required super.occurredAt});
}

/// Emitted when a channel is removed.
///
/// Fired when: `Channel` aggregate is deleted from persistence.
final class ChannelRemoved extends SyncEvent {
  final ChannelId channelId;

  const ChannelRemoved(this.channelId, {required super.occurredAt});
}

/// Emitted when a peer is added as a member of a channel.
///
/// Fired when: `Channel.addMember` successfully adds a new member.
/// Note: Membership is local metadata and is NOT enforced by the gossip
/// protocol. Applications can use membership for UI or application-level
/// access control.
final class MemberAdded extends SyncEvent {
  final ChannelId channelId;
  final NodeId memberId;

  const MemberAdded(this.channelId, this.memberId, {required super.occurredAt});
}

/// Emitted when a member is removed from a channel.
///
/// Fired when: `Channel.removeMember` removes an existing member.
/// This is a LOCAL operation only - the peer can still sync entries if they
/// have the channel locally. Membership is not enforced by the gossip protocol.
final class MemberRemoved extends SyncEvent {
  final ChannelId channelId;
  final NodeId memberId;

  const MemberRemoved(
    this.channelId,
    this.memberId, {
    required super.occurredAt,
  });
}

/// Emitted when a new stream is created within a channel.
///
/// Fired when: `Channel.createStream` successfully adds a new stream.
final class StreamCreated extends SyncEvent {
  final ChannelId channelId;
  final StreamId streamId;

  const StreamCreated(
    this.channelId,
    this.streamId, {
    required super.occurredAt,
  });
}

/// Emitted when a local entry is appended to a stream.
///
/// Fired when: `ChannelService.appendEntry` successfully appends a
/// locally-authored entry. This is for entries created on this node, not
/// received from peers.
final class EntryAppended extends SyncEvent {
  final ChannelId channelId;
  final StreamId streamId;
  final LogEntry entry;

  const EntryAppended(
    this.channelId,
    this.streamId,
    this.entry, {
    required super.occurredAt,
  });
}

/// Emitted when entries from a peer are merged into a stream.
///
/// Fired when: the coordinator's merge fan-out
/// (`Coordinator._handleEntriesMerged`) constructs this after entries are
/// merged during anti-entropy synchronization. The [newVersion] reflects
/// the stream's updated version vector after the merge.
final class EntriesMerged extends SyncEvent {
  final ChannelId channelId;
  final StreamId streamId;
  final List<LogEntry> entries;
  final VersionVector newVersion;

  /// True if any entry in this batch was inserted before the stream's
  /// previous tail entry (by HLC order). When true, materializers must
  /// rebuild from scratch rather than incrementally folding.
  final bool containsOutOfOrderEntries;

  const EntriesMerged(
    this.channelId,
    this.streamId,
    this.entries,
    this.newVersion, {
    this.containsOutOfOrderEntries = false,
    required super.occurredAt,
  });
}

/// Emitted when a stream is compacted to free storage space.
///
/// Currently never emitted — the compaction pipeline does not yet fire
/// this event; retained pending an emit-or-remove decision.
final class StreamCompacted extends SyncEvent {
  final ChannelId channelId;
  final StreamId streamId;
  final CompactionResult result;

  const StreamCompacted(
    this.channelId,
    this.streamId,
    this.result, {
    required super.occurredAt,
  });
}

/// Emitted when the out-of-order buffer overflows for an author.
///
/// Currently never emitted — the compaction pipeline does not yet fire
/// this event; retained pending an emit-or-remove decision.
final class BufferOverflowOccurred extends SyncEvent {
  final ChannelId channelId;
  final StreamId streamId;
  final NodeId author;
  final int droppedCount;

  const BufferOverflowOccurred(
    this.channelId,
    this.streamId,
    this.author,
    this.droppedCount, {
    required super.occurredAt,
  });
}

/// Event for applications to emit when rejecting entries from non-members.
///
/// Note: The gossip protocol does NOT filter entries by membership - this is
/// intentional. Applications that want to enforce membership-based access
/// control should do so at the application layer and can emit this event
/// for observability when rejecting entries.
final class NonMemberEntriesRejected extends SyncEvent {
  final ChannelId channelId;
  final StreamId streamId;
  final int rejectedCount;
  final Set<NodeId> unknownAuthors;

  const NonMemberEntriesRejected(
    this.channelId,
    this.streamId,
    this.rejectedCount,
    this.unknownAuthors, {
    required super.occurredAt,
  });
}
