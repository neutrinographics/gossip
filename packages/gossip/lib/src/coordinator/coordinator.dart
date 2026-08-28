import 'dart:async';
import 'package:meta/meta.dart';
import 'dart:math';
import 'package:gossip/src/shared/shared.dart';
import 'package:gossip/src/sync/sync.dart';
import 'package:gossip/src/membership/membership.dart';
import 'package:gossip/src/coordinator/adaptive_timing_status.dart';
import 'package:gossip/src/coordinator/channel.dart';
import 'package:gossip/src/coordinator/coordinator_config.dart';
import 'package:gossip/src/coordinator/event_stream.dart';
import 'package:gossip/src/coordinator/gossip_sync_activity.dart';
import 'package:gossip/src/coordinator/health_status.dart';
import 'package:gossip/src/coordinator/resource_usage.dart';
import 'package:gossip/src/coordinator/sync_state.dart';

/// Main entry point for the gossip sync library.
///
/// [Coordinator] manages the lifecycle of the sync system, including:
/// - Peer management and failure detection (SWIM protocol)
/// - Channel lifecycle and membership
/// - Protocol services (gossip anti-entropy)
/// - Event and error streams for observability
///
/// ## Quick Start
///
/// ```dart
/// // Create repositories (in-memory for testing, or your own implementations)
/// final channelRepo = InMemoryChannelRepository();
/// final entryRepo = InMemoryEntryRepository();
///
/// // Create coordinator
/// final coordinator = await Coordinator.create(
///   localNodeRepository: InMemoryLocalNodeRepository(),
///   channelRepository: channelRepo,
///   entryRepository: entryRepo,
/// );
///
/// // Create a channel and stream
/// final channel = await coordinator.createChannel(ChannelId('my-channel'));
/// final stream = await channel.getOrCreateStream(StreamId('messages'));
///
/// // Append an entry
/// await stream.append(Uint8List.fromList([1, 2, 3]));
///
/// // Start sync (requires MessagePort and TimePort for network sync)
/// await coordinator.start();
/// ```
///
/// ## Threading Model
///
/// **Important:** All [Coordinator] operations must run in the same Dart isolate.
/// The library uses no locks or synchronization primitives. Accessing a
/// coordinator from multiple isolates will cause data corruption.
///
/// ## Network Synchronization
///
/// To enable network sync, provide [MessagePort] and [TimePort] implementations
/// to [Coordinator.create]:
///
/// ```dart
/// final coordinator = await Coordinator.create(
///   localNodeRepository: InMemoryLocalNodeRepository(),
///   channelRepository: channelRepo,
///   entryRepository: entryRepo,
///   messagePort: MyBluetoothMessagePort(),  // Your transport implementation
///   timePort: RealTimePort(),               // Or InMemoryTimePort for testing
/// );
/// ```
///
/// ## Error Handling
///
/// The coordinator uses a two-tier error handling strategy:
/// - **Fatal errors**: Throw [StateError] for lifecycle violations (e.g., starting
///   when already running)
/// - **Recoverable errors**: Emitted via [errors] stream for network failures,
///   protocol violations, etc.
///
/// Always subscribe to [errors] for observability:
///
/// ```dart
/// coordinator.errors.listen((error) {
///   print('Sync error: ${error.message}');
/// });
/// ```
///
/// See also:
/// - [Channel] for channel operations
/// - [EventStream] for entry operations
/// - [CoordinatorConfig] for tuning sync parameters
/// - [HealthStatus] for monitoring
class Coordinator {
  /// The local node identifier.
  final NodeId localNode;

  /// Peer registry aggregate.
  final PeerRegistry _peerRegistry;

  /// Channel service for channel operations.
  final ChannelService _channelService;

  /// Peer service for peer operations.
  final PeerService _peerService;

  /// Peer repository for persistence.
  final PeerRepository _peerRepository;

  /// Local node repository for identity and clock persistence.
  final LocalNodeRepository _localNodeRepository;

  /// Channel repository for loading channels.
  final ChannelRepository _channelRepository;

  /// Entry repository for gossip engine.
  final EntryRepository _entryRepository;

  /// Configuration for the coordinator.
  final CoordinatorConfig _config;

  /// Diagnostic log sink. Also the fallback error sink after dispose — see
  /// [_handleError].
  final LogCallback? _onLog;

  /// HLC clock for reading current clock state. Null in local-only mode.
  final HlcClock? _hlcClock;

  /// Timer port, used for the periodic auto-compaction loop. Null in
  /// local-only mode (no auto-compaction).
  final TimePort? _timePort;

