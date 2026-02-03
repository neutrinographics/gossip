import 'dart:async';
import 'dart:math';
import '../application/observability/log_level.dart';
import '../domain/errors/sync_error.dart';
import '../domain/services/hlc_clock.dart';
import '../domain/services/rtt_tracker.dart';
import '../domain/value_objects/node_id.dart';
import '../domain/value_objects/channel_id.dart';
import '../domain/value_objects/stream_id.dart';
import '../domain/value_objects/version_vector.dart';
import '../domain/value_objects/log_entry.dart';
import '../domain/aggregates/peer_registry.dart';
import '../domain/aggregates/channel_aggregate.dart';
import '../domain/entities/peer.dart';
import '../domain/interfaces/entry_repository.dart';
import '../infrastructure/ports/time_port.dart';
import '../infrastructure/ports/message_port.dart';
import 'protocol_codec.dart';
import 'messages/protocol_message.dart';
import 'values/channel_digest.dart';
import 'values/stream_digest.dart';
import 'messages/digest_request.dart';
import 'messages/digest_response.dart';
import 'messages/delta_request.dart';
import 'messages/delta_response.dart';

/// Protocol service implementing gossip-based anti-entropy synchronization.
///
/// [GossipEngine] synchronizes log entries across peers through periodic
/// digest exchange. It implements a 4-step anti-entropy protocol:
///
/// ## Anti-Entropy Protocol (4 Steps)
///
/// **Step 1: Digest Request (every 200ms)**
/// - Select random reachable peer
/// - Generate digests (version vectors) for all local channels/streams
/// - Send [DigestRequest] containing our sync state
///
/// **Step 2: Digest Response**
/// - Peer receives request, generates their own digests
/// - Sends [DigestResponse] with their version vectors
///
/// **Step 3: Delta Request**
/// - Compare peer's version vectors with ours
/// - Identify entries we're missing (peer has higher sequence numbers)
/// - Send [DeltaRequest] specifying what we need (since our version)
///
/// **Step 4: Delta Response**
/// - Peer computes missing entries based on our version vector
/// - Sends [DeltaResponse] with actual log entries
/// - We merge entries into our [EntryRepository]
///
/// ## Convergence Characteristics
///
/// - **Sub-second convergence**: Typically 150ms for small networks (< 8 peers)
/// - **Bidirectional sync**: Each round can sync in both directions
/// - **Probabilistic guarantee**: Random peer selection ensures eventual
///   consistency across all peers
///
/// ## Channel Management
///
/// The engine requires a channel map to generate digests. This map is
/// injected via [startListening] and updated via [setChannels]. The map
/// should contain all channels the local node is a member of.
///
/// ## Lifecycle
///
/// Must call [start] to begin gossip rounds and [startListening] to handle
/// incoming messages. Both are independent; typically both are started together.
///
/// Used by: Application facades (Coordinator) to manage data synchronization.
class GossipEngine {
  /// Local node identifier for this instance.
  final NodeId localNode;

  /// Peer registry for selecting random peers to gossip with.
  final PeerRegistry peerRegistry;

  /// Entry store for reading/writing log entries during sync.
  final EntryRepository entryRepository;

  /// Timer abstraction for scheduling periodic gossip rounds.
  final TimePort timePort;

  /// Message transport for sending/receiving protocol messages.
  final MessagePort messagePort;

  /// Optional callback for reporting synchronization errors.
  ///
  /// When provided, errors that would otherwise be silent are reported
  /// through this callback for observability.
  final ErrorCallback? onError;

  /// Optional callback for when entries are merged from a peer.
  ///
  /// Called after entries are successfully stored in the [EntryRepository].
  /// Used by Coordinator to emit [EntriesMerged] events for UI updates.
  final EntriesMergedCallback? onEntriesMerged;

  /// Hybrid logical clock for updating local time on receive.
  ///
  /// When entries are received from peers, the HLC is updated to ensure
  /// subsequent local writes have causally consistent timestamps.
  /// When null, HLC updates are skipped (not recommended for production).
  final HlcClock? _hlcClock;

  /// Optional callback for logging protocol messages.
  ///
  /// When provided, logs message types, sizes, and other protocol details.
  final LogCallback? onLog;

  /// Codec for serializing/deserializing protocol messages.
  final ProtocolCodec _codec = ProtocolCodec();

