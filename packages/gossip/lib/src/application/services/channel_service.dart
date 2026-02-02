import 'dart:typed_data';
import '../../domain/errors/sync_error.dart';
import '../../domain/events/domain_event.dart';
import '../../domain/value_objects/channel_id.dart';
import '../../domain/value_objects/node_id.dart';
import '../../domain/value_objects/stream_id.dart';
import '../../domain/value_objects/log_entry.dart';
import '../../domain/value_objects/hlc.dart';
import '../../domain/aggregates/channel_aggregate.dart';
import '../../domain/interfaces/channel_repository.dart';
import '../../domain/interfaces/retention_policy.dart';
import '../../domain/interfaces/entry_repository.dart';
import '../../domain/interfaces/state_materializer.dart';
import '../../domain/services/hlc_clock.dart';

/// Application service orchestrating channel and stream operations.
///
/// [ChannelService] coordinates between the domain layer ([ChannelAggregate] aggregate)
/// and infrastructure layer ([ChannelRepository], [EntryRepository]). It handles:
///
/// - **Channel lifecycle**: Creating channels and managing membership
/// - **Stream management**: Creating streams with retention policies
/// - **Entry operations**: Appending and retrieving log entries
///
/// ## Transaction Boundaries
///
/// Each public method represents a transaction boundary. Operations that modify
/// aggregates follow the pattern:
/// 1. Load aggregate from repository
/// 2. Execute domain operation on aggregate
/// 3. Save aggregate back to repository
///
/// Entry operations ([appendEntry], [getEntries]) work directly with
/// [EntryRepository] since entries are stored separately from aggregates.
///
/// ## Optional Dependencies
///
/// Both [ChannelRepository] and [EntryRepository] are optional to support
/// in-memory-only operation for testing. When null, persistence is skipped
/// but domain logic still executes.
///
/// Used by: Protocol services (GossipEngine) and public facades.
class ChannelService {
  /// Local node identifier for this instance.
  ///
  /// Used to generate [LogEntry] instances with correct authorship.
  final NodeId localNode;

  /// Hybrid logical clock for generating timestamps.
  ///
  /// Used to generate causally consistent timestamps for entries.
  /// When null, falls back to system time (not recommended for production).
  final HlcClock? _hlcClock;

  /// Persistence layer for [ChannelAggregate] aggregates.
  ///
  /// When null, aggregates are not persisted (in-memory only).
  final ChannelRepository? _channelRepository;

  /// Persistence layer for [LogEntry] instances.
  ///
  /// When null, entries are not persisted (in-memory only).
  final EntryRepository? _entryRepository;

  /// Optional callback for reporting synchronization errors.
  ///
  /// When provided, errors that would otherwise be silent are reported
  /// through this callback for observability.
  final ErrorCallback? onError;

  /// Optional callback for emitting domain events.
  ///
  /// When provided, domain events from aggregates are forwarded through
  /// this callback for observability.
  final void Function(DomainEvent)? onEvent;

  ChannelService({
    required this.localNode,
    HlcClock? hlcClock,
    ChannelRepository? channelRepository,
    EntryRepository? entryRepository,
    this.onError,
    this.onEvent,
  }) : _hlcClock = hlcClock,
       _channelRepository = channelRepository,
       _entryRepository = entryRepository;

  /// Emits an error through the callback if one is registered.
  void _emitError(SyncError error) {
    onError?.call(error);
  }

  /// Emits domain events through the callback if one is registered.
  void _emitEvents(List<DomainEvent> events) {
    if (onEvent != null) {
      for (final event in events) {
        onEvent!(event);
      }
    }
  }

  /// Creates a new channel with the given identifier.
  ///
  /// Initializes a new [ChannelAggregate] aggregate and persists it to the repository.
  /// The channel starts with no members and no streams.
  ///
  /// Used when: Local node discovers or creates a new channel.
  ///
  /// Transaction: Creates and saves a new aggregate.
  ///
  /// Returns: List of domain events emitted during creation (e.g., [ChannelCreated]).
  Future<List<DomainEvent>> createChannel(ChannelId channelId) async {
    final channel = ChannelAggregate(id: channelId, localNode: localNode);
    if (_channelRepository != null) {
      await _channelRepository.save(channel);
    }
    final events = channel.uncommittedEvents;
    _emitEvents(events);
    return events;
  }