  /// Drives the periodic auto-compaction loop. Null until [_startCompaction]
  /// constructs it on the first `start`/`resume`; every stop/pause/dispose
  /// path calls [GenerationScheduler.stop] on it (see [_stopCompaction]).
  GenerationScheduler? _compactionScheduler;

  /// Gossip engine for anti-entropy synchronization.
  GossipEngine? _gossipEngine;

  /// Failure detector for SWIM protocol.
  FailureDetector? _failureDetector;

  /// Cache of channel facades by ID.
  final Map<ChannelId, Channel> _channelFacades = {};

  /// Current state of the coordinator.
  SyncState _state = SyncState.stopped;

  /// Lifecycle epoch, incremented by [stop] and [dispose].
  ///
  /// [start] captures it before its internal awaits and aborts if it
  /// changed — so a stop() issued while start() was loading channels wins,
  /// instead of the resumed start() leaving engines running behind a
  /// coordinator that reports itself stopped.
  int _lifecycleEpoch = 0;

  /// Stream controller for domain events (provided during construction).
  final StreamController<DomainEvent> _eventsController;

  /// Stream controller for sync errors.
  final StreamController<SyncError> _errorsController =
      StreamController<SyncError>.broadcast();

  /// Stream controller for state changes.
  final StreamController<SyncState> _stateController =
      StreamController<SyncState>.broadcast();

  /// Private constructor. Use [create] factory method.
  Coordinator._({
    required this.localNode,
    required PeerRegistry peerRegistry,
    required ChannelService channelService,
    required PeerService peerService,
    required PeerRepository peerRepository,
    required LocalNodeRepository localNodeRepository,
    required ChannelRepository channelRepository,
    required EntryRepository entryRepository,
    required CoordinatorConfig config,
    required HlcClock? hlcClock,
    required TimePort? timePort,
    required StreamController<DomainEvent> eventsController,
    required LogCallback? onLog,
  }) : _peerRegistry = peerRegistry,
       _channelService = channelService,
       _peerService = peerService,
       _peerRepository = peerRepository,
       _localNodeRepository = localNodeRepository,
       _channelRepository = channelRepository,
       _entryRepository = entryRepository,
       _config = config,
       _hlcClock = hlcClock,
       _timePort = timePort,
       _eventsController = eventsController,
       _onLog = onLog;