  /// Random number generator for peer selection.
  /// Injectable for deterministic testing with seeded Random.
  final Random _random;

  /// Whether gossip rounds are currently running.
  bool _isRunning = false;

  /// Handle for cancelling the periodic timer.
  TimerHandle? _timerHandle;

  /// Subscription to incoming messages (for cleanup on stop).
  StreamSubscription<IncomingMessage>? _messageSubscription;

  /// Channel map for generating digests and handling protocol messages.
  ///
  /// Updated via [setChannels] or [startListening]. Must contain all
  /// channels the local node is a member of.
  Map<ChannelId, ChannelAggregate> _channels = {};

  /// RTT tracker for adaptive gossip interval calculation.
  ///
  /// Shared with FailureDetector to use RTT measurements from SWIM pings.
  /// When null, uses static gossip interval for backward compatibility.
  final RttTracker? _rttTracker;

  /// Static gossip interval (used when RTT tracker not provided).
  final Duration _staticGossipInterval;

  /// Whether a static gossip interval was explicitly provided.
  final bool _staticIntervalProvided;

  /// Minimum gossip interval (prevent CPU spin).
  static const Duration _minGossipInterval = Duration(milliseconds: 100);

  /// Maximum gossip interval (ensure progress).
  static const Duration _maxGossipInterval = Duration(seconds: 5);

  /// Multiplier for gossip interval relative to RTT.
  /// Gossip interval = 2x RTT (time for request + response round trip).
  static const int _gossipIntervalMultiplier = 2;

  /// Tracks pending DeltaRequests to prevent duplicate requests.
  ///
  /// Maps (channel, stream) pairs to the timestamp (in ms) when the request
  /// was sent. When the corresponding DeltaResponse is received, the entry
  /// is removed. Entries older than [_pendingRequestTimeout] are considered
  /// expired and can be replaced with new requests.
  ///
  /// This prevents the sync loop bug where multiple DigestResponses arriving
  /// in quick succession would each trigger duplicate DeltaRequests for the
  /// same stream before entries are merged and version vectors updated.
  final Map<(ChannelId, StreamId), int> _pendingDeltaRequests = {};

  /// Timeout for pending delta requests (5 seconds).
  ///
  /// If a DeltaResponse doesn't arrive within this time, the pending request
  /// is considered stale and a new request can be sent. This handles cases
  /// where the response was lost or the peer disconnected.
  static const Duration _pendingRequestTimeout = Duration(seconds: 5);

  /// Window duration for metrics sliding window (10 seconds).
  ///
  /// Used to track message rates within a fixed time window for rate limiting.
  static const int _metricsWindowDurationMs = 10000;

  /// Congestion threshold for backpressure.
  ///
  /// When the transport has more than this many pending messages, gossip
  /// rounds are skipped to prevent unbounded queue growth. This allows the
  /// transport to drain before generating more messages.
  static const int _congestionThreshold = 10;

  GossipEngine({
    required this.localNode,
    required this.peerRegistry,
    required this.entryRepository,
    required this.timePort,
    required this.messagePort,
    this.onError,
    this.onEntriesMerged,
    this.onLog,
    HlcClock? hlcClock,
    Random? random,
    Duration? gossipInterval,
    RttTracker? rttTracker,
  }) : _hlcClock = hlcClock,
       _random = random ?? Random(),
       _staticGossipInterval =
           gossipInterval ?? const Duration(milliseconds: 500),
       _rttTracker = rttTracker,
       _staticIntervalProvided = gossipInterval != null;

  /// Emits an error through the callback if one is registered.
  void _emitError(SyncError error) {
    onError?.call(error);
  }

  /// Logs a message if logging is enabled.
  void _log(
    LogLevel level,
    String message, [
    Object? error,
    StackTrace? stack,
  ]) {
    onLog?.call(level, message, error, stack);
  }

  /// Whether gossip rounds are currently active.
  bool get isRunning => _isRunning;

