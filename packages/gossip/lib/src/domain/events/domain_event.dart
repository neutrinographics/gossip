import '../value_objects/channel_id.dart';
import '../value_objects/log_entry.dart';
import '../value_objects/node_id.dart';
import '../value_objects/stream_id.dart';
import '../value_objects/version_vector.dart';
import '../results/compaction_result.dart';
import '../errors/sync_error.dart';

/// Base class for all domain events emitted by aggregates.
///
/// Domain events represent state changes that have already occurred within
/// the domain. Applications can observe these events to:
/// - Update read models or projections
/// - Trigger side effects (logging, notifications)
/// - Maintain event sourcing audit trails
/// - Synchronize with external systems
///
/// All events include an [occurredAt] timestamp indicating when the event
/// happened in domain time.
sealed class DomainEvent {
  /// The timestamp when this event occurred.
  final DateTime occurredAt;

  const DomainEvent({required this.occurredAt});
}

// ─────────────────────────────────────────────────────────────
// Peer Events
// ─────────────────────────────────────────────────────────────

/// Reachability status for a peer in SWIM failure detection.
///
/// Lifecycle progression:
/// - **reachable**: Peer responds to probes (healthy)
/// - **suspected**: Probe failed, indirect probe in progress
/// - **unreachable**: Confirmed failed (direct and indirect probes failed)
enum PeerStatus { reachable, suspected, unreachable }

/// Emitted when a new peer is added to the peer registry.
///
/// Fired when: [PeerRegistry.addPeer] successfully adds a new peer.
final class PeerAdded extends DomainEvent {
  final NodeId peerId;

  const PeerAdded(this.peerId, {required super.occurredAt});
}

/// Emitted when a peer is removed from the peer registry.
///
/// Fired when: [PeerRegistry.removePeer] removes an existing peer.
final class PeerRemoved extends DomainEvent {
  final NodeId peerId;

  const PeerRemoved(this.peerId, {required super.occurredAt});
}

/// Emitted when a peer's reachability status changes.
///
/// Fired when: [PeerRegistry.updatePeerStatus] changes a peer's status.
/// Common transitions:
/// - reachable → suspected (probe failure)
/// - suspected → unreachable (indirect probe also failed)
/// - suspected → reachable (peer recovered or refuted suspicion)
final class PeerStatusChanged extends DomainEvent {
  final NodeId peerId;
  final PeerStatus oldStatus;
  final PeerStatus newStatus;

  const PeerStatusChanged(
    this.peerId,
    this.oldStatus,
    this.newStatus, {
    required super.occurredAt,
  });
}

/// Emitted when an operation on a peer is skipped because the peer is not found.
///
/// Fired when: Operations like [updatePeerStatus], [updatePeerContact], etc.
/// are called for a peer that doesn't exist in the registry. This is for
/// observability only - not an error, just a trace event.
final class PeerOperationSkipped extends DomainEvent {
  final NodeId peerId;
  final String operation;

  const PeerOperationSkipped(
    this.peerId,
    this.operation, {
    required super.occurredAt,
  });
}

// ─────────────────────────────────────────────────────────────
// Channel Events
// ─────────────────────────────────────────────────────────────

/// Emitted when a new channel is created.
///
/// Fired when: [Channel] aggregate is instantiated and persisted.
final class ChannelCreated extends DomainEvent {
  final ChannelId channelId;

  const ChannelCreated(this.channelId, {required super.occurredAt});
}

/// Emitted when a channel is removed.
///
/// Fired when: [Channel] aggregate is deleted from persistence.
final class ChannelRemoved extends DomainEvent {
  final ChannelId channelId;

  const ChannelRemoved(this.channelId, {required super.occurredAt});
}

/// Emitted when a peer is added as a member of a channel.
///
/// Fired when: [Channel.addMember] successfully adds a new member.
/// Note: Membership is local metadata and is NOT enforced by the gossip
/// protocol. Applications can use membership for UI or application-level
/// access control.
final class MemberAdded extends DomainEvent {
  final ChannelId channelId;
  final NodeId memberId;

  const MemberAdded(this.channelId, this.memberId, {required super.occurredAt});
}

/// Emitted when a member is removed from a channel.
///
/// Fired when: [Channel.removeMember] removes an existing member.
/// This is a LOCAL operation only - the peer can still sync entries if they
/// have the channel locally. Membership is not enforced by the gossip protocol.
final class MemberRemoved extends DomainEvent {
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
/// Fired when: [Channel.addStream] successfully adds a new stream.
final class StreamCreated extends DomainEvent {
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
/// Fired when: [EntryRepository.append] successfully adds a locally-authored entry.
/// This is for entries created on this node, not received from peers.
final class EntryAppended extends DomainEvent {
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
/// Fired when: [EntryRepository.appendAll] successfully merges received entries
/// during anti-entropy synchronization. The [newVersion] reflects the
/// stream's updated version vector after the merge.
final class EntriesMerged extends DomainEvent {
  final ChannelId channelId;
  final StreamId streamId;
  final List<LogEntry> entries;
  final VersionVector newVersion;

  const EntriesMerged(
    this.channelId,
    this.streamId,
    this.entries,
    this.newVersion, {
    required super.occurredAt,
  });
}

/// Emitted when a stream is compacted to free storage space.
///
/// Fired when: [EntryRepository.compact] applies retention policies and removes
/// old entries. The [result] contains statistics about what was removed.
final class StreamCompacted extends DomainEvent {
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
/// Fired when: [EntryRepository] receives entries that exceed buffer limits
/// defined in [StreamConfig]. Entries are dropped to prevent memory
/// exhaustion from malicious or buggy peers.
final class BufferOverflowOccurred extends DomainEvent {
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
final class NonMemberEntriesRejected extends DomainEvent {
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

// ─────────────────────────────────────────────────────────────
// Error Events
// ─────────────────────────────────────────────────────────────

/// Emitted when a synchronization error occurs.
///
/// Fired when: Operations encounter recoverable errors during sync
/// (e.g., malformed messages, validation failures). Applications can
/// observe these to log errors or implement retry policies.
final class SyncErrorOccurred extends DomainEvent {
  final SyncError error;

  const SyncErrorOccurred(this.error, {required super.occurredAt});
}