  /// Creates a new coordinator instance.
  ///
  /// This is the main entry point for applications using the library.
  ///
  /// [messagePort] and [timePort] are optional. If both are provided, the
  /// coordinator will enable gossip protocol and failure detection for
  /// synchronization. If null, the coordinator operates in local-only mode
  /// without network sync.
  ///
  /// [peerRepository] is optional and defaults to [InMemoryPeerRepository].
  /// Peers are transient — they are discovered at runtime and added/removed
  /// as devices connect and disconnect. Persisting peers across restarts is
  /// unnecessary because a loaded peer has no meaning if the device isn't
  /// present, and the failure detector would immediately begin suspecting it.
  ///
  /// [config] allows tuning of gossip and failure detection parameters.
  /// If null, default values are used.
  ///
  /// [random] lets callers inject a seeded Random for deterministic tests.
  ///
  /// [onLog] receives diagnostic logs; also the fallback error sink after
  /// dispose.
  static Future<Coordinator> create({
    required LocalNodeRepository localNodeRepository,
    required ChannelRepository channelRepository,
    required EntryRepository entryRepository,
    PeerRepository? peerRepository,
    MessagePort? messagePort,
    TimePort? timePort,
    Random? random,
    CoordinatorConfig? config,
    LogCallback? onLog,
  }) async {
    peerRepository ??= InMemoryPeerRepository();
    final cfg = config ?? CoordinatorConfig.defaults;

    final localNode = await localNodeRepository.resolveNodeId();

    // Create event controller before the registry so peer lifecycle
    // events can be sinked into it. Without a sink the long-lived
    // registry would buffer events forever (nothing drains it).
    final eventsController = StreamController<DomainEvent>.broadcast();

    final peerRegistry = PeerRegistry(
      localNode: localNode,
      onEvent: (event) {
        if (!eventsController.isClosed) {
          eventsController.add(event);
        }
      },
    );

    HlcClock? hlcClock;
    if (timePort != null) {
      final timeSource = TimeSource(timePort);
      hlcClock = HlcClock(timeSource, maxDrift: cfg.hlcMaxDrift);

      final clockState = await localNodeRepository.getClockState();
      if (clockState != Hlc.zero) {
        hlcClock.restore(clockState);
      }
    }

    // Wrap the channel repository in an identity map so that all consumers
    // (ChannelService, _loadChannels, _loadExistingChannels) share the same
    // in-memory object references. Persistent repositories (e.g. Hive-backed)
    // return new objects on each findById(), which breaks the gossip engine's
    // assumption that channel aggregates are mutated in-place.
    final cachedChannelRepo = CachingChannelRepository(channelRepository);

    final materializationService = MaterializationService(
      entryRepository: entryRepository,
    );

    // Declared ahead of the services so their event callbacks can delegate
    // to coordinator instance methods (assigned below, invoked only at
    // runtime once construction has completed).
    late final Coordinator coordinator;

    final channelService = ChannelService(
      localNode: localNode,
      hlcClock: hlcClock,
      channelRepository: cachedChannelRepo,
      entryRepository: entryRepository,
      localNodeRepository: localNodeRepository,
      // Hardcoded until wire version becomes a coordinator config option.
      // v1: the membership codec doesn't parse the v2 marker yet, so the
      // active send codec must stay v1 until that receiver-side work
      // lands too.
      maxPayloadBytes: SyncMessageCodec.maxEntryPayloadForBudget(
        cfg.maxMessageBytes,
        WireVersion.v1,
      ),
      materializationService: materializationService,
      onEvent: (event) => coordinator._onChannelServiceEvent(event),
      // Without this the services' emitted errors go to a null callback
      // and vanish, violating the no-silent-errors rule.
      onError: (error) => coordinator._handleError(error),
    );
    final peerService = PeerService(
      registry: peerRegistry,
      repository: peerRepository,
    );

    coordinator = Coordinator._(
      localNode: localNode,
      peerRegistry: peerRegistry,
      channelService: channelService,
      peerService: peerService,
      peerRepository: peerRepository,
      localNodeRepository: localNodeRepository,
      channelRepository: cachedChannelRepo,
      entryRepository: entryRepository,
      config: cfg,
      hlcClock: hlcClock,
      timePort: timePort,
      eventsController: eventsController,
      onLog: onLog,
    );

    if (messagePort != null && timePort != null) {
      // GossipEngine computes its interval from per-peer RTT data in PeerRegistry.
      // FailureDetector gets its own RttTracker as a conservative fallback
      // for peers that don't yet have per-peer RTT estimates.
      final failureDetectorRttTracker = RttTracker();

      coordinator._gossipEngine = GossipEngine(
        // Hardcoded until wire version becomes a coordinator config
        // option. v1: the membership codec doesn't parse the v2 marker
        // yet, so the active send codec must stay v1 until that
        // receiver-side work lands too.
        codec: SyncMessageCodec(wireVersion: WireVersion.v1),
        localNode: localNode,
        peerDirectory: MembershipPeerDirectory(peerRegistry),
        entryRepository: entryRepository,
        timePort: timePort,
        messagePort: messagePort,
        onError: coordinator._handleError,
        onEntriesMerged: coordinator._handleEntriesMerged,
        onLog: onLog,
        hlcClock: hlcClock,
        localNodeRepository: localNodeRepository,
        random: random,
        adaptiveTimingEnabled: cfg.adaptiveTimingEnabled,
        gossipInterval: cfg.gossipInterval,
        maxMessageBytes: cfg.maxMessageBytes,
      );

      coordinator._failureDetector = FailureDetector(
        codec: MembershipMessageCodec(),
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timePort,
        messagePort: messagePort,
        onError: coordinator._handleError,
        onLog: onLog,
        random: random,
        failureThreshold: cfg.suspicionThreshold,
        unreachableThreshold: cfg.unreachableThreshold,
        unreachableProbeInterval: cfg.unreachableProbeInterval,
        probeInterval: cfg.probeInterval,
        pingTimeout: cfg.pingTimeout,
        rttTracker: failureDetectorRttTracker,
      );
    }

    await coordinator._loadExistingChannels();

    return coordinator;
  }

  /// Loads existing channels from repository into the facade cache.
  ///
  /// Called during coordinator creation to restore access to persisted channels.
  Future<void> _loadExistingChannels() async {
    final channelIds = await _channelRepository.listIds();
    for (final id in channelIds) {
      _channelFacades[id] = Channel(id: id, service: _channelService);
    }
  }