  /// Returns the effective gossip interval based on RTT measurements.
  ///
  /// If a static [gossipInterval] was provided at construction, uses that value.
  /// Otherwise uses the RTT tracker's smoothed RTT * 2 (time for request + response),
  /// clamped to [_minGossipInterval, _maxGossipInterval].
  ///
  /// Before any RTT samples are collected, uses the initial conservative
  /// estimate (1 second RTT * 2 = 2 seconds).
  Duration get effectiveGossipInterval {
    // Use static interval if explicitly provided (for backward compatibility)
    if (_staticIntervalProvided || _rttTracker == null) {
      return _staticGossipInterval;
    }
    final rtt = _rttTracker.estimate.smoothedRtt;
    final computed = rtt * _gossipIntervalMultiplier;
    if (computed < _minGossipInterval) return _minGossipInterval;
    if (computed > _maxGossipInterval) return _maxGossipInterval;
    return computed;
  }

  /// Starts periodic gossip rounds.
  ///
  /// Schedules [performGossipRound] to run at adaptive intervals based on
  /// measured RTT. The interval adjusts as RTT samples are collected.
  /// Safe to call multiple times (subsequent calls are no-ops).
  ///
  /// Note: This does NOT start message listening. Call [startListening]
  /// separately to handle incoming gossip messages.
  void start() {
    if (_isRunning) return;
    _isRunning = true;
    _scheduleNextGossipRound();
  }

  /// Schedules the next gossip round using the current effective interval.
  ///
  /// Uses [delay] instead of periodic timer to allow the interval to adapt
  /// based on RTT measurements collected during operation.
  void _scheduleNextGossipRound() {
    if (!_isRunning) return;
    timePort.delay(effectiveGossipInterval).then((_) {
      if (_isRunning) {
        _gossipRound();
      }
    });
  }

  /// Stops periodic gossip rounds.
  ///
  /// Cancels the timer but does NOT stop message listening. Call
  /// [stopListening] separately if needed.
  void stop() {
    if (!_isRunning) return;
    _isRunning = false;
    _timerHandle?.cancel();
    _timerHandle = null;
  }

  /// Starts listening to incoming gossip protocol messages.
  ///
  /// Subscribes to [messagePort.incoming] and processes all anti-entropy
  /// messages (DigestRequest/Response, DeltaRequest/Response).
  ///
  /// The [channels] map is stored and used for digest generation and
  /// message handling. Update this map via [setChannels] when channel
  /// membership changes.
  ///
  /// Note: This does NOT start gossip rounds. Call [start] separately to
  /// begin periodic digest exchange.
  void startListening(Map<ChannelId, ChannelAggregate> channels) {
    _channels = channels;
    _messageSubscription = messagePort.incoming.listen(_handleIncomingMessage);
  }

  /// Stops listening to incoming messages.
  ///
  /// Cancels the message subscription. Does not affect channel map.
  void stopListening() {
    _messageSubscription?.cancel();
    _messageSubscription = null;
  }

  /// Updates the channel map used for digest generation.
  ///
  /// Call this when channel membership changes (new channels created,
  /// streams added, etc.) to ensure digests reflect current state.
  ///
  /// The channel map should contain all channels the local node is a
  /// member of.
  void setChannels(Map<ChannelId, ChannelAggregate> channels) {
    _channels = channels;
  }

  /// Performs a single gossip round (called every 200ms).
  ///
  /// Implements Step 1 of the anti-entropy protocol:
  /// 1. Check for transport congestion (skip if congested)
  /// 2. Select random reachable peer via [selectRandomPeer]
  /// 3. Generate digests for all channels via [generateDigest]
  /// 4. Send [DigestRequest] to peer
  ///
  /// The peer will respond with their digests ([DigestResponse]), triggering
  /// Step 3 delta request generation.
  ///
  /// Returns immediately if transport is congested or no reachable peers exist.
  Future<void> performGossipRound() async {
    // Skip round if transport is congested (backpressure)
    if (messagePort.totalPendingSendCount > _congestionThreshold) {
      _log(
        LogLevel.debug,
        'Skipping gossip round: transport congested '
        '(${messagePort.totalPendingSendCount} pending > $_congestionThreshold threshold)',
      );
      return;
    }

    final peer = selectRandomPeer();
    if (peer == null) return;

    final digests = _channels.values.map((channel) {
      return generateDigest(channel);
    }).toList();

    final request = DigestRequest(sender: localNode, digests: digests);
    await _sendMessage(peer.id, request);
  }

