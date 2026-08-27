import 'dart:typed_data';
import 'package:gossip/src/shared/domain/errors/domain_exception.dart';
import 'package:gossip/src/shared/domain/errors/sync_error.dart';
import 'package:gossip/src/shared/domain/events/domain_event.dart';
import 'package:gossip/src/sync/domain/events/sync_events.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/sync/domain/aggregates/channel_aggregate.dart';
import 'package:gossip/src/sync/domain/interfaces/channel_repository.dart';
import 'package:gossip/src/sync/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/sync/domain/value_objects/compaction_result.dart';
import 'package:gossip/src/sync/domain/interfaces/entry_repository.dart';
import 'package:gossip/src/shared/domain/interfaces/local_node_repository.dart';
import 'package:gossip/src/sync/domain/interfaces/state_materializer.dart';
import 'package:gossip/src/sync/domain/services/hlc_clock.dart';
import 'package:gossip/src/shared/domain/services/keyed_task_chain.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/sync/application/materialization/materialization_service.dart';

/// Application service orchestrating channel and stream operations.
///
/// [ChannelService] coordinates between the domain layer ([ChannelAggregate])
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
/// Used by: The Coordinator facade and the Channel/EventStream facades.
/// (The GossipEngine writes merged entries via [EntryRepository] directly;
/// it does not go through this service.)
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

  /// Persistence layer for [ChannelAggregate] instances.
  ///
  /// When null, aggregates are not persisted (in-memory only).
  final ChannelRepository? _channelRepository;

  /// Persistence layer for [LogEntry] instances.
  ///
  /// When null, entries are not persisted (in-memory only).
  final EntryRepository? _entryRepository;

  /// Maximum entry payload size in bytes accepted by [appendEntry].
  ///
  /// Derived by the Coordinator from the gossip engine's delta budget: a
  /// payload above this limit can never be transmitted to peers, so it is
  /// rejected loudly at write time instead of silently failing to sync.
  /// When null, no limit is enforced (local-only / testing setups).
  final int? maxPayloadBytes;

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

  /// Repository for persisting local node state (HLC clock).
  final LocalNodeRepository _localNodeRepository;

  /// Dedicated service for materializer orchestration.
  final MaterializationService? _materializationService;

  ChannelService({
    required this.localNode,
    required LocalNodeRepository localNodeRepository,
    HlcClock? hlcClock,
    ChannelRepository? channelRepository,
    EntryRepository? entryRepository,
    MaterializationService? materializationService,
    this.maxPayloadBytes,
    this.onError,
    this.onEvent,
  }) : _hlcClock = hlcClock,
       _channelRepository = channelRepository,
       _entryRepository = entryRepository,
       _localNodeRepository = localNodeRepository,
       _materializationService = materializationService;

  bool _disposed = false;

  /// Rejects further writes (see [appendEntry]). Called by the owning
  /// Coordinator when it is disposed.
  void markDisposed() => _disposed = true;

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

  /// Creates a new channel with the given identifier, or keeps the
  /// existing one (get-or-create).
  ///
  /// Establishes the channel with no members and no streams. If a channel
  /// with this ID already exists it is left untouched and no events are
  /// emitted — silently replacing it would wipe membership and every
  /// stream registration (COR3-16).
  ///
  /// Used when: Local node discovers or creates a new channel.
  ///
  /// Returns: List of domain events emitted during creation (e.g., [ChannelCreated]).
  Future<List<DomainEvent>> createChannel(ChannelId channelId) async {
    if (_channelRepository != null &&
        await _channelRepository.findById(channelId) != null) {
      return const [];
    }
    final channel = ChannelAggregate(id: channelId, localNode: localNode);
    if (_channelRepository != null) {
      await _channelRepository.save(channel);
    }
    // Drain rather than read: the aggregate instance is long-lived via the
    // caching repository, so un-drained events would be replayed (and
    // accumulate) on every later mutation.
    final events = channel.takeUncommittedEvents();
    _emitEvents(events);
    return events;
  }

  /// Removes a channel and all its associated data.
  ///
  /// This is entirely local: it deletes this node's copy of the channel,
  /// its entries, and its materializer state. Peers that still hold the
  /// channel are unaffected — they keep replicating its entries among
  /// themselves — so this is not a way to delete data mesh-wide or revoke
  /// access.
  ///
  /// Used when: Local node leaves or deletes a channel.
  ///
  /// Emits [ChannelRemoved] once the aggregate is deleted; emits nothing
  /// for a channel that didn't exist.
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
      await _entryRepository.clearChannel(channelId);
    }

    // Clean up materializer state
    await _materializationService?.disposeChannel(channelId);

    // Delete the channel aggregate
    await _channelRepository.delete(channelId);

    _emitEvents([ChannelRemoved(channelId, occurredAt: DateTime.now())]);

    return true;
  }

  /// Adds a peer to the channel's member set.
  ///
  /// Records the member in local channel metadata (see ADR-007 — no
  /// protocol gating) and emits [MemberAdded].
  ///
  /// Used when: The local app decides to record a peer as a member —
  /// membership metadata is local and never crosses the wire.
  ///
  /// Does not throw for a missing repository or channel: [_withChannel]
  /// emits an error and this returns an empty list instead.
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
  /// Removes the member from local channel metadata (see ADR-007 — no
  /// protocol gating; the removed peer can still sync entries it already
  /// has) and emits [MemberRemoved].
  ///
  /// Used when: Peer leaves channel or is evicted.
  ///
  /// Does not throw for a missing repository or channel: [_withChannel]
  /// emits an error and this returns an empty list instead. Throws
  /// [DomainException] if [peerId] is the local node — removing the local
  /// node from its own channel is an invariant violation, and that guard
  /// lives in the aggregate, not this layer.
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
  /// The stream starts with an empty version vector and no entries, ready
  /// to accept writes via [appendEntry] under the given retention policy.
  /// Emits [StreamCreated] once the stream is registered.
  ///
  /// Used when: Application defines a new data stream to synchronize.
  ///
  /// Does not throw for a missing repository or channel: [_withChannel]
  /// emits an error and this returns an empty list instead.
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
    // Drain rather than read — see createChannel.
    final events = channel.takeUncommittedEvents();
    _emitEvents(events);
    return events;
  }

  /// Appends a new entry to a stream authored by the local node.
  ///
  /// Generates the next sequence number for the local node's author chain,
  /// creates a [LogEntry] with current timestamp, and appends to [EntryRepository].
  ///
  /// The stream's version vector lives in EntryRepository and advances as
  /// part of this append — there is no separate confirmation step.
  ///
  /// Used when: Application writes new data to a stream.
  ///
  /// Guarantees monotonically increasing per-author sequence numbers and
  /// that the entry is written to [EntryRepository] before the returned
  /// future completes — callers can treat a completed append as stored,
  /// not merely queued.
  ///
  /// Appends to the same stream are serialized: there are awaits between
  /// reading the latest sequence and storing the entry, so unserialized
  /// concurrent appends would allocate colliding sequence numbers.
  Future<void> appendEntry(
    ChannelId channelId,
    StreamId streamId,
    Uint8List payload,
  ) {
    if (_disposed) {
      // Durable-but-orphaned otherwise: no engine to sync the entry, its
      // events dropped at the coordinator's closed controllers.
      throw StateError('Cannot append: the coordinator has been disposed');
    }
    final limit = maxPayloadBytes;
    if (limit != null && payload.length > limit) {
      // A payload that can never fit a delta message would sync-livelock;
      // reject it at the source (contract violation, not a runtime error).
      throw ArgumentError.value(
        payload.length,
        'payload',
        'exceeds the maximum entry payload of $limit bytes '
            '(derived from the gossip delta budget); '
            'larger payloads can never be synced to peers',
      );
    }

    final key = (channelId, streamId);
    return _appendChain.enqueue(
      key,
      () => _appendEntryNow(channelId, streamId, payload),
    );
  }

  /// Per-stream chain of pending appends (see [appendEntry]).
  ///
  /// Appends to the same stream share awaits between reading the latest
  /// sequence and storing the entry, so unserialized concurrent appends
  /// would allocate colliding sequence numbers — this chain is what
  /// guarantees the serialization [appendEntry] promises.
  final KeyedTaskChain<(ChannelId, StreamId)> _appendChain = KeyedTaskChain();

  Future<void> _appendEntryNow(
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

    // Appending to a stream that was never created is caller misuse, like
    // an oversized payload: silently dropping the payload would be
    // permanent, invisible data loss. Throw so the failure hits the
    // append() call site.
    final streamExists = await hasStream(channelId, streamId);
    if (!streamExists) {
      throw StateError(
        'Cannot append: stream $streamId does not exist in channel '
        '$channelId (create it with getOrCreateStream first)',
      );
    }

    final sequence =
        await _entryRepository.latestSequence(channelId, streamId, localNode) +
        1;

    final timestamp = await takeTimestamp();

    final entry = LogEntry(
      author: localNode,
      sequence: sequence,
      timestamp: timestamp,
      payload: payload,
    );

    await _entryRepository.append(channelId, streamId, entry);

    // Emit EntryAppended event
    final appendEvent = EntryAppended(
      channelId,
      streamId,
      entry,
      occurredAt: DateTime.now(),
    );
    _emitEvents([appendEvent]);

    // Trigger incremental fold for registered materializers
    await _materializationService?.foldEntries(channelId, streamId, [entry]);
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
    return await _entryRepository.getAll(channelId, streamId);
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

  /// Returns the [RetentionPolicy] for the given stream, or `null` if
  /// the channel or stream does not exist.
  Future<RetentionPolicy?> getRetentionPolicy(
    ChannelId channelId,
    StreamId streamId,
  ) async {
    if (_channelRepository == null) {
      return null;
    }
    final channel = await _channelRepository.findById(channelId);
    return channel?.getRetentionPolicy(streamId);
  }

  /// Takes a fresh HLC timestamp (or a wall-clock fallback if no clock
  /// is configured) and persists the advanced clock state.
  ///
  /// Reading the clock advances it; persisting immediately means a crash
  /// never restores a clock older than one an external observer has
  /// already seen. (Deliberately a method, not a getter — a getter with
  /// state-mutating side effects is a trap.)
  Future<Hlc> takeTimestamp() async {
    final timestamp =
        _hlcClock?.now() ?? Hlc(DateTime.now().millisecondsSinceEpoch, 0);
    if (_hlcClock != null) {
      await _localNodeRepository.saveClockState(_hlcClock.current);
    }
    return timestamp;
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
  Future<void> registerMaterializer<T>(
    ChannelId channelId,
    StreamId streamId,
    StateMaterializer<T> materializer,
  ) async {
    await _materializationService?.register(channelId, streamId, materializer);
  }

  /// Computes the materialized state for a stream.
  ///
  /// Returns null if no materializer is registered or the stream doesn't exist.
  ///
  /// Used when: Application needs to read the current derived state.
  Future<T?> getState<T>(ChannelId channelId, StreamId streamId) async {
    if (_materializationService == null) return null;

    // Verify stream exists before returning state
    final streamExists = await hasStream(channelId, streamId);
    if (!streamExists) return null;

    return await _materializationService.getState<T>(channelId, streamId);
  }

  /// Folds merged entries into the materializer for a stream.
  ///
  /// Called by Coordinator after entries are merged from a peer.
  Future<void> foldMergedEntries(
    ChannelId channelId,
    StreamId streamId,
    List<LogEntry> entries, {
    bool containsOutOfOrderEntries = false,
  }) async {
    await _materializationService?.foldEntries(
      channelId,
      streamId,
      entries,
      containsOutOfOrderEntries: containsOutOfOrderEntries,
    );
  }

  /// Returns the state stream for a registered materializer.
  ///
  /// The stream emits materialized state after each fold batch.
  /// Returns null if no materializer is registered.
  ///
  /// Synchronous by design (callers subscribe without awaiting) — unlike
  /// [getState] it cannot verify stream existence, since that check is
  /// async. Callers get null only for unregistered materializers; a
  /// registered materializer on a nonexistent stream still returns its
  /// (never-emitting) stream.
  Stream<T>? getStateStream<T>(ChannelId channelId, StreamId streamId) {
    return _materializationService?.getStateStream<T>(channelId, streamId);
  }

  /// Forces a full rebuild of the materialized state for a stream.
  ///
  /// Useful for developer settings or corruption recovery. No-op if the
  /// stream doesn't exist, mirroring [getState]'s guard — a materializer
  /// can be registered against a stream id before the stream exists (see
  /// [registerMaterializer]), so "nothing registered" isn't a reliable
  /// signal that there's nothing to rebuild.
  Future<void> resetState(ChannelId channelId, StreamId streamId) async {
    if (_materializationService == null) return;

    final streamExists = await hasStream(channelId, streamId);
    if (!streamExists) return;

    await _materializationService.reset(channelId, streamId);
  }

  /// Removes specific entries from a stream during compaction.
  ///
  /// Deletes entries identified by their IDs from the entry repository.
  /// Does nothing if no entry repository is configured.
  ///
  /// Used when: Applying retention policies to reclaim storage.
  Future<void> removeEntries(
    ChannelId channelId,
    StreamId streamId,
    List<LogEntryId> ids,
  ) async {
    await _entryRepository?.removeEntries(channelId, streamId, ids);
  }

  /// Returns the stream's version vector (empty if no entry store).
  Future<VersionVector> getVersionVector(
    ChannelId channelId,
    StreamId streamId,
  ) async {
    if (_entryRepository == null) return VersionVector.empty;
    return _entryRepository.getVersionVector(channelId, streamId);
  }

  /// Disposes all materializer state (closes their state streams).
  ///
  /// Called by the Coordinator on dispose so `stateStream` listeners get
  /// onDone instead of leaking for the process lifetime.
  Future<void> disposeAllMaterializers() async {
    await _materializationService?.disposeAll();
  }

  /// Applies a stream's retention policy, pruning entries it no longer keeps.
  ///
  /// Returns a [CompactionResult] describing what was removed, or null if
  /// there was nothing to prune (no entry store, no policy, a retain-all
  /// policy, empty stream, or all entries survive). When [resetMaterializers]
  /// is true (the default) the stream's materialized state is rebuilt so it
  /// reflects only the surviving entries.
  ///
  /// The version vector is a monotonic high-water mark, so it never regresses
  /// on compaction — pruned entries are not re-advertised (which would
  /// resurrect them via gossip).
  Future<CompactionResult?> compactStream(
    ChannelId channelId,
    StreamId streamId, {
    bool resetMaterializers = true,
  }) async {
    if (_entryRepository == null) return null;

    final retention = await getRetentionPolicy(channelId, streamId);
    if (retention == null || retention.retainsAll) return null;

    final entries = await getEntries(channelId, streamId);
    if (entries.isEmpty) return null;

    final now = await takeTimestamp();
    final survivors = retention.compact(entries, now);
    final survivorIds = survivors.map((e) => e.id).toSet();
    final toPrune = entries.where((e) => !survivorIds.contains(e.id)).toList();
    if (toPrune.isEmpty) return null;

    await removeEntries(channelId, streamId, toPrune.map((e) => e.id).toList());
    final baseVersion = await getVersionVector(channelId, streamId);

    if (resetMaterializers) {
      await resetState(channelId, streamId);
    }

    return CompactionResult(
      entriesRemoved: toPrune.length,
      entriesRetained: survivors.length,
      bytesFreed: toPrune.fold(0, (sum, e) => sum + e.payload.length),
      baseVersion: baseVersion,
    );
  }

  /// Applies every stream's retention policy across all channels. Retain-all
  /// streams are skipped without loading their entries. Called by the
  /// Coordinator's periodic auto-compaction.
  Future<void> compactAll() async {
    if (_channelRepository == null || _entryRepository == null) return;

    for (final channelId in await _channelRepository.listIds()) {
      final channel = await _channelRepository.findById(channelId);
      if (channel == null) continue;
      for (final streamId in channel.streamIds) {
        final retention = channel.getRetentionPolicy(streamId);
        if (retention == null || retention.retainsAll) continue;
        // Isolate failures per stream: retention policies and
        // materializers are app code, and the pass repeats on a timer —
        // one poison stream must not starve every stream after it on
        // every pass, forever.
        try {
          await compactStream(channelId, streamId);
        } catch (e) {
          _emitError(
            StorageSyncError(
              SyncErrorType.storageFailure,
              'Compaction failed for $channelId/$streamId: $e',
              occurredAt: DateTime.now(),
              cause: e,
            ),
          );
        }
      }
    }
  }
}