  /// Transitions to a new state and emits on the state changes stream.
  void _transitionTo(SyncState newState) {
    _state = newState;
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  /// Handles errors from protocol services and emits them on the error
  /// stream. Once disposed, [_errorsController] is closed and has no
  /// listeners left to reach — an error surfacing after that point (e.g.
  /// a pending async callback started before dispose) falls back to
  /// [_onLog] instead of vanishing silently (no-silent-errors rule).
  ///
  /// [stackTrace], when the caller has one, rides along to that same
  /// [_onLog] fallback so a post-dispose failure is still debuggable from
  /// its origin instead of just its message.
  void _handleError(SyncError error, [StackTrace? stackTrace]) {
    if (!_errorsController.isClosed) {
      _errorsController.add(error);
      return;
    }
    _onLog?.call(
      LogLevel.error,
      'error after dispose: $error',
      error,
      stackTrace,
    );
  }

  /// Fans a domain event from [ChannelService] out to the app's event stream
  /// and drives reactive dissemination: a local write ([EntryAppended]) is
  /// handed to the gossip engine so it can push the new entry to peers
  /// immediately (debounced) instead of waiting for the next periodic round.
  void _onChannelServiceEvent(DomainEvent event) {
    if (!_eventsController.isClosed) {
      _eventsController.add(event);
    }
    if (event is EntryAppended) {
      _gossipEngine?.notifyLocalWrite(
        event.channelId,
        event.streamId,
        event.entry,
      );
    }
  }

  /// Starts the periodic auto-compaction loop (applies each stream's
  /// retention policy). No-op without a timer port or when the interval is
  /// disabled (null / non-positive).
  ///
  /// Constructs [_compactionScheduler] on first use — it needs the resolved
  /// [_timePort] and [CoordinatorConfig.compactionInterval], neither of
  /// which are available at construction time in local-only mode — then
  /// reuses it across subsequent stop/start or pause/resume cycles.
  void _startCompaction() {
    final timePort = _timePort;
    final interval = _config.compactionInterval;
    if (timePort == null || interval == null || interval <= Duration.zero) {
      return;
    }
    _compactionScheduler ??= GenerationScheduler(
      timePort: timePort,
      nextDelay: () => interval,
      tick: _channelService.compactAll,
      onTickError: (error, stackTrace) => _handleError(
        StorageSyncError(
          SyncErrorType.storageFailure,
          'Auto-compaction failed: $error',
          occurredAt: DateTime.now(),
          cause: error,
        ),
        stackTrace,
      ),
      onSchedulingError: (error, stackTrace) => _handleError(
        StorageSyncError(
          SyncErrorType.storageFailure,
          'Auto-compaction scheduling failed: $error',
          occurredAt: DateTime.now(),
          cause: error,
        ),
        stackTrace,
      ),
    );
    _compactionScheduler!.start();
  }

  /// Stops the compaction loop (stop/pause/dispose). A no-op if the
  /// scheduler was never constructed (never started, or local-only mode).
  void _stopCompaction() {
    _compactionScheduler?.stop();
  }

  /// Handles entries merged from peers and emits EntriesMerged events.
  Future<void> _handleEntriesMerged(
    ChannelId channelId,
    StreamId streamId,
    List<LogEntry> entries,
    bool containsOutOfOrderEntries,
  ) async {
    if (_eventsController.isClosed || entries.isEmpty) return;

    // Fold merged entries into registered materializers. A materializer is
    // app code: letting its exception propagate would abort this handler
    // (suppressing the EntriesMerged event for entries that ARE durably
    // merged, and stalling the engine's catch-up continuation) and land in
    // the engine's dispatcher catch-all blaming the PEER for message
    // corruption.
    try {
      await _channelService.foldMergedEntries(
        channelId,
        streamId,
        entries,
        containsOutOfOrderEntries: containsOutOfOrderEntries,
      );
    } catch (e, st) {
      _handleError(
        StorageSyncError(
          SyncErrorType.storageFailure,
          'Materializer failed folding merged entries for '
          '$channelId/$streamId: $e',
          occurredAt: DateTime.now(),
          cause: e,
        ),
        st,
      );
    }

    final newVersion = await _entryRepository.getVersionVector(
      channelId,
      streamId,
    );

    // Re-check after the awaits above: dispose() may have closed the
    // controller while the fold / version-vector reads were in flight.
    if (_eventsController.isClosed) return;

    _eventsController.add(
      EntriesMerged(
        channelId,
        streamId,
        entries,
        newVersion,
        containsOutOfOrderEntries: containsOutOfOrderEntries,
        occurredAt: DateTime.now(),
      ),
    );
  }

  /// Loads all channels from the repository into a map.
  Future<Map<ChannelId, ChannelAggregate>> _loadChannels() async {
    final channelIds = await _channelRepository.listIds();
    final channels = <ChannelId, ChannelAggregate>{};

    for (final id in channelIds) {
      final channel = await _channelRepository.findById(id);
      if (channel != null) {
        channels[id] = channel;
      }
    }

    return channels;
  }

  /// Creates a new channel.
  ///
  /// The channel starts with the local node as the only member.
  Future<Channel> createChannel(ChannelId channelId) async {
    await _channelService.createChannel(channelId);

    final facade = Channel(id: channelId, service: _channelService);
    _channelFacades[channelId] = facade;

    if (_state == SyncState.running && _gossipEngine != null) {
      final channels = await _loadChannels();
      _gossipEngine!.setChannels(channels);
    }

    return facade;
  }

  /// Returns the facade for an existing channel, or null if not found.
  Channel? getChannel(ChannelId channelId) {
    return _channelFacades[channelId];
  }

  /// Removes a channel and all its associated data — entries, materializer
  /// state, and the channel aggregate itself — from persistence, emitting
  /// [ChannelRemoved]. If the gossip engine is running, it stops syncing
  /// this channel immediately rather than only after the next stop/start
  /// or pause/resume cycle.
  ///
  /// Returns true if the channel was removed, false if it didn't exist.
  Future<bool> removeChannel(ChannelId channelId) async {
    if (!_channelFacades.containsKey(channelId)) {
      return false;
    }

    final removed = await _channelService.removeChannel(channelId);
    if (!removed) {
      return false;
    }

    _channelFacades.remove(channelId);

    if (_state == SyncState.running && _gossipEngine != null) {
      final channels = await _loadChannels();
      _gossipEngine!.setChannels(channels);
    }

    return true;
  }

  /// Returns the list of all channel IDs.
  List<ChannelId> get channelIds {
    return _channelFacades.keys.toList();
  }

  /// Returns the list of channels where the given peer is a member.
  ///
  /// This provides O(n) lookup where n is the number of channels.
  /// For frequent lookups, consider caching the result.
  ///
  /// Returns an empty list if the peer is not a member of any channels.
  Future<List<ChannelId>> channelsForPeer(NodeId peerId) async {
    final result = <ChannelId>[];

    // Snapshot the keys — the loop body awaits (see getResourceUsage).
    for (final channelId in _channelFacades.keys.toList()) {
      final channel = await _channelRepository.findById(channelId);
      if (channel != null && channel.hasMember(peerId)) {
        result.add(channelId);
      }
    }

    return result;
  }

  /// Adds a peer to the system.
  ///
  /// The peer starts in [PeerStatus.reachable] and will be included in:
  /// - Gossip peer selection for anti-entropy
  /// - SWIM failure detection probing (after grace period or successful probe)
  ///
  /// If [displayName] is not provided, defaults to a truncated form of the
  /// node ID.
  ///
  /// A startup grace period prevents false positive failure detections while
  /// the transport layer is still establishing bidirectional connectivity.
  /// The grace period is cleared early if [FailureDetector.probeNewPeer]
  /// succeeds.
  ///
  /// Throws [DomainException] if attempting to add the local node as a peer.
  Future<void> addPeer(NodeId id, {String? displayName}) async {
    await _peerService.addPeer(id, displayName: displayName);
    _holdProbingDuringStartupGrace(id);
    _bootstrapPeerRtt(id);
    _syncWithNewPeer(id);
  }

  /// Prevents false-positive failure detection while the transport is still
  /// establishing bidirectional connectivity. [_probeNewPeerWithRetry]
  /// clears the hold early on its first successful probe.
  void _holdProbingDuringStartupGrace(NodeId id) {
    if (_failureDetector != null &&
        _config.startupGracePeriod > Duration.zero) {
      _failureDetector!.holdProbing(id, _config.startupGracePeriod);
    }
  }

  /// Fire-and-forget: bootstraps a per-peer RTT estimate within ~200ms
  /// instead of waiting for random probe selection (up to ~45s with 5
  /// peers and a 9s interval). [_probeNewPeerWithRetry] retries because the
  /// remote peer's receive path may not be bidirectional yet.
  void _bootstrapPeerRtt(NodeId id) {
    if (_failureDetector != null && _state == SyncState.running) {
      final detector = _failureDetector!;
      unawaited(_probeNewPeerWithRetry(detector, id));
    }
  }

  /// Fire-and-forget: starts anti-entropy with the new peer immediately
  /// (sync-on-connect) rather than waiting for the random periodic round to
  /// select it — the gossip analogue of [_bootstrapPeerRtt]. Speeds
  /// reconciliation on a fresh join or a healed partition.
  void _syncWithNewPeer(NodeId id) {
    if (_gossipEngine != null && _state == SyncState.running) {
      unawaited(_gossipEngine!.syncWithPeer(id));
    }
  }

  /// Probes a newly added peer with retry to bootstrap per-peer RTT.
  ///
  /// The transport layer may not be fully bidirectional when addPeer is
  /// called — the remote peer's receive path may still be initializing.
  /// Retrying handles this: the first probe may timeout, but subsequent
  /// attempts succeed once the remote transport is ready.
  ///
  /// On success, clears the probing hold to allow normal failure detection.
  Future<void> _probeNewPeerWithRetry(
    FailureDetector detector,
    NodeId peerId,
  ) async {
    const maxAttempts = 3;
    try {
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        if (_state != SyncState.running) return;
        if (_peerRegistry.getPeer(peerId) == null) return;

        final gotAck = await detector.probeNewPeer(peerId);
        if (gotAck) {
          // Clear the probing hold since we confirmed connectivity.
          detector.clearProbingHold(peerId);
          return;
        }
      }
    } catch (e, st) {
      _handleError(
        PeerSyncError(
          peerId,
          SyncErrorType.peerUnreachable,
          'probeNewPeer failed for $peerId: $e',
          occurredAt: DateTime.now(),
          cause: e,
        ),
        st,
      );
    }
  }

