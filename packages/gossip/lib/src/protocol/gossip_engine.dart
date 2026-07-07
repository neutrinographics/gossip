import 'dart:async';
import 'dart:math';
import '../application/observability/log_level.dart';
import '../domain/errors/sync_error.dart';
import '../domain/interfaces/local_node_repository.dart';
import '../domain/services/hlc_clock.dart';
import '../domain/services/jitter.dart';
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
/// - **Convergence time**: O(log n) rounds. At n=2 with a fast interval this
///   can be sub-second; at larger n it is roughly log2(n) × the gossip
///   interval — a few seconds at the 1s default, longer on a slow BLE mesh
///   (fan-out is 1). Reactive push-on-write disseminates new *local* writes
///   faster than this periodic anti-entropy sweep.
/// - **Bidirectional sync**: Each round reciprocates (push-pull), so a single
///   exchange syncs in both directions.
/// - **Probabilistic, preconditioned guarantee**: peers converge *provided*
///   both created the same channel+stream locally (stream creation does not
///   propagate), each entry fits the delta budget, and digests fit the
///   transport limit. Given those, selection (least-recently-synced with a
///   random tiebreak) drives all pairs to eventual consistency.
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

  /// Repository for persisting local node state (HLC clock).
  final LocalNodeRepository _localNodeRepository;

  /// Optional callback for logging protocol messages.
  ///
  /// When provided, logs message types, sizes, and other protocol details.
  final LogCallback? onLog;

  /// Maximum encoded size (in bytes) of a single [DeltaResponse].
  ///
  /// [handleDeltaRequest] truncates the delta to a prefix that fits this
  /// budget; the remainder is delivered by subsequent anti-entropy rounds
  /// as the requester's version vector advances. Without a budget, a large
  /// backlog produces one giant message that the transport can never send,
  /// livelocking sync (the 32KB Android Nearby limit is the design target).
  ///
  /// Defaults to 30KB, leaving envelope headroom under the 32KB transport
  /// limit.
  final int maxDeltaResponseBytes;

  /// Codec for serializing/deserializing protocol messages.
  final ProtocolCodec _codec = ProtocolCodec();

  /// Random number generator for peer selection.
  /// Injectable for deterministic testing with seeded Random.
  final Random _random;

  /// Whether gossip rounds are currently running.
  bool _isRunning = false;

  /// Generation token for the gossip round loop.
  ///
  /// Incremented on every [start] and [stop] so that delay callbacks
  /// scheduled by a previous run become stale and cannot fork a second
  /// concurrent round loop when the engine is restarted within one
  /// interval (e.g. Coordinator pause()/resume()).
  int _generation = 0;

  /// Subscription to incoming messages (for cleanup on stop).
  StreamSubscription<IncomingMessage>? _messageSubscription;

  /// Channel map for generating digests and handling protocol messages.
  ///
  /// Updated via [setChannels] or [startListening]. Must contain all
  /// channels the local node is a member of.
  Map<ChannelId, ChannelAggregate> _channels = {};

  /// Whether adaptive timing is enabled.
  ///
  /// When true, gossip interval is computed from per-peer RTT data in
  /// [PeerRegistry]. When false, uses static gossip interval.
  final bool _adaptiveTimingEnabled;

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
  /// Keyed per-(peer, channel, stream): the timestamp (in ms) when the
  /// request was sent. When the corresponding DeltaResponse is received, the
  /// entry is removed. Entries older than [effectivePendingRequestTimeout]
  /// are considered expired and can be replaced with new requests.
  ///
  /// Keying by peer (not just stream) does two things: it keeps deduping
  /// duplicate DigestResponses from the *same* peer (the original sync-loop
  /// bug), while no longer letting a stalled *slow* peer block requesting
  /// the same stream from a *faster* peer — safe because duplicate/overlapping
  /// entries are filtered by the contiguity guard before merge.
  final Map<(NodeId, ChannelId, StreamId), int> _pendingDeltaRequests = {};

  /// EWMA of observed delta round-trip times (request sent → response
  /// received), used to derive [effectivePendingRequestTimeout]. This
  /// directly measures page-transmit time on the deployment's transport —
  /// a signal ping-based RTT can't provide (a 30KB page over BLE takes
  /// ~1-2 orders of magnitude longer than a 66-byte ping).
  final RttTracker _deltaRttTracker = RttTracker();

  /// Monotonic count of delta batches that merged at least one new entry.
  /// Exposed via [mergedBatchCount] as a coarse "recent sync activity"
  /// signal for applications (G5).
  int _mergedBatchCount = 0;

  /// Default pending-delta timeout used before any delta round-trip has been
  /// observed. Sized to comfortably exceed one ~30KB page over a slow BLE
  /// link (~7.5s at a few KB/s) so a request is never deemed stale
  /// mid-transmission on a cold start.
  static const Duration _defaultPendingTimeout = Duration(seconds: 8);
  static const Duration _minPendingTimeout = Duration(seconds: 2);
  static const Duration _maxPendingTimeout = Duration(seconds: 30);

  /// Window duration for metrics sliding window (10 seconds).
  ///
  /// Used to track message rates within a fixed time window for rate limiting.
  static const int _metricsWindowDurationMs = 10000;

  /// Debounce window for coalescing a burst of local writes into a single
  /// reactive push (rumor mongering — see [notifyLocalWrite]).
  static const Duration _pushDebounce = Duration(milliseconds: 150);

  /// Locally-written entries pending a reactive push, buffered per stream so
  /// a burst of writes within the debounce window coalesces into one push.
  final Map<(ChannelId, StreamId), List<LogEntry>> _pendingPush = {};

  /// True while a debounced push flush is scheduled (coalesces a burst into
  /// one flush).
  bool _pushFlushScheduled = false;

  /// Round-robin cursor over the flattened (channel, stream) digest list.
  /// Used only when a full digest exceeds the transport budget: each round
  /// advertises a byte-budgeted window, and the cursor advances so every
  /// stream is covered across successive rounds (otherwise the streams past
  /// the truncation point would never sync).
  int _digestRotation = 0;

  /// Per-peer congestion threshold for backpressure.
  ///
  /// Peers with more than this many pending messages are excluded from
  /// gossip peer selection. The round is only skipped entirely when ALL
  /// reachable peers exceed this threshold.
  static const int _perPeerCongestionThreshold = 3;

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
    required LocalNodeRepository localNodeRepository,
    Random? random,
    Duration? gossipInterval,
    bool adaptiveTimingEnabled = false,
    this.maxDeltaResponseBytes = 30 * 1024,
  }) : _hlcClock = hlcClock,
       _localNodeRepository = localNodeRepository,
       _random = random ?? Random(),
       _staticGossipInterval =
           gossipInterval ?? const Duration(milliseconds: 500),
       _adaptiveTimingEnabled = adaptiveTimingEnabled,
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

  /// Default conservative gossip interval when no per-peer RTT data exists.
  static const Duration _defaultConservativeInterval = Duration(
    milliseconds: 1000,
  );

  /// Returns the effective gossip interval based on per-peer RTT measurements.
  ///
  /// If a static [gossipInterval] was provided at construction, uses that value.
  /// Otherwise computes from the *median* per-peer smoothed RTT across all
  /// reachable peers, multiplied by [_gossipIntervalMultiplier] (2x).
  ///
  /// Median (not min) pacing keeps a single fast peer from pinning the loop
  /// to a fast cadence that over-drives slower links, while a single very
  /// slow peer can't stall the whole mesh either. Latency-sensitive delivery
  /// is handled by reactive push-on-write; this is the anti-entropy safety
  /// net, so a steadier median cadence is the right trade-off.
  ///
  /// Falls back to a conservative default (1000ms) when no peers have
  /// RTT estimates yet.
  Duration get effectiveGossipInterval {
    // Use static interval if explicitly provided (for backward compatibility)
    if (_staticIntervalProvided || !_adaptiveTimingEnabled) {
      return _staticGossipInterval;
    }

    // Pace off the MEDIAN per-peer SRTT across reachable peers, not the min.
    // The min let a single fast peer pin the whole loop to a fast cadence,
    // over-driving slower links — and each uniform-random round is ~(n-1)/n
    // likely to target a slower-than-fastest peer with a potentially large
    // payload. The median is robust to a single outlier at either end.
    final srtts = <Duration>[];
    for (final peer in peerRegistry.reachablePeers) {
      final rttEstimate = peer.metrics.rttEstimate;
      if (rttEstimate != null) srtts.add(rttEstimate.smoothedRtt);
    }

    // Fall back to conservative default when no peers have RTT estimates
    if (srtts.isEmpty) {
      return _defaultConservativeInterval;
    }

    srtts.sort();
    final medianSrtt = srtts[srtts.length ~/ 2];
    final computed = medianSrtt * _gossipIntervalMultiplier;
    if (computed < _minGossipInterval) return _minGossipInterval;
    if (computed > _maxGossipInterval) return _maxGossipInterval;
    return computed;
  }

  /// How long a pending delta request is honoured before it is considered
  /// stale and a replacement may be issued.
  ///
  /// Adaptive: derived (RFC-6298 style, SRTT + 4·RTTVAR) from observed delta
  /// round-trips so it always exceeds one page's transmit time on the actual
  /// transport, then clamped to [[_minPendingTimeout], [_maxPendingTimeout]].
  /// Before any round-trip is observed it is [_defaultPendingTimeout]. This
  /// stops a large page still in flight from being re-requested (duplicate
  /// requests are pure congestion amplification on a slow link).
  Duration get effectivePendingRequestTimeout {
    if (!_deltaRttTracker.hasReceivedSamples) return _defaultPendingTimeout;
    return _deltaRttTracker.suggestedTimeout(
      minTimeout: _minPendingTimeout,
      maxTimeout: _maxPendingTimeout,
    );
  }

  /// Number of delta requests currently in flight (pulls we are awaiting a
  /// response for). A coarse "am I mid-sync?" signal for applications (G5):
  /// non-zero means we are actively pulling data from a peer.
  int get outstandingPullCount => _pendingDeltaRequests.length;

  /// Monotonic count of delta batches that merged at least one new entry
  /// since construction. Poll it to detect recent sync activity: a value
  /// that stops advancing (together with [outstandingPullCount] == 0)
  /// indicates the node has gone quiescent / caught up (G5).
  int get mergedBatchCount => _mergedBatchCount;

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
    _generation++;
    _scheduleNextGossipRound(_generation);
  }

  /// Schedules the next gossip round using the current effective interval.
  ///
  /// Uses [delay] instead of periodic timer to allow the interval to adapt
  /// based on RTT measurements collected during operation.
  ///
  /// [generation] identifies the run that scheduled this callback; if it
  /// no longer matches [_generation] when the delay fires, the engine was
  /// stopped (and possibly restarted) in the meantime and this stale
  /// callback must not run a round or reschedule itself.
  void _scheduleNextGossipRound(int generation) {
    if (!_isRunning || generation != _generation) return;
    // ±20% jitter decorrelates gossip loops across nodes so they don't
    // phase-lock into correlated request/response bursts.
    timePort.delay(applyJitter(effectiveGossipInterval, _random)).then((_) {
      if (_isRunning && generation == _generation) {
        _gossipRound(generation);
      }
    }).catchError((Object error, StackTrace stackTrace) {
      // A broken timer must not kill the loop silently: surface the error
      // and stop so isRunning reflects reality.
      if (generation == _generation) {
        _isRunning = false;
        _generation++;
      }
      _emitError(
        PeerSyncError(
          localNode,
          SyncErrorType.protocolError,
          'Gossip round scheduling failed: $error',
          occurredAt: DateTime.now(),
          cause: error,
        ),
      );
    });
  }

  /// Stops periodic gossip rounds.
  ///
  /// Cancels the timer but does NOT stop message listening. Call
  /// [stopListening] separately if needed.
  void stop() {
    if (!_isRunning) return;
    _isRunning = false;
    _generation++;
    // Drop any buffered reactive push — the periodic anti-entropy loop is
    // also stopping, and a stale delay callback checks the generation.
    _pendingPush.clear();
    _pushFlushScheduled = false;
    // Drop outstanding delta-request flags: while stopped we don't ingest
    // responses, so a resumed engine should be free to re-request
    // immediately rather than waiting out the pending-request timeout.
    _pendingDeltaRequests.clear();
  }

  /// Reactive dissemination (rumor mongering): notify the engine of a local
  /// write so it pushes the new entry to reachable peers immediately —
  /// debounced to coalesce bursts — instead of waiting for the next periodic
  /// anti-entropy round. The periodic round remains the completeness safety
  /// net that catches anything a push missed.
  ///
  /// No-op when the engine is not running: a paused/listen-only engine
  /// disseminates nothing (consistent with push-pull reciprocation).
  ///
  /// Safe against out-of-order delivery: the push is applied by the receiver
  /// through the same per-author contiguity guard as any delta, so a peer
  /// that isn't caught up simply drops it and relies on anti-entropy.
  void notifyLocalWrite(
    ChannelId channelId,
    StreamId streamId,
    LogEntry entry,
  ) {
    if (!_isRunning) return;
    _pendingPush.putIfAbsent((channelId, streamId), () => []).add(entry);
    if (_pushFlushScheduled) return;
    _pushFlushScheduled = true;
    final generation = _generation;
    timePort
        .delay(_pushDebounce)
        .then((_) {
          if (generation != _generation) return; // stale run — do nothing
          _pushFlushScheduled = false;
          if (_isRunning) unawaited(_flushPendingPushes());
        })
        .catchError((Object error, StackTrace stackTrace) {
          if (generation != _generation) return;
          _pushFlushScheduled = false;
          _pendingPush.clear();
          _emitError(
            PeerSyncError(
              localNode,
              SyncErrorType.protocolError,
              'Reactive push scheduling failed: $error',
              occurredAt: DateTime.now(),
              cause: error,
            ),
          );
        });
  }

  /// Pushes buffered local writes to all reachable peers as unsolicited
  /// DeltaResponses. Oversized bursts (rare — the debounce window is short)
  /// fall back to paginated anti-entropy rather than a doomed oversized send.
  Future<void> _flushPendingPushes() async {
    if (_pendingPush.isEmpty) return;
    final batches = Map.of(_pendingPush);
    _pendingPush.clear();

    final peers = peerRegistry.reachablePeers;
    if (peers.isEmpty) return;

    for (final batch in batches.entries) {
      final (channelId, streamId) = batch.key;
      final push = DeltaResponse(
        sender: localNode,
        channelId: channelId,
        streamId: streamId,
        entries: batch.value,
      );
      if (_codec.encode(push).length > maxDeltaResponseBytes) continue;
      for (final peer in peers) {
        await _sendMessage(peer.id, push);
      }
    }
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
    _messageSubscription?.cancel();
    _messageSubscription = messagePort.incoming.listen(
      _handleIncomingMessage,
      // Without onError, one transport stream error becomes an uncaught
      // zone error and permanently cancels gossip message handling.
      onError: (Object error, StackTrace stackTrace) {
        _emitError(
          PeerSyncError(
            localNode,
            SyncErrorType.protocolError,
            'Transport stream error: $error',
            occurredAt: DateTime.now(),
            cause: error,
          ),
        );
      },
    );
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
  /// 1. Get reachable peers and filter out congested ones (per-peer backpressure)
  /// 2. Select the least-recently-gossiped uncongested candidate (bounded
  ///    coverage; random tiebreak) and mark it gossiped
  /// 3. Generate digests for all channels via [generateDigest]
  /// 4. Send [DigestRequest] to peer
  ///
  /// The peer will respond with their digests ([DigestResponse]), triggering
  /// Step 3 delta request generation.
  ///
  /// Returns immediately if all peers are congested or no reachable peers exist.
  Future<void> performGossipRound() async {
    final reachable = peerRegistry.reachablePeers;
    if (reachable.isEmpty) return;

    // Filter out congested peers (per-peer backpressure)
    final candidates = reachable
        .where(
          (p) =>
              messagePort.pendingSendCount(p.id) <= _perPeerCongestionThreshold,
        )
        .toList();

    if (candidates.isEmpty) {
      _log(
        LogLevel.debug,
        'Skipping gossip round: all ${reachable.length} peers congested '
        '(threshold: $_perPeerCongestionThreshold per peer)',
      );
      return;
    }

    final peer = _selectGossipPartner(candidates);
    // Record that we're gossiping with this peer now, so the next rounds
    // prefer peers we haven't synced with recently (bounded coverage).
    peerRegistry.updatePeerAntiEntropy(peer.id, timePort.nowMs);
    await _sendMessage(peer.id, await _buildDigestRequest());
  }

  /// Selects the gossip partner from [candidates], preferring the
  /// least-recently-gossiped peer (a peer we have never gossiped with —
  /// null timestamp — counts as the most stale), with a random tiebreak
  /// among equally-stale peers.
  ///
  /// This bounds gossip coverage to ~(n-1) rounds instead of pure-random
  /// selection's geometric distribution (the same win H3 gave SWIM probing),
  /// while the tiebreak keeps selection decorrelated across nodes — each node
  /// holds its own per-peer anti-entropy timestamps.
  Peer _selectGossipPartner(List<Peer> candidates) {
    // Never-gossiped (null) sorts before any real timestamp: -1 < 0 <= nowMs.
    int staleKey(Peer p) => p.lastAntiEntropyMs ?? -1;

    var minKey = staleKey(candidates.first);
    for (final p in candidates.skip(1)) {
      final k = staleKey(p);
      if (k < minKey) minKey = k;
    }
    final stalest = candidates.where((p) => staleKey(p) == minKey).toList();
    return stalest[_random.nextInt(stalest.length)];
  }

  /// Builds a [DigestRequest] carrying this node's version vectors.
  ///
  /// Sends the full digest when it fits the transport budget (the common
  /// case). When it doesn't, sends a byte-budgeted, round-robin-rotated
  /// subset of streams so no message is oversized and every stream is
  /// covered across rounds — instead of a giant message the transport can
  /// never carry (which would livelock sync entirely, H4).
  Future<DigestRequest> _buildDigestRequest() async {
    final all = <ChannelDigest>[];
    for (final channel in _channels.values) {
      all.add(await generateDigest(channel));
    }

    final full = DigestRequest(sender: localNode, digests: all);
    if (_codec.encode(full).length <= maxDeltaResponseBytes) {
      return full;
    }

    final flat = _flattenDigests(all);
    final (digests, consumed) = _fitDigests(flat, _digestRotation);
    if (flat.isNotEmpty) {
      _digestRotation = (_digestRotation + consumed) % flat.length;
    }
    return DigestRequest(sender: localNode, digests: digests);
  }

  /// Flattens grouped channel digests into a `(channel, stream digest)` list
  /// for byte-budgeted selection.
  List<({ChannelId channel, StreamDigest digest})> _flattenDigests(
    List<ChannelDigest> all,
  ) {
    final flat = <({ChannelId channel, StreamDigest digest})>[];
    for (final channelDigest in all) {
      for (final streamDigest in channelDigest.streams) {
        flat.add((channel: channelDigest.channelId, digest: streamDigest));
      }
    }
    return flat;
  }

  /// Selects the largest prefix of [flat] (starting at [startIndex], wrapping)
  /// whose encoded digest message fits [maxDeltaResponseBytes], regrouped by
  /// channel. Returns the selected digests and the number of items consumed
  /// (for advancing the rotation cursor).
  ///
  /// A single stream digest that alone exceeds the budget can never be sent;
  /// it is skipped with a distinct error rather than silently blocking the
  /// whole message every round.
  (List<ChannelDigest>, int) _fitDigests(
    List<({ChannelId channel, StreamDigest digest})> flat,
    int startIndex,
  ) {
    final n = flat.length;
    if (n == 0) return (const <ChannelDigest>[], 0);

    final base = _codec
        .encode(DigestRequest(sender: localNode, digests: const []))
        .length;

    final selected = <ChannelId, List<StreamDigest>>{};
    var size = base;
    var consumed = 0;

    for (var i = 0; i < n; i++) {
      final item = flat[(startIndex + i) % n];
      // Conservative cost: the stream digest plus a full channel envelope
      // (channelId + structural JSON), so we never exceed the budget even
      // when a stream is the first of its channel.
      final cost = _codec.encodedStreamDigestSize(item.digest) +
          item.channel.value.length +
          40;

      if (base + cost > maxDeltaResponseBytes) {
        _emitError(
          ChannelSyncError(
            item.channel,
            SyncErrorType.protocolError,
            'Digest for ${item.channel}/${item.digest.streamId} is ~$cost '
            'bytes and cannot fit maxDeltaResponseBytes=$maxDeltaResponseBytes; '
            'that stream has too many authors to sync (consider compaction '
            'or sharding the channel)',
            occurredAt: DateTime.now(),
          ),
        );
        consumed = i + 1;
        continue;
      }

      if (size + cost > maxDeltaResponseBytes) break; // window full

      size += cost;
      selected.putIfAbsent(item.channel, () => []).add(item.digest);
      consumed = i + 1;
    }

    final digests = selected.entries
        .map((e) => ChannelDigest(channelId: e.key, streams: e.value))
        .toList();
    return (digests, consumed);
  }

  /// Immediately starts anti-entropy with [peerId] by sending it a
  /// DigestRequest, rather than waiting for the random periodic round to
  /// select it. The gossip analogue of `FailureDetector.probeNewPeer`:
  /// called when a peer connects/reconnects so a fresh join or a healed
  /// partition reconciles right away. With push-pull reciprocation (M1) the
  /// single exchange syncs both directions. No-op when not running.
  Future<void> syncWithPeer(NodeId peerId) async {
    if (!_isRunning) return;
    try {
      await _sendMessage(peerId, await _buildDigestRequest());
    } catch (e) {
      _emitError(
        PeerSyncError(
          peerId,
          SyncErrorType.protocolError,
          'Initial sync with $peerId failed: $e',
          occurredAt: DateTime.now(),
          cause: e,
        ),
      );
    }
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

    // Receiving gossip from a peer is unambiguous proof of life. Feed it
    // into SWIM liveness so an actively-syncing peer is never suspected or
    // evicted from the gossip set just because its (lower-frequency) pings
    // were starved behind gossip traffic on a slow transport. No-op for
    // unknown/removed peers.
    peerRegistry.updatePeerContact(message.sender, nowMs);

    try {
      final protocolMessage = _codec.decode(message.bytes);

      if (protocolMessage is DigestRequest) {
        _log(
          LogLevel.trace,
          'RECV DigestRequest from ${_shortId(message.sender.value)}: '
          '${protocolMessage.digests.length} channels',
        );
        final response = await _handleDigestRequest(protocolMessage);
        await _sendMessage(message.sender, response);
        // Push-pull: the request already carries the initiator's version
        // vectors, so reciprocate by pulling anything they advertised that
        // we lack — making each exchange bidirectional instead of pulling
        // only toward the initiator. Reciprocation is *active* sync, so
        // gate it on running: a paused/listen-only engine still answers
        // digests (serves data) but must not initiate new pulls.
        if (_isRunning) {
          await _sendDeltaRequests(
            message.sender,
            await _computeDeltaRequests(
              message.sender,
              protocolMessage.digests,
            ),
          );
        }
      } else if (protocolMessage is DigestResponse) {
        _log(
          LogLevel.trace,
          'RECV DigestResponse from ${_shortId(message.sender.value)}: '
          '${protocolMessage.digests.length} channels',
        );
        // Pulling is active sync — a paused/listen-only engine serves but
        // does not pull. (A DigestResponse is only ever a reply to our own
        // request, which we make only while running.)
        if (_isRunning) {
          await _sendDeltaRequests(
            message.sender,
            await handleDigestResponse(protocolMessage),
          );
        }
      } else if (protocolMessage is DeltaRequest) {
        _log(
          LogLevel.debug,
          'RECV DeltaRequest from ${_shortId(message.sender.value)}: '
          'channel=${_shortId(protocolMessage.channelId.value)} '
          'stream=${protocolMessage.streamId.value}',
        );
        final response = await handleDeltaRequest(protocolMessage);
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
        // Ingesting new data is active sync — a paused/listen-only engine
        // drops incoming deltas (including unsolicited reactive pushes) and
        // relies on anti-entropy to re-fetch them after resume.
        if (_isRunning) {
          final continuation = await handleDeltaResponse(protocolMessage);
          if (continuation != null) {
            // Drain the rest of a truncated backlog immediately.
            await _sendDeltaRequests(message.sender, [continuation]);
          }
        }
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
  ///
  /// Returns true on success. Send failures are emitted via [ErrorCallback]
  /// and reported as false so callers can roll back optimistic state
  /// (e.g. the pending-delta-request flag).
  Future<bool> _sendMessage(NodeId recipient, ProtocolMessage message) async {
    final bytes = _codec.encode(message);
    _logOutgoingMessage(recipient, message, bytes.length);
    try {
      await messagePort.send(recipient, bytes);
      peerRegistry.recordMessageSent(recipient, bytes.length);
      return true;
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
      return false;
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

  /// Handle digest request using the current channel map.
  Future<DigestResponse> _handleDigestRequest(DigestRequest request) {
    final requestedChannels = request.digests
        .map((d) => d.channelId)
        .map((id) => _channels[id])
        .whereType<ChannelAggregate>()
        .toList();

    return handleDigestRequest(request, requestedChannels);
  }

  void _gossipRound(int generation) {
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
          _scheduleNextGossipRound(generation);
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
  Future<ChannelDigest> generateDigest(ChannelAggregate channel) async {
    final streamDigests = <StreamDigest>[];
    for (final streamId in channel.streamIds) {
      final version = await _computeVersionVector(channel.id, streamId);
      streamDigests.add(StreamDigest(streamId: streamId, version: version));
    }

    return ChannelDigest(channelId: channel.id, streams: streamDigests);
  }

  /// Gets version vector for a stream from the entry store.
  Future<VersionVector> _computeVersionVector(
    ChannelId channelId,
    StreamId streamId,
  ) {
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
  Future<List<LogEntry>> computeDelta(
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
  Future<DigestResponse> handleDigestRequest(
    DigestRequest request,
    List<ChannelAggregate> channels,
  ) async {
    // Respond only for the (channel, stream) pairs the initiator asked about
    // and that we also have, budgeted to the transport limit. Scoping the
    // response to the request keeps it bounded — the initiator already
    // budgeted/rotated the request, and our own version vectors may be
    // larger, so the response is fitted independently.
    final byId = {for (final channel in channels) channel.id: channel};

    final flat = <({ChannelId channel, StreamDigest digest})>[];
    for (final channelDigest in request.digests) {
      final channel = byId[channelDigest.channelId];
      if (channel == null) continue;
      for (final streamDigest in channelDigest.streams) {
        if (!channel.hasStream(streamDigest.streamId)) continue;
        final version = await _computeVersionVector(
          channelDigest.channelId,
          streamDigest.streamId,
        );
        flat.add((
          channel: channelDigest.channelId,
          digest: StreamDigest(
            streamId: streamDigest.streamId,
            version: version,
          ),
        ));
      }
    }

    final (digests, _) = _fitDigests(flat, 0);
    return DigestResponse(sender: localNode, digests: digests);
  }

  /// Handles digest response from a peer (Step 3).
  ///
  /// Compares peer's version vectors with ours to identify entries we're
  /// missing. Generates [DeltaRequest] only for streams where the peer has
  /// entries we don't have (i.e., where our version does not dominate theirs).
  ///
  /// Exposed as public for testing. Called by [_handleIncomingMessage].
  Future<List<DeltaRequest>> handleDigestResponse(
    DigestResponse response,
  ) {
    return _computeDeltaRequests(response.sender, response.digests);
  }

  /// Selects the entries that can be applied without leaving a per-author
  /// sequence gap: for each author, the contiguous run starting at
  /// `ourVersion[author] + 1`. Entries beyond a gap are dropped (anti-entropy
  /// backfills them contiguously later); entries at or below our version are
  /// skipped as already held. Preserves the original entry order.
  ///
  /// This upholds the version-vector high-water-mark invariant: applying a
  /// gapped entry would advance the vector past entries we don't actually
  /// hold, so no peer would ever return them again — a permanent silent gap.
  /// Matters most for unsolicited pushes (reactive dissemination), which can
  /// deliver an arbitrary suffix; the request/response path is already
  /// contiguous by construction, so this is also defense-in-depth there.
  List<LogEntry> _selectContiguousEntries(
    List<LogEntry> entries,
    VersionVector ourVersion,
  ) {
    final byAuthor = <NodeId, List<LogEntry>>{};
    for (final entry in entries) {
      byAuthor.putIfAbsent(entry.author, () => []).add(entry);
    }

    final acceptUpTo = <NodeId, int>{};
    for (final authorEntry in byAuthor.entries) {
      final author = authorEntry.key;
      final authorEntries = authorEntry.value
        ..sort((a, b) => a.sequence.compareTo(b.sequence));
      var next = ourVersion[author] + 1;
      for (final entry in authorEntries) {
        if (entry.sequence < next) continue; // already held
        if (entry.sequence != next) break; // gap — stop accepting this author
        next++;
      }
      acceptUpTo[author] = next - 1;
    }

    return entries
        .where(
          (e) =>
              e.sequence > ourVersion[e.author] &&
              e.sequence <= acceptUpTo[e.author]!,
        )
        .toList();
  }

  /// Sends the given [requests] to [recipient], releasing the pending flag
  /// for any that fail to transmit (the peer can never answer a request it
  /// didn't receive, so holding the flag would block re-requesting for the
  /// full timeout).
  Future<void> _sendDeltaRequests(
    NodeId recipient,
    List<DeltaRequest> requests,
  ) async {
    for (final request in requests) {
      final sent = await _sendMessage(recipient, request);
      if (!sent) {
        _pendingDeltaRequests.remove(
          (recipient, request.channelId, request.streamId),
        );
      }
    }
  }

  /// Compares a peer's advertised [peerDigests] against our own state and
  /// returns the [DeltaRequest]s needed to pull entries we are missing.
  ///
  /// Shared by both directions of anti-entropy: the DigestResponse path
  /// (we initiated; pull from the responder) and the DigestRequest path
  /// (they initiated; reciprocate using the digests they already sent us,
  /// i.e. push-pull). Streams with a non-expired pending request are
  /// skipped for dedup.
  Future<List<DeltaRequest>> _computeDeltaRequests(
    NodeId peer,
    List<ChannelDigest> peerDigests,
  ) async {
    final deltaRequests = <DeltaRequest>[];

    for (final channelDigest in peerDigests) {
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
        // Skip streams we don't have locally. Stream creation is a local
        // operation (by design — apps coordinate stream names), so a
        // peer's stream we never created is invisible here FOREVER; log
        // it so the situation is diagnosable in the field.
        if (!channel.hasStream(streamDigest.streamId)) {
          _log(
            LogLevel.trace,
            'ignoring digest for ${channelDigest.channelId}/'
            '${streamDigest.streamId}: stream not created locally',
          );
          continue;
        }

        final key = (peer, channelDigest.channelId, streamDigest.streamId);

        // Skip if we already have a non-expired pending request to THIS peer
        // for this stream.
        final pendingTimestamp = _pendingDeltaRequests[key];
        if (pendingTimestamp != null) {
          final elapsed = timePort.nowMs - pendingTimestamp;
          if (elapsed < effectivePendingRequestTimeout.inMilliseconds) {
            continue;
          }
          // Request has expired, remove it and allow a new one
          _pendingDeltaRequests.remove(key);
        }

        // Mark pending BEFORE the await below. The incoming-message
        // listener doesn't await handlers, so two queued DigestResponses
        // interleave here; setting the flag synchronously after the check
        // is what makes the dedup effective (otherwise both pass the
        // check above and emit duplicate DeltaRequests).
        _pendingDeltaRequests[key] = timePort.nowMs;

        final ourVersion = await _computeVersionVector(
          channelDigest.channelId,
          streamDigest.streamId,
        );

        // Only request delta if peer has entries we don't have
        if (!ourVersion.dominates(streamDigest.version)) {
          deltaRequests.add(
            DeltaRequest(
              sender: localNode,
              channelId: channelDigest.channelId,
              streamId: streamDigest.streamId,
              since: ourVersion,
            ),
          );
        } else {
          // Nothing to request after all — release the flag.
          _pendingDeltaRequests.remove(key);
        }
      }
    }

    return deltaRequests;
  }

  /// Handles delta request from a peer (Step 4).
  ///
  /// Computes the entries the peer is missing via [computeDelta] and
  /// returns them in a [DeltaResponse], truncated so the encoded message
  /// fits [maxDeltaResponseBytes]. Truncation keeps a prefix of the
  /// repository's timestamp order — per-author HLC monotonicity means a
  /// prefix is per-author sequence-contiguous, so the requester's version
  /// vector never develops holes. The requester obtains the remainder in
  /// subsequent anti-entropy rounds as its version vector advances.
  ///
  /// Exposed as public for testing. Called by [_handleIncomingMessage].
  Future<DeltaResponse> handleDeltaRequest(DeltaRequest request) async {
    final delta = await computeDelta(
      request.channelId,
      request.streamId,
      request.since,
    );

    final (fitted, hasMore) = _fitDeltaToBudget(request, delta);
    return DeltaResponse(
      sender: localNode,
      channelId: request.channelId,
      streamId: request.streamId,
      entries: fitted,
      hasMore: hasMore,
    );
  }

  /// Selects the prefix of [delta] whose encoded [DeltaResponse] fits
  /// [maxDeltaResponseBytes].
  ///
  /// An entry too large to ever fit (even alone in an empty message) can
  /// never be synced: it is reported via [ErrorCallback] and its author's
  /// remaining entries are excluded from this response to preserve
  /// per-author sequence contiguity — but other authors keep syncing.
  /// Returns the fitted prefix plus a `hasMore` flag: true when the page was
  /// cut short by the byte budget (deliverable entries remain for a future
  /// page). A truncation caused only by undeliverable "poison" entries does
  /// NOT set hasMore — continuing would make no progress and loop forever.
  (List<LogEntry>, bool) _fitDeltaToBudget(
    DeltaRequest request,
    List<LogEntry> delta,
  ) {
    if (delta.isEmpty) return (delta, false);

    final baseSize = _codec
        .encode(
          DeltaResponse(
            sender: localNode,
            channelId: request.channelId,
            streamId: request.streamId,
            entries: const [],
          ),
        )
        .length;

    final selected = <LogEntry>[];
    final blockedAuthors = <NodeId>{};
    var truncated = false;
    // +1 per entry for the JSON array separator.
    var size = baseSize;
    for (final entry in delta) {
      if (blockedAuthors.contains(entry.author)) continue;
      final cost = _codec.encodedEntrySize(entry) + 1;

      if (baseSize + cost > maxDeltaResponseBytes) {
        // Undeliverable: no message can ever carry this entry.
        _emitError(
          ChannelSyncError(
            request.channelId,
            SyncErrorType.protocolError,
            'Entry ${entry.author}#${entry.sequence} in '
            '${request.channelId}/${request.streamId} encodes to '
            '$cost bytes and can never fit '
            'maxDeltaResponseBytes=$maxDeltaResponseBytes; '
            'it cannot be synced to peers',
            occurredAt: DateTime.now(),
          ),
        );
        blockedAuthors.add(entry.author);
        continue;
      }

      if (size + cost > maxDeltaResponseBytes) {
        // Page full and this entry is deliverable in a future page — signal
        // the requester to continue immediately.
        truncated = true;
        break;
      }

      size += cost;
      selected.add(entry);
    }
    return (selected, truncated);
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
  /// Merges a [DeltaResponse] into the entry store.
  ///
  /// Returns a continuation [DeltaRequest] (for the dispatcher to send) when
  /// the sender truncated the response to the size budget ([hasMore]) AND we
  /// applied new entries — draining a backlog at link speed instead of one
  /// page per periodic round. Returns null otherwise (no more, or no
  /// progress — the latter guards against an infinite continuation loop).
  Future<DeltaRequest?> handleDeltaResponse(DeltaResponse response) async {
    final key = (response.sender, response.channelId, response.streamId);
    // If this response answers a request we were tracking, the elapsed time
    // is a sample of the real delta round-trip (dominated by page transmit
    // time) — feed it to the adaptive-timeout estimator before clearing.
    final pendingSince = _pendingDeltaRequests.remove(key);
    if (pendingSince != null) {
      final elapsedMs = timePort.nowMs - pendingSince;
      if (elapsedMs > 0) {
        var sample = Duration(milliseconds: elapsedMs);
        if (sample < _minPendingTimeout) sample = _minPendingTimeout;
        if (sample > _maxPendingTimeout) sample = _maxPendingTimeout;
        _deltaRttTracker.recordSample(sample);
      }
    }

    if (response.entries.isEmpty) return null;

    _updateHlcFromEntries(response.entries);

    // Keep only entries we don't already have, in per-author contiguous
    // order. Duplicate/stale DeltaResponses (a slow peer answering after the
    // pending timeout, overlap between two peers' responses) must not be
    // handed to the repository — whose contract rejects duplicates — nor
    // re-reported via onEntriesMerged as if they were new.
    final ourVersion = await _computeVersionVector(
      response.channelId,
      response.streamId,
    );
    final newEntries = _selectContiguousEntries(response.entries, ourVersion);
    if (newEntries.isEmpty) return null;

    // Snapshot the current tail HLC before appending to detect out-of-order
    final previousTailHlc = await entryRepository.getTailTimestamp(
      response.channelId,
      response.streamId,
    );

    await entryRepository.appendAll(
      response.channelId,
      response.streamId,
      newEntries,
    );

    // Out-of-order: any merged entry sorts before the previous tail
    final containsOutOfOrderEntries =
        previousTailHlc != null &&
        newEntries.any((e) => e.timestamp < previousTailHlc);

    _mergedBatchCount++;

    await onEntriesMerged?.call(
      response.channelId,
      response.streamId,
      newEntries,
      containsOutOfOrderEntries,
    );

    if (response.hasMore) {
      // Continue draining from the same peer at our advanced version.
      final advanced = await _computeVersionVector(
        response.channelId,
        response.streamId,
      );
      _pendingDeltaRequests[key] = timePort.nowMs;
      return DeltaRequest(
        sender: localNode,
        channelId: response.channelId,
        streamId: response.streamId,
        since: advanced,
      );
    }
    return null;
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

    // Persist clock state for restart recovery. Fire-and-forget for
    // latency, but never silent: a persistent store failing (disk full)
    // must surface via ErrorCallback instead of becoming an unhandled
    // zone error.
    unawaited(
      _localNodeRepository.saveClockState(_hlcClock.current).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        _emitError(
          StorageSyncError(
            SyncErrorType.storageFailure,
            'Failed to persist HLC clock state: $error',
            occurredAt: DateTime.now(),
            cause: error,
          ),
        );
      }),
    );
  }
}