  /// Removes a channel and all its associated data.
  ///
  /// This operation:
  /// 1. Deletes the [ChannelAggregate] from the repository
  /// 2. Clears all entries for this channel from the entry store
  ///
  /// Used when: Local node leaves or deletes a channel.
  ///
  /// Transaction: Delete aggregate and clear entries.
  ///
  /// Returns true if the channel was removed, false if it didn't exist.
  Future<bool> removeChannel(ChannelId channelId) async {
    if (_channelRepository == null) {
      _emitError(
        StorageSyncError(
          SyncErrorType.storageFailure,
          'Channel removal skipped: no repository configured for channel $channelId',
          occurredAt: DateTime.now(),
        ),
      );
      return false;
    }

    // Check if channel exists
    final channel = await _channelRepository.findById(channelId);
    if (channel == null) {
      return false;
    }

    // Clear all entries for this channel
    if (_entryRepository != null) {
      _entryRepository.clearChannel(channelId);
    }

    // Delete the channel aggregate
    await _channelRepository.delete(channelId);

    return true;
  }

  /// Adds a peer to the channel's member set.
  ///
  /// Loads the [ChannelAggregate] aggregate, adds the member, and persists the change.
  /// Fires [MemberAdded] domain event.
  ///
  /// Used when: Peer joins channel via gossip or explicit invitation.
  ///
  /// Transaction: Load → modify → save.
  ///
  /// Throws [Exception] if channel doesn't exist in repository.
  ///
  /// Returns: List of domain events emitted (e.g., [MemberAdded]).
  Future<List<DomainEvent>> addMember(
    ChannelId channelId,
    NodeId peerId,
  ) async {
    return await _withChannel(channelId, (channel) {
      channel.addMember(peerId, occurredAt: DateTime.now());
    });
  }

  /// Removes a peer from the channel's member set.
  ///
  /// Loads the [ChannelAggregate] aggregate, removes the member, and persists the change.
  /// Fires [MemberRemoved] domain event.
  ///
  /// Used when: Peer leaves channel or is evicted.
  ///
  /// Transaction: Load → modify → save.
  ///
  /// Throws [Exception] if channel doesn't exist in repository.
  ///
  /// Returns: List of domain events emitted (e.g., [MemberRemoved]).
  Future<List<DomainEvent>> removeMember(
    ChannelId channelId,
    NodeId peerId,
  ) async {
    return await _withChannel(channelId, (channel) {
      channel.removeMember(peerId, occurredAt: DateTime.now());
    });
  }

  /// Creates a new stream within a channel.
  ///
  /// Loads the [ChannelAggregate] aggregate, creates the stream with the specified
  /// retention policy, and persists the change. Fires [StreamCreated] domain
  /// event.
  ///
  /// The stream starts with an empty version vector and no entries. Entries
  /// are appended separately via [appendEntry].
  ///
  /// Used when: Application defines a new data stream to synchronize.
  ///
  /// Transaction: Load → modify → save.
  ///
  /// Throws [Exception] if channel doesn't exist in repository.
  ///
  /// Returns: List of domain events emitted (e.g., [StreamCreated]).
  Future<List<DomainEvent>> createStream(
    ChannelId channelId,
    StreamId streamId,
    RetentionPolicy retention,
  ) async {
    return await _withChannel(channelId, (channel) {
      channel.createStream(streamId, retention, occurredAt: DateTime.now());
    });
  }

  /// Executes an operation on a channel with load → modify → save pattern.
  ///
  /// Emits error and returns early if:
  /// - Repository is null (StorageSyncError)
  /// - Channel not found (ChannelSyncError)
  ///
  /// This method never throws - it fails gracefully with error emission.
  ///
  /// Returns: List of domain events emitted during the operation, or empty list on error.
  Future<List<DomainEvent>> _withChannel(
    ChannelId channelId,
    void Function(ChannelAggregate) operation,
  ) async {
    if (_channelRepository == null) {
      _emitError(
        StorageSyncError(
          SyncErrorType.storageFailure,
          'Channel operation skipped: no repository configured for channel $channelId',
          occurredAt: DateTime.now(),
        ),
      );
      return [];
    }

    final channel = await _channelRepository.findById(channelId);
    if (channel == null) {
      _emitError(
        ChannelSyncError(
          channelId,
          SyncErrorType.storageFailure,
          'Channel operation skipped: channel $channelId not found',
          occurredAt: DateTime.now(),
        ),
      );
      return [];
    }

    operation(channel);
    await _channelRepository.save(channel);
    final events = channel.uncommittedEvents;
    _emitEvents(events);
    return events;
  }

