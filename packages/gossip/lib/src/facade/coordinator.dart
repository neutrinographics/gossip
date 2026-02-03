import 'dart:async';
import 'dart:math';
import '../application/observability/log_level.dart';
import '../application/services/channel_service.dart';
import '../application/services/peer_service.dart';
import '../domain/aggregates/peer_registry.dart';
import '../domain/aggregates/channel_aggregate.dart';
import '../domain/entities/peer.dart';
import '../domain/entities/peer_metrics.dart';
import '../domain/interfaces/channel_repository.dart';
import '../domain/interfaces/entry_repository.dart';
import '../domain/interfaces/peer_repository.dart';
import '../domain/value_objects/channel_id.dart';
import '../domain/value_objects/log_entry.dart';
import '../domain/value_objects/node_id.dart';
import '../domain/value_objects/stream_id.dart';
import '../domain/events/domain_event.dart';
import '../domain/errors/sync_error.dart';
import '../domain/services/hlc_clock.dart';
import '../domain/services/rtt_tracker.dart';
import '../domain/services/time_source.dart';
import '../infrastructure/ports/message_port.dart';
import '../infrastructure/ports/time_port.dart';
import '../protocol/gossip_engine.dart';
import '../protocol/failure_detector.dart';
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
/// final peerRepo = InMemoryPeerRepository();
/// final entryRepo = InMemoryEntryRepository();
///
/// // Create coordinator
/// final coordinator = await Coordinator.create(
///   localNode: NodeId('device-1'),
///   channelRepository: channelRepo,
///   peerRepository: peerRepo,
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
///   localNode: NodeId('device-1'),
///   channelRepository: channelRepo,
///   peerRepository: peerRepo,
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

  /// Channel repository for loading channels.
  final ChannelRepository _channelRepository;

  /// Entry repository for gossip engine.
  final EntryRepository _entryRepository;

  /// Gossip engine for anti-entropy synchronization.
  GossipEngine? _gossipEngine;

  /// Failure detector for SWIM protocol.
  FailureDetector? _failureDetector;

  /// Cache of channel facades by ID.
  final Map<ChannelId, Channel> _channelFacades = {};

  /// Current state of the coordinator.
  SyncState _state = SyncState.stopped;

  /// Stream controller for domain events (provided during construction).
  final StreamController<DomainEvent> _eventsController;

  /// Stream controller for sync errors.
  final StreamController<SyncError> _errorsController =
      StreamController<SyncError>.broadcast();

  /// Private constructor. Use [create] factory method.
  Coordinator._({
    required this.localNode,
    required PeerRegistry peerRegistry,
    required ChannelService channelService,
    required PeerService peerService,
    required ChannelRepository channelRepository,
    required EntryRepository entryRepository,
    required GossipEngine? gossipEngine,
    required FailureDetector? failureDetector,
    required StreamController<DomainEvent> eventsController,
  }) : _peerRegistry = peerRegistry,
       _channelService = channelService,
       _peerService = peerService,
       _channelRepository = channelRepository,
       _entryRepository = entryRepository,
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
  /// [config] allows tuning of gossip and failure detection parameters.
  /// If null, default values are used.
  static Future<Coordinator> create({
    required NodeId localNode,
    required ChannelRepository channelRepository,
    required PeerRepository peerRepository,
    required EntryRepository entryRepository,
    MessagePort? messagePort,
    TimePort? timerPort,
    Random? random,
    CoordinatorConfig? config,
    LogCallback? onLog,
  }) async {
    final cfg = config ?? CoordinatorConfig.defaults;
    // Note: NodeId validates its own invariants (non-empty) in constructor

    final peerRegistry = PeerRegistry(
      localNode: localNode,
      initialIncarnation: 0,
    );

    // Create HlcClock if TimePort is provided for proper timestamp generation
    HlcClock? hlcClock;
    if (timerPort != null) {
      final timeSource = TimeSource(timerPort);
      hlcClock = HlcClock(timeSource);
    }

    // Create event controller to capture in closure before coordinator is created
    final eventsController = StreamController<DomainEvent>.broadcast();

    final channelService = ChannelService(
      localNode: localNode,
      hlcClock: hlcClock,
      channelRepository: channelRepository,
      entryRepository: entryRepository,
      onEvent: (event) {
        if (!eventsController.isClosed) {
          eventsController.add(event);
        }
      },
    );
    final peerService = PeerService(
      localNode: localNode,
      registry: peerRegistry,
      repository: peerRepository,
    );

    final coordinator = Coordinator._(
      localNode: localNode,
      peerRegistry: peerRegistry,
      channelService: channelService,
      peerService: peerService,
      channelRepository: channelRepository,
      entryRepository: entryRepository,
      gossipEngine: null, // Set below after coordinator is created
      failureDetector: null, // Set below after coordinator is created
      eventsController: eventsController,
    );

    // Create GossipEngine and FailureDetector if ports are provided, wiring error callbacks
    if (messagePort != null && timerPort != null) {
      // Create shared RTT tracker for adaptive timing (ADR-012)
      final rttTracker = RttTracker();

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
        random: random,
        rttTracker: rttTracker,
        // gossipInterval is now RTT-adaptive (see ADR-012)
      );

      coordinator._failureDetector = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timerPort,
        messagePort: messagePort,
        onError: coordinator._handleError,
        random: random,
        failureThreshold: cfg.suspicionThreshold,
        rttTracker: rttTracker,
        // Timeout parameters are now RTT-adaptive (see ADR-012)
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

  /// Handles errors from protocol services and emits them on the error stream.
  void _handleError(SyncError error) {
    if (!_errorsController.isClosed) {
      _errorsController.add(error);
    }
  }

  /// Handles entries merged from peers and emits EntriesMerged events.
  void _handleEntriesMerged(
    ChannelId channelId,
    StreamId streamId,
    List<LogEntry> entries,
  ) {
    if (_eventsController.isClosed || entries.isEmpty) return;

    // Compute the new version vector for the stream
    final newVersion = _entryRepository.getVersionVector(channelId, streamId);

    _eventsController.add(
      EntriesMerged(
        channelId,
        streamId,
        entries,
        newVersion,
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

    for (final channelId in _channelFacades.keys) {
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
  /// - SWIM failure detection probing
  ///
  /// If [displayName] is not provided, defaults to a truncated form of the
  /// node ID.
  ///
  /// Throws [Exception] if attempting to add the local node as a peer.
  Future<void> addPeer(NodeId id, {String? displayName}) async {
    await _peerService.addPeer(id, displayName: displayName);
  }

  /// Removes a peer from the system.
  ///
  /// The peer will no longer participate in gossip or failure detection.
  /// Any pending operations with this peer will be cancelled.
  Future<void> removePeer(NodeId id) async {
    await _peerService.removePeer(id);
  }

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

    // Iterate through all channels and streams to count entries and bytes
    for (final channelId in _channelFacades.keys) {
      final channel = await _channelRepository.findById(channelId);
      if (channel != null) {
        for (final streamId in channel.streamIds) {
          totalEntries += _entryRepository.entryCount(channelId, streamId);
          totalStorageBytes += _entryRepository.sizeBytes(channelId, streamId);
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

  /// Returns the current state of the coordinator.
  SyncState get state => _state;

  /// Returns true if the coordinator has been disposed.
  bool get isDisposed => _state == SyncState.disposed;

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
  /// Throws [StateError] if already running or disposed.
  Future<void> start() async {
    if (_state == SyncState.running) {
      throw StateError('Coordinator is already running');
    }
    if (_state == SyncState.disposed) {
      throw StateError('Cannot start a disposed coordinator');
    }

    _state = SyncState.running;

    // Start GossipEngine if available
    if (_gossipEngine != null) {
      final channels = await _loadChannels();
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
  /// Throws [StateError] if already stopped or disposed.
  Future<void> stop() async {
    if (_state == SyncState.stopped) {
      throw StateError('Coordinator is already stopped');
    }
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

    _state = SyncState.stopped;
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

    _state = SyncState.paused;
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

    _state = SyncState.running;

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

    _state = SyncState.disposed;

    // Close stream controllers
    await _eventsController.close();
    await _errorsController.close();
  }
}
