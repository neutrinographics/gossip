import '../value_objects/channel_id.dart';
import '../value_objects/node_id.dart';
import '../value_objects/stream_id.dart';
import '../interfaces/retention_policy.dart';
import '../interfaces/state_materializer.dart';
import '../interfaces/entry_repository.dart';
import '../events/domain_event.dart';

/// Aggregate root managing channel membership and stream metadata.
///
/// [ChannelAggregate] is the organizational boundary for gossip synchronization.
/// It maintains membership (which peers can participate) and stream
/// metadata (which streams exist and their retention policies).
///
/// ## Responsibilities
/// - **Membership management**: Add/remove members, enforce local node membership
/// - **Stream lifecycle**: Create streams with retention policies
///
/// ## Membership as Local Metadata
/// Membership lists are LOCAL to each node and are NOT enforced by the gossip
/// protocol. The protocol syncs entries to any peer that has the same channel,
/// regardless of membership. This design:
/// - Avoids inconsistent sync when membership lists diverge between nodes
/// - Keeps the protocol simple and predictable
/// - Allows applications to use membership for their own purposes (e.g., UI)
///
/// Applications requiring access control should implement it at the application
/// layer (e.g., encrypted payloads, signed entries).
///
/// ## Why Entries Are NOT Stored Here
/// Log entries are persisted separately via [EntryRepository] to prevent memory
/// exhaustion. A channel may contain thousands or millions of entries, so
/// keeping them in-memory with the aggregate would be impractical. Instead,
/// the channel maintains only:
/// - Membership set
/// - Stream IDs and retention policies
/// - (Version vectors are tracked per stream in future implementations)
///
/// ## Invariants
/// - Local node is always a member (cannot be removed)
/// - Stream IDs are unique within the channel
/// - Each stream has exactly one retention policy
///
/// ## Domain Events
/// Emits events for observability:
/// - [MemberAdded], [MemberRemoved], [StreamCreated]
class ChannelAggregate {
  /// Unique identifier for this channel.
  final ChannelId id;

  /// The local node ID (always a member of the channel).
  final NodeId localNode;

  final Set<NodeId> _memberIds = {};
  final Map<StreamId, RetentionPolicy> _streams = {};
  final Map<StreamId, StateMaterializer<dynamic>> _materializers = {};
  final List<DomainEvent> _uncommittedEvents = [];

  /// Creates a [ChannelAggregate] with the local node as the initial member.
  ///
  /// Emits: [ChannelCreated] event.
  ChannelAggregate({
    required this.id,
    required this.localNode,
    DateTime? occurredAt,
  }) {
    _memberIds.add(localNode);
    _addEvent(ChannelCreated(id, occurredAt: occurredAt ?? DateTime.now()));
  }

  /// Private constructor for reconstitute — no events, no auto-member-add.
  ChannelAggregate._reconstitute({required this.id, required this.localNode});

  /// Restores a previously persisted channel aggregate.
  ///
  /// Unlike the default constructor, this does NOT emit domain events
  /// (no [ChannelCreated], [MemberAdded], [StreamCreated]) since this
  /// represents loading existing state, not creating new state.
  ///
  /// The caller provides the full [memberIds] set (which should already
  /// include localNode if it was a member when persisted).
  factory ChannelAggregate.reconstitute({
    required ChannelId id,
    required NodeId localNode,
    required Set<NodeId> memberIds,
    required Map<StreamId, RetentionPolicy> streams,
  }) {
    final aggregate = ChannelAggregate._reconstitute(
      id: id,
      localNode: localNode,
    );
    aggregate._memberIds.addAll(memberIds);
    aggregate._streams.addAll(streams);
    return aggregate;
  }

  /// Returns true if the given node is a member of this channel.
  bool hasMember(NodeId id) => _memberIds.contains(id);

  /// Returns all member node IDs.
  Set<NodeId> get memberIds => Set.unmodifiable(_memberIds);

  /// Returns true if a stream with the given ID exists in this channel.
  bool hasStream(StreamId id) => _streams.containsKey(id);