  /// Removes a peer from the system.
  ///
  /// The peer will no longer participate in gossip or failure detection.
  /// Any pending operations with this peer will be cancelled.
  Future<void> removePeer(NodeId id) async {
    // Drop the probing hold and probe-attempt tracking so entries don't
    // accumulate under peer churn (the peer is gone, not merely confirmed
    // reachable — see FailureDetector.forgetPeer).
    _failureDetector?.forgetPeer(id);
    // Drop in-flight pulls to this peer: they can never complete, and a
    // stale flag would both block re-requesting after a fast reconnect and
    // wedge gossipSyncActivity.isQuiescent.
    _gossipEngine?.clearPendingRequestsForPeer(id);
    await _peerService.removePeer(id);
  }

  /// The internal failure detector, exposed for tests only.
  @visibleForTesting
  FailureDetector? get failureDetectorForTesting => _failureDetector;

  /// The internal gossip engine, exposed for tests only.
  @visibleForTesting
  GossipEngine? get gossipEngineForTesting => _gossipEngine;

  /// The internal compaction scheduler, exposed for tests only.
  @visibleForTesting
  GenerationScheduler? get compactionSchedulerForTesting =>
      _compactionScheduler;

  /// Returns all registered peers.
  ///
  /// This includes peers in any status (reachable, suspected, unreachable).
  List<Peer> get peers {
    return _peerRegistry.allPeers;
  }