  /// Handles incoming gossip protocol messages.
  ///
  /// Decodes message and dispatches to appropriate handler:
  /// - [DigestRequest] → Generate our digests, send [DigestResponse] (Step 2)
  /// - [DigestResponse] → Compare digests, send [DeltaRequest] for missing entries (Step 3)
  /// - [DeltaRequest] → Compute delta, send [DeltaResponse] with entries (Step 4)
  /// - [DeltaResponse] → Merge received entries into [EntryRepository]
  ///
  /// Malformed messages are silently ignored to prevent denial-of-service
  /// via protocol violations.
  Future<void> _handleIncomingMessage(IncomingMessage message) async {
    // Record metrics before processing (even if decode fails)
    final nowMs = timePort.nowMs;
    peerRegistry.recordMessageReceived(
      message.sender,
      message.bytes.length,
      nowMs,
      _metricsWindowDurationMs,
    );

    try {
      final protocolMessage = _codec.decode(message.bytes);

      if (protocolMessage is DigestRequest) {
        _log(
          LogLevel.trace,
          'RECV DigestRequest from ${_shortId(message.sender.value)}: '
          '${protocolMessage.digests.length} channels',
        );
        final response = _handleDigestRequest(protocolMessage);
        await _sendMessage(message.sender, response);
      } else if (protocolMessage is DigestResponse) {
        _log(
          LogLevel.trace,
          'RECV DigestResponse from ${_shortId(message.sender.value)}: '
          '${protocolMessage.digests.length} channels',
        );
        final deltaRequests = handleDigestResponse(protocolMessage);
        await _sendMessages(message.sender, deltaRequests);
      } else if (protocolMessage is DeltaRequest) {
        _log(
          LogLevel.debug,
          'RECV DeltaRequest from ${_shortId(message.sender.value)}: '
          'channel=${_shortId(protocolMessage.channelId.value)} '
          'stream=${protocolMessage.streamId.value}',
        );
        final response = handleDeltaRequest(protocolMessage);
        await _sendMessage(message.sender, response);
      } else if (protocolMessage is DeltaResponse) {
        final level = protocolMessage.entries.isEmpty
            ? LogLevel.trace
            : LogLevel.debug;
        _log(
          level,
          'RECV DeltaResponse from ${_shortId(message.sender.value)}: '
          'channel=${_shortId(protocolMessage.channelId.value)} '
          'stream=${protocolMessage.streamId.value} '
          'entries=${protocolMessage.entries.length}',
        );
        handleDeltaResponse(protocolMessage);
      }
    } catch (e) {
      // Emit error for observability (intentionally non-fatal for DoS prevention)
      _emitError(
        PeerSyncError(
          message.sender,
          SyncErrorType.messageCorrupted,
          'Malformed gossip message from ${message.sender}: $e',
          occurredAt: DateTime.now(),
          cause: e,
        ),
      );
    }
  }

  /// Encodes and sends a single protocol message to a peer.
  Future<void> _sendMessage(NodeId recipient, ProtocolMessage message) async {
    final bytes = _codec.encode(message);
    _logOutgoingMessage(recipient, message, bytes.length);
    try {
      await messagePort.send(recipient, bytes);
      peerRegistry.recordMessageSent(recipient, bytes.length);
    } catch (e) {
      _emitError(
        PeerSyncError(
          recipient,
          SyncErrorType.peerUnreachable,
          'Failed to send ${message.runtimeType} to $recipient: $e',
          occurredAt: DateTime.now(),
          cause: e,
        ),
      );
    }
  }

  /// Logs details about an outgoing protocol message.
  void _logOutgoingMessage(
    NodeId recipient,
    ProtocolMessage message,
    int size,
  ) {
    final recipientShort = _shortId(recipient.value);
    switch (message) {
      case DigestRequest(:final digests):
        _log(
          LogLevel.trace,
          'SEND DigestRequest to $recipientShort: ${digests.length} channels ($size bytes)',
        );
      case DigestResponse(:final digests):
        _log(
          LogLevel.trace,
          'SEND DigestResponse to $recipientShort: ${digests.length} channels ($size bytes)',
        );
      case DeltaRequest(:final channelId, :final streamId):
        _log(
          LogLevel.debug,
          'SEND DeltaRequest to $recipientShort: '
          'channel=${_shortId(channelId.value)} stream=${streamId.value} ($size bytes)',
        );
      case DeltaResponse(:final channelId, :final streamId, :final entries):
        final level = entries.isEmpty ? LogLevel.trace : LogLevel.debug;
        _log(
          level,
          'SEND DeltaResponse to $recipientShort: '
          'channel=${_shortId(channelId.value)} stream=${streamId.value} '
          'entries=${entries.length} ($size bytes)',
        );
      default:
        _log(
          LogLevel.trace,
          'SEND ${message.runtimeType} to $recipientShort ($size bytes)',
        );
    }
  }