  /// Appends a new entry to a stream authored by the local node.
  ///
  /// Generates the next sequence number for the local node's author chain,
  /// creates a [LogEntry] with current timestamp, and appends to [EntryRepository].
  ///
  /// Note: This does NOT update the [Channel] aggregate's version vector.
  /// That happens separately during sync protocol when entries are confirmed
  /// by remote peers.
  ///
  /// Used when: Application writes new data to a stream.
  ///
  /// Transaction: Query latest sequence → create entry → append to store.
  Future<void> appendEntry(
    ChannelId channelId,
    StreamId streamId,
    Uint8List payload,
  ) async {
    if (_entryRepository == null) {
      _emitError(
        StorageSyncError(
          SyncErrorType.storageFailure,
          'Entry append skipped: no entry store configured for $channelId/$streamId',
          occurredAt: DateTime.now(),
        ),
      );
      return;
    }

    // Check if stream exists before appending
    final streamExists = await hasStream(channelId, streamId);
    if (!streamExists) {
      _emitError(
        StorageSyncError(
          SyncErrorType.storageFailure,
          'Entry append skipped: stream $streamId does not exist in channel $channelId',
          occurredAt: DateTime.now(),
        ),
      );
      return;
    }

    final sequence =
        _entryRepository.latestSequence(channelId, streamId, localNode) + 1;

    // Generate timestamp from HlcClock if available, otherwise fallback to system time
    final timestamp =
        _hlcClock?.now() ?? Hlc(DateTime.now().millisecondsSinceEpoch, 0);

    final entry = LogEntry(
      author: localNode,
      sequence: sequence,
      timestamp: timestamp,
      payload: payload,
    );

    _entryRepository.append(channelId, streamId, entry);

    // Emit EntryAppended event
    final appendEvent = EntryAppended(
      channelId,
      streamId,
      entry,
      occurredAt: DateTime.now(),
    );
    _emitEvents([appendEvent]);

  }

  /// Retrieves all entries for a stream, ordered by HLC timestamp.
  ///
  /// Returns all entries currently stored for the stream. Order is
  /// deterministic (HLC ascending) for consistent playback across peers.
  ///
  /// Used when: Application reads stream data or syncs with remote peer.
  ///
  /// Returns empty list if [EntryRepository] is null or stream has no entries.
  Future<List<LogEntry>> getEntries(
    ChannelId channelId,
    StreamId streamId,
  ) async {
    if (_entryRepository == null) {
      _emitError(
        StorageSyncError(
          SyncErrorType.storageFailure,
          'Entry retrieval skipped: no entry store configured for $channelId/$streamId',
          occurredAt: DateTime.now(),
        ),
      );
      return [];
    }
    return _entryRepository.getAll(channelId, streamId);
  }

  /// Returns the set of member node IDs for a channel.
  ///
  /// Returns empty set if repository is null or channel not found.
  ///
  /// Used when: Querying channel membership.
  Future<Set<NodeId>> getMembers(ChannelId channelId) async {
    if (_channelRepository == null) {
      return {};
    }
    final channel = await _channelRepository.findById(channelId);
    return channel?.memberIds ?? {};
  }

  /// Returns the list of stream IDs for a channel.
  ///
  /// Returns empty list if repository is null or channel not found.
  ///
  /// Used when: Querying available streams in a channel.
  Future<List<StreamId>> getStreamIds(ChannelId channelId) async {
    if (_channelRepository == null) {
      return [];
    }
    final channel = await _channelRepository.findById(channelId);
    return channel?.streamIds ?? [];
  }

  /// Checks if a stream exists in a channel.
  ///
  /// Returns false if repository is null or channel/stream not found.
  Future<bool> hasStream(ChannelId channelId, StreamId streamId) async {
    if (_channelRepository == null) {
      return false;
    }
    final channel = await _channelRepository.findById(channelId);
    return channel?.hasStream(streamId) ?? false;
  }

  /// Registers a materializer for a stream to compute derived state.
  ///
  /// The materializer folds log entries into application-specific state.
  /// Materializers must be re-registered after loading channels from storage
  /// as they are not persisted.
  ///
  /// Used when: Application wants to compute derived state (e.g., current
  /// document state from edit operations).
  ///
  /// Transaction: Load → register → save.
  ///
  /// Returns: List of domain events (typically empty for materializer registration).
  Future<List<DomainEvent>> registerMaterializer<T>(
    ChannelId channelId,
    StreamId streamId,
    StateMaterializer<T> materializer,
  ) async {
    return await _withChannel(channelId, (channel) {
      channel.registerMaterializer(streamId, materializer);
    });
  }

  /// Computes the materialized state for a stream.
  ///
  /// Retrieves all entries from the stream and applies the registered
  /// materializer to fold them into state.
  ///
  /// Returns null if:
  /// - No materializer is registered for this stream
  /// - The stream doesn't exist
  /// - Repository or entry store is null
  ///
  /// Used when: Application needs to read the current derived state.
  ///
  /// Transaction: Read-only (no save).
  Future<T?> getState<T>(ChannelId channelId, StreamId streamId) async {
    if (_channelRepository == null || _entryRepository == null) {
      return null;
    }

    final channel = await _channelRepository.findById(channelId);
    if (channel == null) {
      return null;
    }

    return channel.getState<T>(streamId, _entryRepository);
  }
}