  /// Returns only reachable peers.
  ///
  /// These are peers that have recently responded to probes and are
  /// eligible for gossip and message routing.
  List<Peer> get reachablePeers {
    return _peerRegistry.reachablePeers;
  }

  /// Returns the current HLC clock state, or null if no clock is configured.
  ///
  /// When a [LocalNodeRepository] is provided to [create], the clock state
  /// is persisted automatically on each entry write. On the next [create]
  /// call, it is restored to preserve timestamp monotonicity across restarts.
  ///
  /// Returns null when no [TimePort] was provided (local-only mode).
  Hlc? get currentClockState => _hlcClock?.current;

  /// Returns metrics for a specific peer, or null if not found.
  ///
  /// Metrics include message counts, byte counts, and sliding window data
  /// for rate limiting.
  PeerMetrics? getPeerMetrics(NodeId id) {
    return _peerRegistry.getMetrics(id);
  }

  /// Returns current resource usage statistics.
  ///
  /// Provides a snapshot of peer count, channel count, total entries,
  /// and storage usage across all channels and streams.
  Future<ResourceUsage> getResourceUsage() async {
    int totalEntries = 0;
    int totalStorageBytes = 0;

    // Snapshot the keys: the loop body awaits, and a createChannel/
    // removeChannel completing in between would throw
    // ConcurrentModificationError on the live keys view.
    for (final channelId in _channelFacades.keys.toList()) {
      final channel = await _channelRepository.findById(channelId);
      if (channel != null) {
        for (final streamId in channel.streamIds) {
          totalEntries += await _entryRepository.entryCount(
            channelId,
            streamId,
          );
          totalStorageBytes += await _entryRepository.sizeBytes(
            channelId,
            streamId,
          );
        }
      }
    }

    return ResourceUsage(
      peerCount: _peerRegistry.allPeers.length,
      channelCount: _channelFacades.length,
      totalEntries: totalEntries,
      totalStorageBytes: totalStorageBytes,
    );
  }

  /// A coarse snapshot of gossip sync activity for "syncing…" vs "up to
  /// date" UI. See [GossipSyncActivity]. In local-only mode (no gossip
  /// engine) it reports quiescent with zero activity.
  GossipSyncActivity get gossipSyncActivity => GossipSyncActivity(
    outstandingPulls: _gossipEngine?.outstandingPullCount ?? 0,
    mergedBatches: _gossipEngine?.mergedBatchCount ?? 0,
  );