  /// Shortens an ID for logging (first 8 chars).
  String _shortId(String id) {
    return id.length > 8 ? id.substring(0, 8) : id;
  }

  /// Encodes and sends multiple protocol messages to a peer.
  Future<void> _sendMessages(
    NodeId recipient,
    List<ProtocolMessage> messages,
  ) async {
    for (final message in messages) {
      await _sendMessage(recipient, message);
    }
  }

  /// Handle digest request using the current channel map.
  DigestResponse _handleDigestRequest(DigestRequest request) {
    final requestedChannels = request.digests
        .map((d) => d.channelId)
        .map((id) => _channels[id])
        .whereType<ChannelAggregate>()
        .toList();

    return handleDigestRequest(request, requestedChannels);
  }

  void _gossipRound() {
    performGossipRound()
        .catchError((error, stackTrace) {
          _emitError(
            PeerSyncError(
              localNode,
              SyncErrorType.protocolError,
              'Gossip round failed: $error',
              occurredAt: DateTime.now(),
              cause: error,
            ),
          );
        })
        .whenComplete(() {
          // Schedule next gossip round with adaptive interval
          // (interval may have changed based on new RTT samples)
          _scheduleNextGossipRound();
        });
  }

  /// Selects a random reachable peer for gossip.
  ///
  /// Delegates to [PeerRegistry.selectRandomReachablePeer].
  ///
  /// Returns null if no reachable peers exist.
  Peer? selectRandomPeer() {
    return peerRegistry.selectRandomReachablePeer(_random);
  }

  /// Generates a digest (version vector summary) for a channel.
  ///
  /// Creates a compact representation of sync state by computing version
  /// vectors for each stream. The digest typically occupies 10-100 bytes
  /// compared to megabytes for full entry sets, enabling efficient anti-entropy.
  ///
  /// Used in: [performGossipRound] (Step 1) and [handleDigestRequest] (Step 2).
  ///
  /// Exposed as public for testing.
  ChannelDigest generateDigest(ChannelAggregate channel) {
    final streamDigests = channel.streamIds.map((streamId) {
      final version = _computeVersionVector(channel.id, streamId);
      return StreamDigest(streamId: streamId, version: version);
    }).toList();

    return ChannelDigest(channelId: channel.id, streams: streamDigests);
  }

  /// Gets version vector for a stream from the entry store.
  VersionVector _computeVersionVector(ChannelId channelId, StreamId streamId) {
    return entryRepository.getVersionVector(channelId, streamId);
  }

  /// Computes delta (missing entries) that peer needs based on their version.
  ///
  /// Queries [EntryRepository] for entries where:
  /// - entry.author not in peerVersion, OR
  /// - entry.sequence > peerVersion[entry.author]
  ///
  /// This identifies entries the peer is missing relative to our state.
  ///
  /// Used in: [handleDeltaRequest] (Step 4).
  ///
  /// Exposed as public for testing.
  List<LogEntry> computeDelta(
    ChannelId channelId,
    StreamId streamId,
    VersionVector peerVersion,
  ) {
    return entryRepository.entriesSince(channelId, streamId, peerVersion);
  }

  /// Handles digest request from a peer (Step 2).
  ///
  /// Generates our own digests for the requested channels and returns them.
  /// The peer initiated anti-entropy; we're responding with our sync state.
  ///
  /// Only generates digests for channels we're members of (present in
  /// the [channels] parameter).
  ///
  /// Exposed as public for testing. Called by [_handleIncomingMessage].
  DigestResponse handleDigestRequest(
    DigestRequest request,
    List<ChannelAggregate> channels,
  ) {
    final responseDigests = channels.map((channel) {
      return generateDigest(channel);
    }).toList();

    return DigestResponse(sender: localNode, digests: responseDigests);
  }

