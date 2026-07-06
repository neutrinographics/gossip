import 'dart:async';
import 'package:meta/meta.dart';
import 'dart:math';
import '../application/observability/log_level.dart';
import '../application/services/channel_service.dart';
import '../application/services/materialization_service.dart';
import '../application/services/peer_service.dart';
import '../domain/aggregates/peer_registry.dart';
import '../domain/aggregates/channel_aggregate.dart';
import '../domain/entities/peer.dart';
import '../domain/entities/peer_metrics.dart';
import '../domain/interfaces/channel_repository.dart';
import '../infrastructure/repositories/caching_channel_repository.dart';
import '../infrastructure/repositories/in_memory_peer_repository.dart';
import '../domain/interfaces/entry_repository.dart';
import '../domain/interfaces/local_node_repository.dart';
import '../domain/interfaces/peer_repository.dart';
import '../domain/value_objects/channel_id.dart';
import '../domain/value_objects/log_entry.dart';
import '../domain/value_objects/node_id.dart';
import '../domain/value_objects/stream_id.dart';
import '../domain/events/domain_event.dart';
import '../domain/errors/sync_error.dart';
import '../domain/services/hlc_clock.dart';
import '../domain/services/rtt_tracker.dart';
import '../domain/value_objects/hlc.dart';
import '../domain/value_objects/rtt_estimate.dart';
import '../domain/services/time_source.dart';
import '../infrastructure/ports/message_port.dart';
import '../infrastructure/ports/time_port.dart';
import '../protocol/gossip_engine.dart';
import '../protocol/failure_detector.dart';
import '../protocol/protocol_codec.dart';
import 'adaptive_timing_status.dart';
import 'channel.dart';
import 'coordinator_config.dart';
import 'health_status.dart';
import 'resource_usage.dart';
import 'sync_state.dart';

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
///   timerPort: RealTimePort(),               // Or InMemoryTimePort for testing
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

  /// HLC clock for reading current clock state. Null in local-only mode.
  final HlcClock? _hlcClock;

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
    required GossipEngine? gossipEngine,
    required FailureDetector? failureDetector,
    required StreamController<DomainEvent> eventsController,
  }) : _peerRegistry = peerRegistry,
       _channelService = channelService,
       _peerService = peerService,
       _peerRepository = peerRepository,
       _localNodeRepository = localNodeRepository,
       _channelRepository = channelRepository,
       _entryRepository = entryRepository,
       _config = config,
       _hlcClock = hlcClock,
       _gossipEngine = gossipEngine,
       _failureDetector = failureDetector,
       _eventsController = eventsController;

  /// Creates a new coordinator instance.
  ///
  /// This is the main entry point for applications using the library.
  ///
  /// [messagePort] and [timerPort] are optional. If both are provided, the
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
  static Future<Coordinator> create({
    required LocalNodeRepository localNodeRepository,
    required ChannelRepository channelRepository,
    required EntryRepository entryRepository,
    PeerRepository? peerRepository,
    MessagePort? messagePort,
    TimePort? timerPort,
    Random? random,
    CoordinatorConfig? config,
    LogCallback? onLog,
  }) async {
    peerRepository ??= InMemoryPeerRepository();
    final cfg = config ?? CoordinatorConfig.defaults;

    // Resolve localNode from repository — single source of truth
    final localNode = await localNodeRepository.resolveNodeId();

    // Restore incarnation from LocalNodeRepository
    final incarnation = await localNodeRepository.getIncarnation();

    // Create event controller before the registry so peer lifecycle
    // events can be sinked into it. Without a sink the long-lived
    // registry would buffer events forever (nothing drains it).
    final eventsController = StreamController<DomainEvent>.broadcast();

    final peerRegistry = PeerRegistry(
      localNode: localNode,
      initialIncarnation: incarnation,
      onEvent: (event) {
        if (!eventsController.isClosed) {
          eventsController.add(event);
        }
      },
    );

    // Create HlcClock if TimePort is provided for proper timestamp generation
    HlcClock? hlcClock;
    if (timerPort != null) {
      final timeSource = TimeSource(timerPort);
      hlcClock = HlcClock(timeSource);

      // Restore clock state from LocalNodeRepository
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

    final channelService = ChannelService(
      localNode: localNode,
      hlcClock: hlcClock,
      channelRepository: cachedChannelRepo,
      entryRepository: entryRepository,
      localNodeRepository: localNodeRepository,
      maxPayloadBytes: ProtocolCodec.maxEntryPayloadForBudget(
        cfg.maxDeltaResponseBytes,
      ),
      materializationService: materializationService,
      onEvent: (event) {
        if (!eventsController.isClosed) {
          eventsController.add(event);
        }
      },
    );
    final peerService = PeerService(
      registry: peerRegistry,
      localNodeRepository: localNodeRepository,
      repository: peerRepository,
    );

    final coordinator = Coordinator._(
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
      gossipEngine: null, // Set below after coordinator is created
      failureDetector: null, // Set below after coordinator is created
      eventsController: eventsController,
    );

    // Create GossipEngine and FailureDetector if ports are provided, wiring error callbacks
    if (messagePort != null && timerPort != null) {
      // GossipEngine computes its interval from per-peer RTT data in PeerRegistry.
      // FailureDetector gets its own RttTracker as a conservative fallback
      // for peers that don't yet have per-peer RTT estimates.
      final failureDetectorRttTracker = RttTracker();

      coordinator._gossipEngine = GossipEngine(
        localNode: localNode,
        peerRegistry: peerRegistry,
        entryRepository: entryRepository,
        timePort: timerPort,
        messagePort: messagePort,
        onError: coordinator._handleError,
        onEntriesMerged: coordinator._handleEntriesMerged,
        onLog: onLog,
        hlcClock: hlcClock,
        localNodeRepository: localNodeRepository,
        random: random,
        adaptiveTimingEnabled: cfg.adaptiveTimingEnabled,
        gossipInterval: cfg.gossipInterval,
        maxDeltaResponseBytes: cfg.maxDeltaResponseBytes,
      );

      coordinator._failureDetector = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timerPort,
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

    // Load existing channels from repository into facade cache
    await coordinator._loadExistingChannels();

    return coordinator;
  }

  /// Loads existing channels from repository into the facade cache.
  ///
  /// Called during coordinator creation to restore access to persisted channels.
  Future<void> _loadExistingChannels() async {
    final channelIds = await _channelRepository.listIds();
    for (final id in channelIds) {
      _channelFacades[id] = Channel(id: id, channelService: _channelService);
    }
  }

  /// Transitions to a new state and emits on the state changes stream.
  void _transitionTo(SyncState newState) {
    _state = newState;
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  /// Handles errors from protocol services and emits them on the error stream.
  void _handleError(SyncError error) {
    if (!_errorsController.isClosed) {
      _errorsController.add(error);
    }
  }

  /// Handles entries merged from peers and emits EntriesMerged events.
  Future<void> _handleEntriesMerged(
    ChannelId channelId,
    StreamId streamId,
    List<LogEntry> entries,
    bool containsOutOfOrderEntries,
  ) async {
    if (_eventsController.isClosed || entries.isEmpty) return;

    // Fold merged entries into registered materializers
    await _channelService.foldMergedEntries(
      channelId,
      streamId,
      entries,
      containsOutOfOrderEntries: containsOutOfOrderEntries,
    );

    // Compute the new version vector for the stream
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
    // Create the channel via the service (events are emitted via onEvent callback)
    await _channelService.createChannel(channelId);

    // Create and cache the facade
    final facade = Channel(id: channelId, channelService: _channelService);
    _channelFacades[channelId] = facade;

    // Update GossipEngine with new channel if running
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

  /// Removes a channel and all its associated data.
  ///
  /// This operation:
  /// 1. Removes the channel from the facade cache
  /// 2. Clears all entries for this channel from the entry store
  /// 3. Deletes the channel from the repository
  /// 4. Updates the gossip engine (if running) to stop syncing this channel
  /// 5. Emits a [ChannelRemoved] event
  ///
  /// Returns true if the channel was removed, false if it didn't exist.
  Future<bool> removeChannel(ChannelId channelId) async {
    // Check if channel exists in our cache
    if (!_channelFacades.containsKey(channelId)) {
      return false;
    }

    // Remove via service (clears entries and deletes from repository)
    final removed = await _channelService.removeChannel(channelId);
    if (!removed) {
      return false;
    }

    // Remove from facade cache
    _channelFacades.remove(channelId);

    // Update GossipEngine with removed channel if running
    if (_state == SyncState.running && _gossipEngine != null) {
      final channels = await _loadChannels();
      _gossipEngine!.setChannels(channels);
    }

    // Emit ChannelRemoved event
    if (!_eventsController.isClosed) {
      _eventsController.add(
        ChannelRemoved(channelId, occurredAt: DateTime.now()),
      );
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
  /// The grace period is cleared early if [probeNewPeer] succeeds.
  ///
  /// Throws [Exception] if attempting to add the local node as a peer.
  Future<void> addPeer(NodeId id, {String? displayName}) async {
    await _peerService.addPeer(id, displayName: displayName);

    // Set probing hold to prevent false positives during connection startup.
    // The hold is cleared early if probeNewPeer succeeds below.
    if (_failureDetector != null &&
        _config.startupGracePeriod > Duration.zero) {
      final holdUntilMs =
          _failureDetector!.timePort.nowMs +
          _config.startupGracePeriod.inMilliseconds;
      _failureDetector!.setProbingHold(id, holdUntilMs);
    }

    // Fire-and-forget immediate probe to bootstrap per-peer RTT estimate.
    // Gets first RTT sample within ~200ms instead of waiting for random
    // probe selection (which could take ~45s with 5 peers and 9s interval).
    //
    // Retries up to 3 times on timeout because the transport layer may
    // not be fully bidirectional yet when addPeer is called — the remote
    // peer's receive path may still be initializing.
    //
    // On success, clears the probing hold early since connectivity is confirmed.
    if (_failureDetector != null && _state == SyncState.running) {
      final detector = _failureDetector!;
      unawaited(_probeNewPeerWithRetry(detector, id));
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
    } catch (e) {
      _handleError(
        PeerSyncError(
          peerId,
          SyncErrorType.peerUnreachable,
          'probeNewPeer failed for $peerId: $e',
          occurredAt: DateTime.now(),
          cause: e,
        ),
      );
    }
  }

  /// Removes a peer from the system.
  ///
  /// The peer will no longer participate in gossip or failure detection.
  /// Any pending operations with this peer will be cancelled.
  Future<void> removePeer(NodeId id) async {
    // Drop any probing hold so entries don't accumulate under peer churn.
    _failureDetector?.clearProbingHold(id);
    await _peerService.removePeer(id);
  }

  /// The internal failure detector, exposed for tests only.
  @visibleForTesting
  FailureDetector? get failureDetectorForTesting => _failureDetector;

  /// The internal gossip engine, exposed for tests only.
  @visibleForTesting
  GossipEngine? get gossipEngineForTesting => _gossipEngine;

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

  /// Returns the local node's current incarnation number.
  ///
  /// The incarnation is incremented when this node refutes a false
  /// failure suspicion in SWIM protocol.
  int get localIncarnation {
    return _peerRegistry.localIncarnation;
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

  /// Returns the current health status of the coordinator.
  ///
  /// Provides a comprehensive view including sync state, local node info,
  /// resource usage, and connectivity status.
  Future<HealthStatus> getHealth() async {
    final resourceUsage = await getResourceUsage();

    return HealthStatus(
      state: _state,
      localNode: localNode,
      incarnation: _peerRegistry.localIncarnation,
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

    // Build per-peer RTT map and derive global fields from per-peer data.
    final perPeerRtt = <NodeId, RttEstimate>{};
    Duration? minSrtt;
    Duration? minSrttVariance;
    int totalSamples = 0;

    for (final peer in _peerRegistry.allPeers) {
      final rttEstimate = peer.metrics.rttEstimate;
      if (rttEstimate != null) {
        perPeerRtt[peer.id] = rttEstimate;
        totalSamples++;
        if (minSrtt == null || rttEstimate.smoothedRtt < minSrtt) {
          minSrtt = rttEstimate.smoothedRtt;
          minSrttVariance = rttEstimate.rttVariance;
        }
      }
    }

    // Fall back to global tracker when no per-peer data exists.
    final rttTracker = _failureDetector!.rttTracker;
    final smoothedRtt = minSrtt ?? rttTracker.smoothedRtt;
    final rttVariance = minSrttVariance ?? rttTracker.rttVariance;
    final sampleCount = totalSamples > 0
        ? totalSamples
        : rttTracker.sampleCount;
    final hasSamples = totalSamples > 0 ? true : rttTracker.hasReceivedSamples;

    return AdaptiveTimingStatus(
      smoothedRtt: smoothedRtt,
      rttVariance: rttVariance,
      rttSampleCount: sampleCount,
      hasRttSamples: hasSamples,
      effectiveGossipInterval: _gossipEngine!.effectiveGossipInterval,
      effectivePingTimeout: _failureDetector!.effectivePingTimeout,
      effectiveProbeInterval: _failureDetector!.effectiveProbeInterval,
      totalPendingSendCount: _gossipEngine!.messagePort.totalPendingSendCount,
      perPeerRtt: perPeerRtt,
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
  /// Events include:
  /// - MemberAdded, MemberRemoved
  /// - StreamCreated
  /// - PeerStatusChanged
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
  /// - Start gossip protocol (once integrated)
  /// - Start failure detection (once integrated)
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

    // Start GossipEngine if available
    if (_gossipEngine != null) {
      _gossipEngine!.startListening(channels);
      _gossipEngine!.start();
    }

    // Start FailureDetector if available
    if (_failureDetector != null) {
      _failureDetector!.startListening();
      _failureDetector!.start();
    }
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

    // Stop GossipEngine if available
    if (_gossipEngine != null) {
      _gossipEngine!.stop();
      _gossipEngine!.stopListening();
    }

    // Stop FailureDetector if available
    if (_failureDetector != null) {
      _failureDetector!.stop();
      _failureDetector!.stopListening();
    }

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

    // Pause GossipEngine if available
    if (_gossipEngine != null) {
      _gossipEngine!.stop();
      // Keep listening to handle incoming messages
    }

    // Pause FailureDetector if available
    if (_failureDetector != null) {
      _failureDetector!.stop();
      // Keep listening to handle incoming messages
    }

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

    // Resume GossipEngine if available
    if (_gossipEngine != null) {
      _gossipEngine!.start();
    }

    // Resume FailureDetector if available
    if (_failureDetector != null) {
      _failureDetector!.start();
    }
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

    // Stop if currently running or paused
    if (_state == SyncState.running || _state == SyncState.paused) {
      // Stop GossipEngine if available
      if (_gossipEngine != null) {
        _gossipEngine!.stop();
        _gossipEngine!.stopListening();
      }

      // Stop FailureDetector if available
      if (_failureDetector != null) {
        _failureDetector!.stop();
        _failureDetector!.stopListening();
      }
    }

    _transitionTo(SyncState.disposed);

    // Close materializer state streams so their listeners get onDone.
    await _channelService.disposeAllMaterializers();

    // Close stream controllers
    await _eventsController.close();
    await _errorsController.close();
    await _stateController.close();
  }

  /// Destroys the coordinator and wipes all persisted sync state.
  ///
  /// This method:
  /// 1. Disposes the coordinator (stops protocols, closes streams)
  /// 2. Clears all channels, entries, and peers from their repositories
  /// 3. Resets the local node identity (node ID, clock, incarnation)
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
  ///   timerPort: timerPort,
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