  /// Returns the current health status of the coordinator.
  ///
  /// Provides a comprehensive view including sync state, local node info,
  /// resource usage, and connectivity status.
  Future<HealthStatus> getHealth() async {
    final resourceUsage = await getResourceUsage();

    return HealthStatus(
      state: _state,
      localNode: localNode,
      resourceUsage: resourceUsage,
      reachablePeerCount: _peerRegistry.reachablePeers.length,
    );
  }

  /// Returns the current adaptive timing status, or null if adaptive
  /// timing is not active (no message/time ports provided).
  ///
  /// Provides a snapshot of RTT estimates, effective protocol intervals,
  /// and transport backpressure state for observability.
  AdaptiveTimingStatus? getAdaptiveTimingStatus() {
    if (_gossipEngine == null || _failureDetector == null) {
      return null;
    }

    // Each context assembles its own timing state; this facade only
    // reshapes the two snapshots into the public, cross-context DTO.
    final membershipTiming = _failureDetector!.timingSnapshot();

    return AdaptiveTimingStatus(
      smoothedRtt: membershipTiming.smoothedRtt,
      rttVariance: membershipTiming.rttVariance,
      rttSampleCount: membershipTiming.sampleCount,
      hasRttSamples: membershipTiming.hasSamples,
      effectiveGossipInterval: _gossipEngine!.effectiveGossipInterval,
      effectivePingTimeout: membershipTiming.pingTimeout,
      effectiveProbeInterval: membershipTiming.probeInterval,
      totalPendingSendCount: _gossipEngine!.transportBacklog,
      perPeerRtt: membershipTiming.perPeerRtt,
    );
  }

  /// Returns the current state of the coordinator.
  SyncState get state => _state;

  /// Stream of state changes emitted when the coordinator transitions
  /// between [SyncState] values.
  ///
  /// Useful for binding UI to sync status or logging lifecycle transitions.
  /// Does not emit when an idempotent call (e.g., [start] when already
  /// running) results in no actual state change.
  Stream<SyncState> get stateChanges => _stateController.stream;

  /// Returns true if the coordinator has been disposed.
  bool get isDisposed => _state == SyncState.disposed;

  /// Returns true if network synchronization is enabled.
  ///
  /// This is true when both [MessagePort] and [TimePort] were provided
  /// to [create], enabling gossip protocol and failure detection.
  /// When false, the coordinator operates in local-only mode.
  bool get hasNetworkSync => _gossipEngine != null;

  /// Stream of domain events emitted by the system.
  ///
  /// Carries every [SyncEvent] and [MembershipEvent]; see those sealed
  /// families for the full set.
  ///
  /// Applications can observe this stream for logging, metrics, or event sourcing.
  Stream<DomainEvent> get events => _eventsController.stream;

  /// Stream of sync errors that occur during operation.
  ///
  /// Errors include:
  /// - PeerSyncError (peer unreachable, message send failures)
  /// - ChannelSyncError (channel operation failures)
  /// - StorageSyncError (repository failures)
  ///
  /// Applications should observe this stream for error handling and monitoring.
  Stream<SyncError> get errors => _errorsController.stream;

  /// Starts the coordinator and begins synchronization.
  ///
  /// Transitions from [SyncState.stopped] or [SyncState.paused] to [SyncState.running].
  /// When running, the coordinator will:
  /// - Start gossip protocol
  /// - Start failure detection
  /// - Begin processing events
  ///
  /// Returns immediately if already running (idempotent).
  /// Throws [StateError] if disposed.
  Future<void> start() async {
    if (_state == SyncState.running) return;
    if (_state == SyncState.disposed) {
      throw StateError('Cannot start a disposed coordinator');
    }

    // Do all awaited work BEFORE transitioning, so there is no window in
    // which the state says running while the engines aren't started (or
    // vice versa after an interleaved stop()).
    final epoch = _lifecycleEpoch;
    var channels = const <ChannelId, ChannelAggregate>{};
    if (_gossipEngine != null) {
      channels = await _loadChannels();
    }

    if (_state == SyncState.disposed) {
      throw StateError('Cannot start a disposed coordinator');
    }
    if (epoch != _lifecycleEpoch || _state == SyncState.running) {
      // A stop() (epoch bump) or a concurrent start() interleaved with
      // the channel load — the later call wins; do not start engines.
      return;
    }

    _transitionTo(SyncState.running);

    if (_gossipEngine != null) {
      _gossipEngine!.startListening(channels);
      _gossipEngine!.start();
    }

    if (_failureDetector != null) {
      _failureDetector!.startListening();
      _failureDetector!.start();
    }

    _startCompaction();
  }