  /// Returns all stream IDs in this channel.
  List<StreamId> get streamIds => _streams.keys.toList();

  /// Returns the total number of streams in this channel.
  int get streamCount => _streams.length;

  /// Returns domain events emitted since last clearing.
  ///
  /// Applications can observe these events for logging, metrics, or
  /// event sourcing. Events accumulate until explicitly cleared.
  List<DomainEvent> get uncommittedEvents =>
      List.unmodifiable(_uncommittedEvents);

  void _addEvent(DomainEvent event) {
    _uncommittedEvents.add(event);
  }

  /// Adds a peer as a member of this channel.
  ///
  /// Membership is local metadata and is NOT enforced by the gossip protocol.
  /// Applications can use membership for UI purposes or application-level
  /// access control decisions.
  ///
  /// No-op if the peer is the local node (already a member).
  /// No-op if the peer is already a member.
  ///
  /// Emits: [MemberAdded] event.
  void addMember(NodeId peerId, {required DateTime occurredAt}) {
    if (peerId == localNode) return;
    if (_memberIds.add(peerId)) {
      _addEvent(MemberAdded(id, peerId, occurredAt: occurredAt));
    }
  }

  /// Removes a peer from channel membership.
  ///
  /// This is a LOCAL operation only. The peer can still sync entries if they
  /// have the channel locally - membership is not enforced by the gossip
  /// protocol. The peer's existing entries remain in the channel.
  ///
  /// Throws if attempting to remove the local node (invariant violation).
  ///
  /// Emits: [MemberRemoved] event if member was present.
  void removeMember(NodeId peerId, {required DateTime occurredAt}) {
    if (peerId == localNode) {
      throw Exception('Cannot remove local node from channel');
    }
    _memberIds.remove(peerId);
  }

  /// Creates a new stream with the specified retention policy.
  ///
  /// Streams are the granularity at which data is synced between peers.
  /// Each stream has its own retention policy determining when entries
  /// are compacted.
  ///
  /// Returns true if the stream was created, false if it already exists.
  ///
  /// Emits: [StreamCreated] event if created.
  bool createStream(
    StreamId streamId,
    RetentionPolicy retention, {
    required DateTime occurredAt,
  }) {
    if (_streams.containsKey(streamId)) return false;
    _streams[streamId] = retention;
    _addEvent(StreamCreated(id, streamId, occurredAt: occurredAt));
    return true;
  }

  /// Registers a materializer for computing derived state from stream entries.
  ///
  /// The materializer will be used by [getState] to fold entries into
  /// application-specific state. Only one materializer can be registered
  /// per stream; subsequent calls replace the previous materializer.
  ///
  /// Example use case: Computing current document state from a stream
  /// of edit operations.
  ///
  /// Note: Materializers are not persisted. Applications must re-register
  /// materializers after loading a channel from storage.
  void registerMaterializer<T>(
    StreamId streamId,
    StateMaterializer<T> materializer,
  ) {
    _materializers[streamId] = materializer;
  }

  /// Computes the materialized state for a stream by folding all entries.
  ///
  /// Retrieves all entries from the [EntryRepository], then applies the
  /// registered materializer's [fold] method in timestamp order to produce
  /// the final state.
  ///
  /// Returns null if:
  /// - No materializer is registered for this stream
  /// - The stream doesn't exist
  ///
  /// Throws if the type parameter [T] doesn't match the registered
  /// materializer's type.
  ///
  /// Note: This method performs a full scan of entries. For large streams,
  /// consider implementing incremental materialization or caching.
  Future<T?> getState<T>(
    StreamId streamId,
    EntryRepository entryRepository,
  ) async {
    final materializer = _materializers[streamId];
    if (materializer == null) return null;
    if (!_streams.containsKey(streamId)) return null;

    // Type safety check
    if (materializer is! StateMaterializer<T>) {
      throw TypeError();
    }

    final entries = await entryRepository.getAll(id, streamId);
    T state = materializer.initial();
    for (final entry in entries) {
      state = materializer.fold(state, entry);
    }
    return state;
  }
}