  /// Handles digest response from a peer (Step 3).
  ///
  /// Compares peer's version vectors with ours to identify entries we're
  /// missing. Generates [DeltaRequest] only for streams where the peer has
  /// entries we don't have (i.e., where our version does not dominate theirs).
  ///
  /// Exposed as public for testing. Called by [_handleIncomingMessage].
  List<DeltaRequest> handleDigestResponse(DigestResponse response) {
    final deltaRequests = <DeltaRequest>[];

    for (final channelDigest in response.digests) {
      final channel = _channels[channelDigest.channelId];
      if (channel == null) {
        _emitError(
          ChannelSyncError(
            channelDigest.channelId,
            SyncErrorType.protocolError,
            'Received digest for unknown channel ${channelDigest.channelId}',
            occurredAt: DateTime.now(),
          ),
        );
        continue;
      }

      for (final streamDigest in channelDigest.streams) {
        final key = (channelDigest.channelId, streamDigest.streamId);

        // Skip if we already have a non-expired pending request for this stream
        final pendingTimestamp = _pendingDeltaRequests[key];
        if (pendingTimestamp != null) {
          final elapsed = timePort.nowMs - pendingTimestamp;
          if (elapsed < _pendingRequestTimeout.inMilliseconds) {
            continue;
          }
          // Request has expired, remove it and allow a new one
          _pendingDeltaRequests.remove(key);
        }

        final ourVersion = _computeVersionVector(
          channelDigest.channelId,
          streamDigest.streamId,
        );

        // Only request delta if peer has entries we don't have
        if (!ourVersion.dominates(streamDigest.version)) {
          _pendingDeltaRequests[key] = timePort.nowMs;
          deltaRequests.add(
            DeltaRequest(
              sender: localNode,
              channelId: channelDigest.channelId,
              streamId: streamDigest.streamId,
              since: ourVersion,
            ),
          );
        }
      }
    }

    return deltaRequests;
  }

  /// Handles delta request from a peer (Step 4).
  ///
  /// Computes the entries the peer is missing via [computeDelta] and
  /// returns them in a [DeltaResponse]. The peer will merge these entries
  /// into their [EntryRepository].
  ///
  /// Exposed as public for testing. Called by [_handleIncomingMessage].
  DeltaResponse handleDeltaRequest(DeltaRequest request) {
    final delta = computeDelta(
      request.channelId,
      request.streamId,
      request.since,
    );

    return DeltaResponse(
      sender: localNode,
      channelId: request.channelId,
      streamId: request.streamId,
      entries: delta,
    );
  }

  /// Handles delta response from a peer (final step).
  ///
  /// Merges received entries into our [EntryRepository]. This completes the
  /// anti-entropy protocol. The entries are now synchronized.
  ///
  /// Also updates the local HLC clock to ensure subsequent local writes
  /// have timestamps that are causally after the received entries.
  ///
  /// Clears the pending request flag to allow future delta requests for
  /// this stream.
  ///
  /// Exposed as public for testing. Called by [_handleIncomingMessage].
  void handleDeltaResponse(DeltaResponse response) {
    // Clear pending flag to allow future requests for this stream
    _pendingDeltaRequests.remove((response.channelId, response.streamId));

    if (response.entries.isEmpty) return;

    _updateHlcFromEntries(response.entries);

    entryRepository.appendAll(
      response.channelId,
      response.streamId,
      response.entries,
    );

    onEntriesMerged?.call(
      response.channelId,
      response.streamId,
      response.entries,
    );
  }

  /// Clears all pending delta requests.
  ///
  /// Call this when a peer disconnects to allow immediate re-sync when
  /// the peer reconnects. Without clearing, pending requests would block
  /// new delta requests until they expire.
  void clearPendingRequests() {
    _pendingDeltaRequests.clear();
  }

  /// Updates the local HLC clock from received entries.
  ///
  /// Finds the maximum HLC timestamp among the entries and calls
  /// [HlcClock.receive] to ensure causal consistency for subsequent writes.
  void _updateHlcFromEntries(List<LogEntry> entries) {
    if (_hlcClock == null || entries.isEmpty) return;

    final maxHlc = entries
        .map((e) => e.timestamp)
        .reduce((a, b) => a.compareTo(b) > 0 ? a : b);

    _hlcClock.receive(maxHlc);
  }
}