  /// Stops the coordinator and ceases all synchronization.
  ///
  /// Transitions from [SyncState.running] or [SyncState.paused] to [SyncState.stopped].
  /// When stopped, all protocol services are halted but the coordinator
  /// can be restarted with [start].
  ///
  /// Returns immediately if already stopped (idempotent).
  /// Throws [StateError] if disposed.
  Future<void> stop() async {
    // Invalidate any in-flight start() even if we early-return below —
    // "stop" is the caller's latest intent.
    _lifecycleEpoch++;
    if (_state == SyncState.stopped) return;
    if (_state == SyncState.disposed) {
      throw StateError('Cannot stop a disposed coordinator');
    }

    if (_gossipEngine != null) {
      _gossipEngine!.stop();
      _gossipEngine!.stopListening();
    }

    if (_failureDetector != null) {
      _failureDetector!.stop();
      _failureDetector!.stopListening();
    }

    _stopCompaction();
    _transitionTo(SyncState.stopped);
  }

  /// Pauses synchronization without fully stopping.
  ///
  /// Transitions from [SyncState.running] to [SyncState.paused].
  /// When paused, protocol services are temporarily halted but can
  /// be quickly resumed with [resume].
  ///
  /// Throws [StateError] if not running or if disposed.
  Future<void> pause() async {
    if (_state != SyncState.running) {
      throw StateError('Can only pause a running coordinator');
    }

    if (_gossipEngine != null) {
      _gossipEngine!.stop();
      // Keep listening to handle incoming messages
    }

    if (_failureDetector != null) {
      _failureDetector!.stop();
      // Keep listening to handle incoming messages
    }

    _stopCompaction();
    _transitionTo(SyncState.paused);
  }

  /// Resumes synchronization from a paused state.
  ///
  /// Transitions from [SyncState.paused] to [SyncState.running].
  ///
  /// Throws [StateError] if not paused or if disposed.
  Future<void> resume() async {
    if (_state != SyncState.paused) {
      throw StateError('Can only resume a paused coordinator');
    }

    // Reload the channel map: createChannel/removeChannel only push
    // updates to the engine while running, so channels created or removed
    // during the pause would otherwise never (or forever) be gossiped.
    if (_gossipEngine != null) {
      final channels = await _loadChannels();
      if (_state != SyncState.paused) return; // interleaved stop/dispose
      _gossipEngine!.setChannels(channels);
    }

    _transitionTo(SyncState.running);

    if (_gossipEngine != null) {
      _gossipEngine!.start();
    }

    if (_failureDetector != null) {
      _failureDetector!.start();
    }

    _startCompaction();
  }

  /// Disposes the coordinator and releases all resources.
  ///
  /// After disposal, the coordinator cannot be reused. All protocol services
  /// are stopped and stream controllers are closed.
  ///
  /// This method is idempotent - calling it multiple times is safe.
  Future<void> dispose() async {
    if (_state == SyncState.disposed) {
      return; // Already disposed
    }

    // Reject further facade writes immediately: a payload accepted after
    // dispose would be durable-but-orphaned — no engine to sync it, its
    // events dropped at closed controllers.
    _channelService.markDisposed();

    if (_state == SyncState.running || _state == SyncState.paused) {
      if (_gossipEngine != null) {
        _gossipEngine!.stop();
        _gossipEngine!.stopListening();
      }

      if (_failureDetector != null) {
        _failureDetector!.stop();
        _failureDetector!.stopListening();
      }
    }

    _stopCompaction();
    _transitionTo(SyncState.disposed);

    // Close materializer state streams so their listeners get onDone.
    await _channelService.disposeAllMaterializers();

    await _eventsController.close();
    await _errorsController.close();
    await _stateController.close();
  }

  /// Destroys the coordinator: disposes it (stopping protocols and closing
  /// streams), wipes all channels, entries, and peers from their
  /// repositories, and resets the local node identity (node ID, clock).
  ///
  /// After destruction, the coordinator cannot be reused. Call
  /// [Coordinator.create] with the same repositories to start fresh
  /// with a new node identity.
  ///
  /// **Important:** A new node ID is generated on the next [create] call
  /// because peers track version vectors keyed by node ID. Reusing the
  /// old ID after clearing entries would cause peers to silently skip
  /// new entries.
  ///
  /// This method is idempotent — calling it multiple times is safe.
  ///
  /// Example (logout/login flow):
  /// ```dart
  /// await coordinator.destroy();
  /// coordinator = await Coordinator.create(
  ///   localNodeRepository: localNodeRepo, // generates new nodeId
  ///   channelRepository: channelRepo,
  ///   entryRepository: entryRepo,
  ///   messagePort: messagePort,
  ///   timePort: timePort,
  /// );
  /// await coordinator.start();
  /// ```
  Future<void> destroy() async {
    await dispose();

    await _channelRepository.clearAll();
    await _entryRepository.clearAll();
    await _peerRepository.clearAll();
    await _localNodeRepository.reset();
  }
}
