import 'dart:async';
import 'dart:math';
import 'package:gossip/src/shared/domain/value_objects/log_level.dart';
import 'package:gossip/src/shared/domain/errors/sync_error.dart';
import 'package:gossip/src/shared/domain/interfaces/local_node_repository.dart';
import 'package:gossip/src/sync/domain/services/hlc_clock.dart';
import 'package:gossip/src/sync/domain/services/gossip_timing_policy.dart';
import 'package:gossip/src/shared/domain/services/generation_scheduler.dart';
import 'package:gossip/src/shared/domain/services/jitter.dart';
import 'package:gossip/src/shared/domain/services/keyed_task_chain.dart';
import 'package:gossip/src/sync/domain/services/pending_pull_tracker.dart';

import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/sync/domain/aggregates/channel_aggregate.dart';
import 'package:gossip/src/sync/domain/interfaces/entry_repository.dart';
import 'package:gossip/src/shared/domain/interfaces/time_port.dart';
import 'package:gossip/src/shared/domain/interfaces/message_port.dart';
import 'package:gossip/src/shared/domain/interfaces/message_codec.dart';
import 'package:gossip/src/sync/domain/interfaces/peer_directory.dart';
import 'package:gossip/src/sync/domain/value_objects/sync_partner.dart';
import 'package:gossip/src/sync/infrastructure/sync_message_codec.dart';
import 'package:gossip/src/shared/domain/interfaces/protocol_message.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';
import 'package:gossip/src/sync/domain/value_objects/stream_digest.dart';
import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:gossip/src/sync/domain/messages/digest_response.dart';
import 'package:gossip/src/sync/domain/messages/delta_request.dart';
import 'package:gossip/src/sync/domain/messages/delta_response.dart';
import 'package:gossip/src/sync/domain/events/sync_events.dart';
import 'package:gossip/src/sync/application/digest_budgeter.dart';

/// Protocol service implementing gossip-based anti-entropy synchronization.
///
/// [GossipEngine] synchronizes log entries across peers through periodic
/// digest exchange. It implements a 4-step anti-entropy protocol:
///
/// ## Anti-Entropy Protocol (4 Steps)
///
/// **Step 1: Digest Request** (see [effectiveGossipInterval] for the interval policy)
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
///
/// Comment keys like COR3-n / WIRE4-n / H-n refer to findings in
/// `docs/audits/`.
class GossipEngine {
  /// Local node identifier for this instance.
  final NodeId localNode;

  /// Sync's port onto peer state (membership context), for selecting
  /// partners to gossip with and recording contact/anti-entropy telemetry.
  /// Implemented by `MembershipPeerDirectory`, an ACL over `PeerRegistry` —
  /// see `sync/domain/interfaces/peer_directory.dart`.
  final PeerDirectory peerDirectory;

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
  /// Used by `Coordinator` to emit [EntriesMerged] events for UI updates.
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

  /// The byte budget for every sync protocol message — digests, delta
  /// pages, and pushes — sized to the 32 KB transport limit.
  ///
  /// [handleDeltaRequest] truncates the delta to a prefix that fits this
  /// budget; the remainder is delivered by subsequent anti-entropy rounds
  /// as the requester's version vector advances. Without a budget, a large
  /// backlog produces one giant message that the transport can never send,
  /// livelocking sync (the 32KB Android Nearby limit is the design target).
  ///
  /// Defaults to 30KB, leaving envelope headroom under the 32KB transport
  /// limit.
  final int maxMessageBytes;

  /// Codec for serializing/deserializing this context's (sync's) protocol
  /// messages.
  ///
  /// Injected by the composition root (`Coordinator` wires a
  /// [SyncMessageCodec]; test harnesses do the same) rather than
  /// constructed inline, so the engine depends only on the shared
  /// [MessageCodec] seam, not a concrete codec class.
  /// [MessageCodec.decode] answers null for a frame outside this codec's
  /// family (e.g. a membership Ping/Ack/PingReq sharing the same transport) — see the
  /// null-check in [_handleIncomingMessage].
  final MessageCodec _codec;

  /// Byte-budget helpers ([SyncMessageCodec.encodedEntrySize],
  /// [SyncMessageCodec.encodedStreamDigestSize]) aren't part of the shared
  /// [MessageCodec] seam — sizing entries/digests against the transport
  /// limit is a sync-specific concern, not something membership's codec
  /// needs. The gossip engine is a sync-context component, so its injected
  /// codec is always a [SyncMessageCodec] in practice (`Coordinator` and
  /// every test harness wire exactly that); this getter makes that
  /// assumption explicit at its call sites instead of scattering casts —
  /// [_fitDeltaToBudget]'s `encodedEntrySize` call, and constructing
  /// [_digestBudgeter] (which needs the concrete type, not the shared
  /// [MessageCodec] seam, for its own digest-sizing helpers).
  SyncMessageCodec get _syncCodec => _codec as SyncMessageCodec;

  /// Random number generator for peer selection.
  /// Injectable for deterministic testing with seeded Random.
  final Random _random;

  /// Drives the periodic gossip round loop: computes each tick's delay
  /// (jittered [effectiveGossipInterval]), runs [performGossipRound], and
  /// reports tick vs. scheduling failures separately (see
  /// [GenerationScheduler]'s class doc for the failure policy and the
  /// forking hazard it forecloses). Built in the constructor body — its
  /// `nextDelay`/`tick` callbacks close over instance members that must
  /// already be initialized.
  late final GenerationScheduler _scheduler;

  /// Generation token for the reactive-push debounce timer only
  /// ([notifyLocalWrite]/[_flushPendingPushes]).
  ///
  /// Before this class adopted [GenerationScheduler] for the round loop, a
  /// single `_generation` counter guarded both the round loop's delay
  /// callback AND this debounce's delay callback — [start] and [stop]
  /// bumped it once and both mechanisms checked it; a *live* (non-stale)
  /// round-loop scheduling failure bumped it too, staleness-gated the same
  /// way. The round loop's half of that is now [_scheduler]'s own internal
  /// concern, which this class cannot observe or reuse (by design — see
  /// [GenerationScheduler]'s doc: it does not expose its generation). This
  /// field keeps the debounce's half working exactly as before: bumped
  /// everywhere the old shared counter was bumped relative to it —
  /// [start], [stop], and (staleness-gated via `_scheduler.isRunning`, in
  /// the `onSchedulingError` callback wired in the constructor) a live
  /// round-loop scheduling failure — so a callback from a debounce
  /// scheduled before any of those events recognizes itself as stale and
  /// does nothing.
  int _pushGeneration = 0;

  /// Subscription to incoming messages (for cleanup on stop).
  StreamSubscription<IncomingMessage>? _messageSubscription;

  /// Channel map for generating digests and handling protocol messages.
  ///
  /// Updated via [setChannels] or [startListening]. Must contain all
  /// channels the local node is a member of.
  Map<ChannelId, ChannelAggregate> _channels = {};

  /// Owns the gossip-round interval policy (CC5-13): static vs. adaptive,
  /// the median-SRTT formula, and the quiescence pacer. See
  /// [GossipTimingPolicy] for why this is a separate object rather than
  /// fields here.
  late final GossipTimingPolicy _timing;

  /// True when anything newsworthy happened since the last round began.
  /// Read-and-cleared by [performGossipRound]; set by [_recordNews]. A
  /// round-scoped read-and-clear flag, not pacing state, so it stays here
  /// rather than moving into [GossipTimingPolicy] with the pacer.
  bool _newsSinceLastRound = true;

  /// News: local append, merge, delta traffic either direction, or a
  /// membership change. Resets the pacer and marks the round non-quiet.
  void _recordNews() {
    _newsSinceLastRound = true;
    _timing.news();
  }

  /// Owns pull-request dedup (at most one outstanding DeltaRequest per
  /// (peer, channel, stream) at a time) and the adaptive per-request
  /// timeout derived from observed delta round-trip time (CC5-1). See
  /// [PendingPullTracker] for the per-peer keying rationale, the
  /// RFC-6298 timeout formula, and why a BLE page-transmit signal can't
  /// come from ping-based RTT.
  late final PendingPullTracker _pendingPullTracker;

  /// Monotonic count of delta batches that merged at least one new entry.
  /// Exposed via [mergedBatchCount] as a coarse "recent sync activity"
  /// signal for applications (G5).
  int _mergedBatchCount = 0;

  static const Duration _metricsWindow = Duration(seconds: 10);

  /// Debounce window for coalescing a burst of local writes into a single
  /// reactive push (rumor mongering — see [notifyLocalWrite]).
  static const Duration _pushDebounce = Duration(milliseconds: 150);

  /// Locally-written entries pending a reactive push, buffered per stream so
  /// a burst of writes within the debounce window coalesces into one push.
  final Map<(ChannelId, StreamId), List<LogEntry>> _pendingPush = {};

  /// True while a debounced push flush is scheduled (coalesces a burst into
  /// one flush).
  bool _pushFlushScheduled = false;

  /// Owns byte-budgeted digest windowing (CC5-1): fitting a digest
  /// request/response to [maxMessageBytes] by selecting a round-robin
  /// rotated subset of (channel, stream) digests when the full set doesn't
  /// fit, so no message is oversized and every stream is covered across
  /// successive rounds (H4). See [DigestBudgeter] for the request/response
  /// cursor split (OBS-3) and the conservative cost model.
  late final DigestBudgeter _digestBudgeter;

  /// Per-peer congestion threshold for backpressure.
  ///
  /// Peers with more than this many pending messages are excluded from
  /// gossip peer selection. The round is only skipped entirely when ALL
  /// reachable peers exceed this threshold.
  static const int _perPeerCongestionThreshold = 3;

  GossipEngine({
    required MessageCodec codec,
    required this.localNode,
    required this.peerDirectory,
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
    this.maxMessageBytes = 30 * 1024,
  }) : _codec = codec,
       _hlcClock = hlcClock,
       _localNodeRepository = localNodeRepository,
       _random = random ?? Random() {
    // Needs nothing but the `timePort` parameter, so it could live in the
    // initializer list — built here instead, grouped with this
    // constructor's other extracted domain-service collaborators
    // ([_timing], [_digestBudgeter]) for one discoverable construction
    // site rather than splitting collaborators across the initializer
    // list and the body.
    _pendingPullTracker = PendingPullTracker(timePort: timePort);
    // Built here rather than the initializer list, mirroring
    // FailureDetector's ProbeTimingPolicy construction (E2/CC5-13): keeps
    // every extracted timing-policy collaborator constructed at the same
    // site across the two engines rather than one in the initializer list
    // and one in the body.
    _timing = GossipTimingPolicy(
      peerDirectory: peerDirectory,
      staticInterval: gossipInterval,
      adaptiveEnabled: adaptiveTimingEnabled,
    );
    // Needs the concrete SyncMessageCodec (its digest-sizing helpers aren't
    // part of the shared MessageCodec seam) — built here, after `_codec` is
    // assigned by the initializer list above, so `_syncCodec`'s cast is
    // valid; same body-construction rationale as `_timing` above.
    _digestBudgeter = DigestBudgeter(
      codec: _syncCodec,
      localNode: localNode,
      maxMessageBytes: maxMessageBytes,
    );
    _scheduler = GenerationScheduler(
      timePort: timePort,
      // ±20% jitter decorrelates gossip loops across nodes so they don't
      // phase-lock into correlated request/response bursts; recomputed
      // fresh every cycle so the pacer's growth/reset each round is
      // reflected in the next tick's delay.
      nextDelay: () => applyJitter(effectiveGossipInterval, _random),
      tick: performGossipRound,
      onTickError: (error, stackTrace) => _emitError(
        PeerSyncError(
          localNode,
          SyncErrorType.protocolError,
          'Gossip round failed: $error',
          occurredAt: DateTime.now(),
          cause: error,
        ),
      ),
      onSchedulingError: (error, stackTrace) {
        // A dead round loop invalidates any reactive-push debounce still
        // in flight too — see [_pushGeneration]'s doc for why this bump
        // belongs here. But GenerationScheduler calls this callback for a
        // STALE failure too (a delay from an old, already-superseded run
        // erroring out late) — its own internal stop is staleness-gated,
        // this callback is not. Gating the bump on isRunning tells the two
        // apart: by the time this callback runs, isRunning reads false
        // exactly when the failure was live (the scheduler's conditional
        // stop runs synchronously first) — a stale failure alongside a
        // currently-live loop leaves isRunning true, so we must NOT bump,
        // or we'd invalidate the live loop's own in-flight debounce and
        // wedge reactive push permanently (only stop() resets the flag).
        // A stale failure while already stopped still bumps here, which is
        // harmless: the flag is already false and any captured generation
        // is already stale regardless. A genuinely live failure must clear
        // `_pushFlushScheduled` itself, not just bump the generation: the
        // bump alone only makes an in-flight debounce recognize itself as
        // stale when it fires — its "stale run — do nothing" early return
        // does not reset the flag — and nothing else ever would, since the
        // scheduler already stopped itself before this callback runs, so a
        // caller's own [stop] (whose reset this flag would otherwise rely
        // on) sees `isRunning` already false and short-circuits as a no-op.
        if (!_scheduler.isRunning) {
          _pushGeneration++;
          _pushFlushScheduled = false;
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
      },
    );
  }

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
  bool get isRunning => _scheduler.isRunning;

  /// Effective gossip round interval. Delegates to [_timing] — see
  /// [GossipTimingPolicy.effectiveInterval] for the interval policy.
  Duration get effectiveGossipInterval => _timing.effectiveInterval;

  /// How long a pending delta request is honoured before it is considered
  /// stale and a replacement may be issued. Delegates to
  /// [_pendingPullTracker] — see [PendingPullTracker.effectiveTimeout] for
  /// the adaptive RFC-6298 formula, its clamping, and the cold-start
  /// default.
  Duration get effectivePendingRequestTimeout =>
      _pendingPullTracker.effectiveTimeout;

  /// Number of delta requests currently in flight (pulls we are awaiting a
  /// response for). A coarse "am I mid-sync?" signal for applications (G5):
  /// non-zero means we are actively pulling data from a peer. Delegates to
  /// [_pendingPullTracker] — see [PendingPullTracker.outstandingCount] for
  /// the expiry-exclusion rationale.
  int get outstandingPullCount => _pendingPullTracker.outstandingCount;

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
    if (_scheduler.isRunning) return;
    // A restart is news — never resume mid-backoff into a stale world.
    _newsSinceLastRound = true;
    _timing.news();
    _pushGeneration++;
    _scheduler.start();
  }

  /// Stops periodic gossip rounds.
  ///
  /// Cancels the timer but does NOT stop message listening. Call
  /// [stopListening] separately if needed.
  void stop() {
    if (!_scheduler.isRunning) return;
    _pushGeneration++;
    _scheduler.stop();
    // Drop any buffered reactive push — the periodic anti-entropy loop is
    // also stopping, and a stale delay callback checks the generation.
    _pendingPush.clear();
    _pushFlushScheduled = false;
    // Drop outstanding delta-request flags: while stopped we don't ingest
    // responses, so a resumed engine should be free to re-request
    // immediately rather than waiting out the pending-request timeout.
    _pendingPullTracker.clearAll();
    // A restart is a fresh diagnosis window for persistent gaps.
    _reportedGaps.clear();
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
    if (!_scheduler.isRunning) return;
    _recordNews();
    _pendingPush.putIfAbsent((channelId, streamId), () => []).add(entry);
    if (_pushFlushScheduled) return;
    _pushFlushScheduled = true;
    final generation = _pushGeneration;
    timePort
        .delay(_pushDebounce)
        .then((_) {
          if (generation != _pushGeneration) return; // stale run — do nothing
          _pushFlushScheduled = false;
          if (_scheduler.isRunning) unawaited(_flushPendingPushes());
        })
        .catchError((Object error, StackTrace stackTrace) {
          if (generation != _pushGeneration) return;
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
          _log(
            LogLevel.error,
            'Reactive push scheduling failed: $error',
            error,
            stackTrace,
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

    final partners = peerDirectory.reachablePartners();
    if (partners.isEmpty) return;

    for (final batch in batches.entries) {
      final (channelId, streamId) = batch.key;
      final push = DeltaResponse(
        sender: localNode,
        channelId: channelId,
        streamId: streamId,
        entries: batch.value,
      );
      if (_codec.encode(push).length > maxMessageBytes) continue;
      for (final partner in partners) {
        await _sendMessage(partner.nodeId, push);
      }
    }
  }

  /// Starts listening to incoming gossip protocol messages.
  ///
  /// Subscribes to [MessagePort.incoming] and processes all anti-entropy
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

  /// Performs a single gossip round (see [effectiveGossipInterval] for cadence).
  ///
  /// Implements Step 1 of the anti-entropy protocol:
  /// 1. Get reachable peers and filter out congested ones (per-peer
  ///    backpressure) and ones we already exchanged with inside the
  ///    current interval (recency suppression, time-based — see
  ///    [SyncPartner.lastAntiEntropyMs])
  /// 2. Select the least-recently-gossiped uncongested candidate (bounded
  ///    coverage; random tiebreak) and mark it gossiped
  /// 3. Generate digests for all channels via [generateDigest]
  /// 4. Send [DigestRequest] to peer
  ///
  /// The peer will respond with their digests ([DigestResponse]), triggering
  /// Step 3 delta request generation. The responder side of an exchange is
  /// recorded too (see the [DigestRequest] branch of
  /// [_handleIncomingMessage]), so a reciprocated exchange counts as
  /// coverage for both sides.
  ///
  /// Returns immediately if no reachable peers exist, or if every reachable
  /// peer is either congested or too fresh to re-gossip with yet.
  Future<void> performGossipRound() async {
    if (_newsSinceLastRound) {
      _newsSinceLastRound = false;
    } else {
      _timing.quietRound();
    }

    final reachable = peerDirectory.reachablePartners();
    if (reachable.isEmpty) return;

    // Filter out congested peers (per-peer backpressure) AND peers we
    // already exchanged with inside the current interval.
    //
    // Deliberate: this reads effectiveGossipInterval AFTER the quietRound()
    // above may have just grown it this very round, so the suppression
    // window here is already the just-grown interval, not the pre-round
    // one. That's intentional and self-correcting — it's time-based (see
    // the recency-suppression note below), so widening the window only
    // widens how long an idle pair goes between exchanges, consistent
    // with the pacer's own stretch, never a correctness issue.
    final interval = effectiveGossipInterval.inMilliseconds;
    final nowMs = timePort.nowMs;
    final candidates = reachable
        .where(
          (p) =>
              messagePort.pendingSendCount(p.nodeId) <=
                  _perPeerCongestionThreshold &&
              // Recency suppression (time-based — deliberately NOT
              // cached-VV state): skip peers we exchanged with inside
              // the current interval. Worst case of a wrong skip is one
              // interval of delay.
              (p.lastAntiEntropyMs == null ||
                  nowMs - p.lastAntiEntropyMs! >= interval),
        )
        .toList();

    if (candidates.isEmpty) {
      _log(
        LogLevel.debug,
        'Skipping gossip round: no stale, uncongested peers',
      );
      return;
    }

    final partner = _selectGossipPartner(candidates);
    // Record that we're gossiping with this peer now, so the next rounds
    // prefer peers we haven't synced with recently (bounded coverage).
    peerDirectory.recordAntiEntropy(partner.nodeId, timePort.nowMs);
    await _sendMessage(partner.nodeId, await _buildDigestRequest());
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
  SyncPartner _selectGossipPartner(List<SyncPartner> candidates) {
    // Never-gossiped (null) sorts before any real timestamp: -1 < 0 <= nowMs.
    int staleKey(SyncPartner p) => p.lastAntiEntropyMs ?? -1;

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
  /// never carry (which would livelock sync entirely, H4). Budgeting itself
  /// is [_digestBudgeter]'s job; this method only generates the input and
  /// renders any [OversizedDigest] diagnostics it reports.
  Future<DigestRequest> _buildDigestRequest() async {
    final all = <ChannelDigest>[];
    for (final channel in _channels.values) {
      all.add(await generateDigest(channel));
    }

    final (digests, oversized) = _digestBudgeter.fitRequest(all);
    for (final o in oversized) {
      _emitError(_oversizedDigestError(o));
    }
    return DigestRequest(sender: localNode, digests: digests);
  }

  /// Renders an [OversizedDigest] diagnostic (a stream whose digest alone
  /// exceeds [maxMessageBytes]) into the [ChannelSyncError] surfaced via
  /// [ErrorCallback]. Kept on the engine (not [_digestBudgeter]) because the
  /// budgeter doesn't know about the engine's error types.
  ChannelSyncError _oversizedDigestError(OversizedDigest o) => ChannelSyncError(
    o.channel,
    SyncErrorType.protocolError,
    'Digest for ${o.channel}/${o.streamId} is ~${o.cost} '
    'bytes and cannot fit maxMessageBytes=$maxMessageBytes; '
    'that stream has too many authors to sync (consider compaction '
    'or sharding the channel)',
    occurredAt: DateTime.now(),
  );

  /// Immediately starts anti-entropy with [peerId] by sending it a
  /// DigestRequest, rather than waiting for the random periodic round to
  /// select it. The gossip analogue of `FailureDetector.probeNewPeer`:
  /// called when a peer connects/reconnects so a fresh join or a healed
  /// partition reconciles right away. With push-pull reciprocation (M1) the
  /// single exchange syncs both directions. No-op when not running.
  Future<void> syncWithPeer(NodeId peerId) async {
    if (!_scheduler.isRunning) return;
    _recordNews();
    try {
      await _sendMessage(peerId, await _buildDigestRequest());
    } catch (e, st) {
      _emitError(
        PeerSyncError(
          peerId,
          SyncErrorType.protocolError,
          'Initial sync with $peerId failed: $e',
          occurredAt: DateTime.now(),
          cause: e,
        ),
      );
      _log(LogLevel.error, 'Initial sync with $peerId failed: $e', e, st);
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
  /// Malformed messages are dropped non-fatally and reported via
  /// [ErrorCallback] (DoS containment) rather than allowed to crash the
  /// message-handling loop.
  Future<void> _handleIncomingMessage(IncomingMessage message) async {
    // Record metrics before processing (even if decode fails)
    final nowMs = timePort.nowMs;
    peerDirectory.recordMessageReceived(
      message.sender,
      message.bytes.length,
      nowMs,
      _metricsWindow.inMilliseconds,
    );

    // Receiving gossip from a peer is unambiguous proof of life. Feed it
    // into SWIM liveness so an actively-syncing peer is never suspected or
    // evicted from the gossip set just because its (lower-frequency) pings
    // were starved behind gossip traffic on a slow transport. No-op for
    // unknown/removed peers.
    peerDirectory.recordContact(message.sender, nowMs);

    final ProtocolMessage? protocolMessage;
    try {
      protocolMessage = _codec.decode(message.bytes);
    } catch (e, st) {
      // Emit error for observability (intentionally non-fatal for DoS
      // prevention): a malformed frame is dropped, not allowed to crash
      // the message-handling loop.
      _emitError(
        PeerSyncError(
          message.sender,
          SyncErrorType.messageCorrupted,
          'Malformed gossip message from ${message.sender}: $e',
          occurredAt: DateTime.now(),
          cause: e,
        ),
      );
      _log(
        LogLevel.error,
        'Malformed gossip message from ${message.sender}: $e',
        e,
        st,
      );
      return;
    }
    // Foreign-family frame (e.g. a membership Ping/Ack/PingReq sharing
    // the same transport) — not ours to handle. Routine traffic, not an
    // error: mirrors the pre-injection behavior where the type-dispatch
    // below simply had no matching branch for it.
    if (protocolMessage == null) return;

    try {
      if (protocolMessage is DigestRequest) {
        _log(
          LogLevel.trace,
          'RECV DigestRequest from ${_shortId(message.sender.value)}: '
          '${protocolMessage.digests.length} channels',
        );
        // A reciprocated exchange is coverage for BOTH sides: record it
        // so our own selector/suppression see this peer as fresh
        // (missing half of WIRE4-1).
        peerDirectory.recordAntiEntropy(message.sender, nowMs);
        final response = await _handleDigestRequest(protocolMessage);
        await _sendMessage(message.sender, response);
        // Push-pull: the request already carries the initiator's version
        // vectors, so reciprocate by pulling anything they advertised that
        // we lack — making each exchange bidirectional instead of pulling
        // only toward the initiator. Reciprocation is *active* sync, so
        // gate it on running: a paused/listen-only engine still answers
        // digests (serves data) but must not initiate new pulls.
        if (_scheduler.isRunning) {
          // A DigestRequest by design carries ALL the sender's channels, so
          // ones we don't share are routine under partial channel overlap —
          // filter them out here rather than letting _computeDeltaRequests
          // emit a protocolError per non-shared channel per round. (On the
          // DigestResponse path the digests are scoped to our own request,
          // so an unknown channel there stays an anomaly worth reporting.)
          final sharedDigests = <ChannelDigest>[];
          for (final digest in protocolMessage.digests) {
            if (_channels.containsKey(digest.channelId)) {
              sharedDigests.add(digest);
            } else {
              _log(
                LogLevel.trace,
                'ignoring reciprocal digest for non-shared channel '
                '${digest.channelId}',
              );
            }
          }
          await _sendDeltaRequests(
            message.sender,
            await _computeDeltaRequests(message.sender, sharedDigests),
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
        if (_scheduler.isRunning) {
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
        // An inbound DeltaRequest means the peer is actively pulling from
        // us — news regardless of whether we can serve anything back.
        _recordNews();
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
        if (_scheduler.isRunning) {
          final continuation = await handleDeltaResponse(protocolMessage);
          if (continuation != null) {
            // Drain the rest of a truncated backlog immediately.
            await _sendDeltaRequests(message.sender, [continuation]);
          }
        }
      }
    } catch (e, st) {
      // A handler failure is distinct from a decode failure: the message
      // was well-formed, so this is a protocol/application-level fault
      // (e.g. a downstream callback throwing) rather than corrupted bytes.
      _emitError(
        PeerSyncError(
          message.sender,
          SyncErrorType.protocolError,
          'Failed handling ${protocolMessage.runtimeType} from '
          '${message.sender}: $e',
          occurredAt: DateTime.now(),
          cause: e,
        ),
      );
      _log(
        LogLevel.error,
        'Failed handling ${protocolMessage.runtimeType} from '
        '${message.sender}: $e',
        e,
        st,
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
      peerDirectory.recordMessageSent(recipient, bytes.length);
      return true;
    } catch (e, st) {
      _emitError(
        PeerSyncError(
          recipient,
          SyncErrorType.peerUnreachable,
          'Failed to send ${message.runtimeType} to $recipient: $e',
          occurredAt: DateTime.now(),
          cause: e,
        ),
      );
      _log(
        LogLevel.error,
        'Failed to send ${message.runtimeType} to $recipient: $e',
        e,
        st,
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
  /// - `entry.sequence > peerVersion[entry.author]`
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
    // larger, so the response is fitted independently by
    // [_digestBudgeter.fitResponse], with its own rotation cursor so an
    // over-budget response covers every stream across successive exchanges
    // too, instead of truncating the same tail every time (OBS-3).
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
        // Dominance filter (WIRE4-5): if the requester's vector already
        // covers ours, echoing it back is pure redundancy. Safe: the
        // requester pulls only when the response shows us ahead, and the
        // responder-behind direction is our own reciprocal pull.
        if (streamDigest.version.dominates(version)) continue;
        flat.add((
          channel: channelDigest.channelId,
          digest: StreamDigest(
            streamId: streamDigest.streamId,
            version: version,
          ),
        ));
      }
    }

    final (digests, oversized) = _digestBudgeter.fitResponse(flat);
    for (final o in oversized) {
      _emitError(_oversizedDigestError(o));
    }
    return DigestResponse(sender: localNode, digests: digests);
  }

  /// Handles digest response from a peer (Step 3).
  ///
  /// Compares peer's version vectors with ours to identify entries we're
  /// missing. Generates [DeltaRequest] only for streams where the peer has
  /// entries we don't have (i.e., where our version does not dominate theirs).
  ///
  /// Exposed as public for testing. Called by [_handleIncomingMessage].
  Future<List<DeltaRequest>> handleDigestResponse(DigestResponse response) {
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
  ({List<LogEntry> accepted, List<ContiguityGap> gaps})
  _selectContiguousEntries(List<LogEntry> entries, VersionVector ourVersion) {
    final byAuthor = <NodeId, List<LogEntry>>{};
    for (final entry in entries) {
      byAuthor.putIfAbsent(entry.author, () => []).add(entry);
    }

    final acceptUpTo = <NodeId, int>{};
    final gaps = <ContiguityGap>[];
    for (final authorEntry in byAuthor.entries) {
      final author = authorEntry.key;
      final authorEntries = authorEntry.value
        ..sort((a, b) => a.sequence.compareTo(b.sequence));
      var next = ourVersion[author] + 1;
      int? firstBeyondGap;
      for (final entry in authorEntries) {
        if (entry.sequence < next) continue; // already held
        if (entry.sequence != next) {
          // Gap — stop accepting this author; record it so the drop is
          // diagnosable (a silent drop here is how a peer that compacted
          // past our position stalls sync invisibly, COR3-1).
          firstBeyondGap = entry.sequence;
          break;
        }
        next++;
      }
      acceptUpTo[author] = next - 1;
      if (firstBeyondGap != null) {
        gaps.add(
          ContiguityGap(
            author: author,
            expectedNext: next,
            firstAvailable: firstBeyondGap,
          ),
        );
      }
    }

    final accepted = entries
        .where(
          (e) =>
              e.sequence > ourVersion[e.author] &&
              e.sequence <= acceptUpTo[e.author]!,
        )
        .toList();
    return (accepted: accepted, gaps: gaps);
  }

  /// Sends the given [requests] to [recipient], releasing the pending flag
  /// for any that fail to transmit (the peer can never answer a request it
  /// didn't receive, so holding the flag would block re-requesting for the
  /// full timeout).
  Future<void> _sendDeltaRequests(
    NodeId recipient,
    List<DeltaRequest> requests,
  ) async {
    // Initiating a pull is news: we're actively chasing entries we're
    // missing, so the round is not quiet.
    if (requests.isNotEmpty) _recordNews();
    for (final request in requests) {
      final sent = await _sendMessage(recipient, request);
      if (!sent) {
        _pendingPullTracker.release(
          recipient,
          request.channelId,
          request.streamId,
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

        // Dedup gate: skip if a non-expired pull to THIS peer for this
        // stream is already pending. A single synchronous call — see
        // [PendingPullTracker.tryMark] for why the check and the mark
        // must happen together, with no `await` between them.
        if (!_pendingPullTracker.tryMark(
          peer,
          channelDigest.channelId,
          streamDigest.streamId,
        )) {
          continue;
        }

        var ourVersion = await _computeVersionVector(
          channelDigest.channelId,
          streamDigest.streamId,
        );

        // The peer claims entries under OUR authorship beyond our own
        // high-water mark: this channel/stream identity was removed and
        // recreated (or local storage was reset) while peers kept the old
        // history. Appending from the stale-low sequence would collide
        // with it — the new entries would be invisible to every peer whose
        // vector already covers the numbers, and two payloads would exist
        // under one entry identity. Adopt the claim as a sequence floor so
        // new local appends allocate past it (COR3-4). A lying peer can
        // only make us skip sequence numbers, which is harmless.
        final theirClaimForUs = streamDigest.version[localNode];
        if (theirClaimForUs > ourVersion[localNode]) {
          await entryRepository.adoptVersionFloor(
            channelDigest.channelId,
            streamDigest.streamId,
            VersionVector({localNode: theirClaimForUs}),
          );
          _log(
            LogLevel.warning,
            'peer ${_shortId(peer.value)} holds our authorship up to '
            '$theirClaimForUs in ${channelDigest.channelId}/'
            '${streamDigest.streamId} but our mark is '
            '${ourVersion[localNode]} — adopting as sequence floor '
            '(recreated channel identity?)',
          );
          ourVersion = await _computeVersionVector(
            channelDigest.channelId,
            streamDigest.streamId,
          );
        }

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
          _pendingPullTracker.release(
            peer,
            channelDigest.channelId,
            streamDigest.streamId,
          );
        }
      }
    }

    return deltaRequests;
  }

  /// Handles delta request from a peer (Step 4).
  ///
  /// Computes the entries the peer is missing via [computeDelta] and
  /// returns them in a [DeltaResponse], truncated so the encoded message
  /// fits [maxMessageBytes]. Truncation keeps a prefix of the
  /// repository's timestamp order — per-author HLC monotonicity means a
  /// prefix is per-author sequence-contiguous, so the requester's version
  /// vector never develops holes. The requester obtains the remainder in
  /// subsequent anti-entropy rounds as its version vector advances.
  ///
  /// Exposed as public for testing. Called by [_handleIncomingMessage].
  Future<DeltaResponse> handleDeltaRequest(DeltaRequest request) async {
    // Serve only channels/streams this node actually has (mirrors the
    // ingestion guard in [handleDeltaResponse]): data for a channel we
    // never joined — e.g. phantom entries persisted before the ingestion
    // guard existed — must not cross the membership boundary (COR3-2).
    final channel = _channels[request.channelId];
    if (channel == null || !channel.hasStream(request.streamId)) {
      _log(
        LogLevel.trace,
        'not serving delta for ${request.channelId}/${request.streamId}: '
        'not a channel/stream of ours',
      );
      return DeltaResponse(
        sender: localNode,
        channelId: request.channelId,
        streamId: request.streamId,
        entries: const [],
      );
    }

    final delta = await computeDelta(
      request.channelId,
      request.streamId,
      request.since,
    );

    // A requester positioned below our compaction floor asked for entries
    // retention pruned away — nobody can serve them from here. Report the
    // floor so the requester can adopt truncated history; otherwise it
    // drops the survivors as gapped and re-requests the same page forever
    // (COR3-1).
    final fullFloor = await entryRepository.getCompactionFloor(
      request.channelId,
      request.streamId,
    );
    var floor = VersionVector.empty;
    if (fullFloor.entries.isNotEmpty) {
      final belowFloor = <NodeId, int>{
        for (final f in fullFloor.entries.entries)
          if (request.since[f.key] < f.value) f.key: f.value,
      };
      if (belowFloor.isNotEmpty) floor = VersionVector(belowFloor);
    }

    final (fitted, hasMore) = _fitDeltaToBudget(request, delta);
    // Serving data back to a puller is news; an empty response (nothing to
    // give) is not.
    if (fitted.isNotEmpty) _recordNews();
    return DeltaResponse(
      sender: localNode,
      channelId: request.channelId,
      streamId: request.streamId,
      entries: fitted,
      hasMore: hasMore,
      floor: floor,
    );
  }

  /// Selects the prefix of [delta] whose encoded [DeltaResponse] fits
  /// [maxMessageBytes].
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
    var size = baseSize;
    for (final entry in delta) {
      if (blockedAuthors.contains(entry.author)) continue;
      // +1 per entry for the JSON array separator.
      final cost = _syncCodec.encodedEntrySize(entry) + 1;

      if (baseSize + cost > maxMessageBytes) {
        // Undeliverable: no message can ever carry this entry.
        _emitError(
          ChannelSyncError(
            request.channelId,
            SyncErrorType.protocolError,
            'Entry ${entry.author}#${entry.sequence} in '
            '${request.channelId}/${request.streamId} encodes to '
            '$cost bytes and can never fit '
            'maxMessageBytes=$maxMessageBytes; '
            'it cannot be synced to peers',
            occurredAt: DateTime.now(),
          ),
        );
        blockedAuthors.add(entry.author);
        continue;
      }

      if (size + cost > maxMessageBytes) {
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

  /// Handles a delta response from a peer — the final step of anti-entropy.
  ///
  /// Merges received entries into our [EntryRepository] and advances the
  /// local HLC clock so subsequent local writes are causally after the
  /// received entries. Exposed as public for testing; production callers
  /// reach it via [_handleIncomingMessage].
  ///
  /// Returns a continuation [DeltaRequest] (for the dispatcher to send) when
  /// the sender truncated the response to the size budget
  /// ([DeltaResponse.hasMore]) AND we applied new entries — draining a
  /// backlog at link speed instead of one page per periodic round. Returns
  /// null otherwise (no more, or no progress — the latter guards against an
  /// infinite continuation loop).
  Future<DeltaRequest?> handleDeltaResponse(DeltaResponse response) {
    // Ingest only channels/streams this node actually has. Reactive pushes
    // fan out to every reachable peer, so receiving data for a channel we
    // never joined is routine — silently storing it would accumulate
    // unbounded phantom data (never advertised, never compacted) and leak
    // channel content across the membership boundary (COR3-2). The
    // request path applies the same rule when computing pulls.
    final channel = _channels[response.channelId];
    if (channel == null || !channel.hasStream(response.streamId)) {
      _log(
        LogLevel.trace,
        'ignoring delta for ${response.channelId}/${response.streamId}: '
        'not a channel/stream of ours',
      );
      return Future.value(null);
    }

    // Serialize merges per (channel, stream): the merge body reads the
    // version vector, filters, and appends across awaits, so two
    // overlapping responses (per-peer pending keys deliberately allow
    // concurrent same-stream pulls from two peers) would both pass the
    // filter against the same stale vector — the second append then
    // rejects the whole batch and its genuinely-new entries are delayed
    // to a later round, with a spurious error blaming the peer (COR3-9).
    // Failure isolation between chained merges is [KeyedTaskChain]'s
    // contract, not reimplemented here.
    final chainKey = (response.channelId, response.streamId);
    return _mergeChain.enqueue(chainKey, () => _mergeDeltaResponse(response));
  }

  /// Per-(channel, stream) chain of in-flight merges — see
  /// [handleDeltaResponse].
  final KeyedTaskChain<(ChannelId, StreamId)> _mergeChain = KeyedTaskChain();

  Future<DeltaRequest?> _mergeDeltaResponse(DeltaResponse response) async {
    // If this response answers a request we were tracking, [complete]
    // removes it and feeds the elapsed time to the adaptive-timeout
    // estimator as an RTT sample (dominated by page transmit time) — see
    // [PendingPullTracker.complete].
    final elapsedMs = _pendingPullTracker.complete(
      response.sender,
      response.channelId,
      response.streamId,
    );

    // A solicited response may carry the sender's compaction floor: the
    // range below it was pruned by retention and is unobtainable, so adopt
    // it as truncated history (raising our high-water mark and our own
    // floor) BEFORE filtering — the surviving entries then pass the
    // contiguity guard instead of being dropped forever (COR3-1).
    // Unsolicited responses cannot move our floor: we never asked this
    // sender, and honoring an unsolicited claim would let any peer make us
    // skip history that is still obtainable elsewhere.
    if (elapsedMs != null && response.floor.entries.isNotEmpty) {
      await entryRepository.adoptVersionFloor(
        response.channelId,
        response.streamId,
        response.floor,
      );
      _log(
        LogLevel.info,
        'adopted truncated history for '
        '${response.channelId}/${response.streamId} from ${response.sender}: '
        'floor ${response.floor.entries}',
      );
    }

    if (response.entries.isEmpty) return null;

    // Keep only entries we don't already have, in per-author contiguous
    // order. Duplicate/stale DeltaResponses (a slow peer answering after the
    // pending timeout, overlap between two peers' responses) must not be
    // handed to the repository — whose contract rejects duplicates — nor
    // re-reported via onEntriesMerged as if they were new.
    final ourVersion = await _computeVersionVector(
      response.channelId,
      response.streamId,
    );
    final selection = _selectContiguousEntries(response.entries, ourVersion);
    final newEntries = selection.accepted;
    if (selection.gaps.isNotEmpty) {
      _reportContiguityGaps(
        response,
        selection.gaps,
        solicited: elapsedMs != null,
      );
    }
    if (newEntries.isEmpty) return null;

    // Only entries we actually merge drive the clock: a rejected entry
    // (gapped, duplicate) must not be able to touch local causality state
    // (COR3-10).
    _updateHlcFromEntries(newEntries);

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

    // Out-of-order: any merged entry sorts before the previous tail. The
    // tail is known only by timestamp, so an entry TYING it may still sort
    // before it on the author tiebreak — treat ties as possibly
    // out-of-order (a rare extra rebuild beats silent fold/rebuild
    // divergence, COR3-27).
    final containsOutOfOrderEntries =
        previousTailHlc != null &&
        newEntries.any((e) => e.timestamp <= previousTailHlc);

    _mergedBatchCount++;
    _recordNews();

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
      _pendingPullTracker.markContinuation(
        response.sender,
        response.channelId,
        response.streamId,
      );
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
    _pendingPullTracker.clearAll();
    _reportedGaps.clear();
  }

  /// Clears pending delta requests addressed to [peer].
  ///
  /// Called when a peer is removed: its in-flight pulls can never complete,
  /// so leaving them would block re-requesting after a fast reconnect and
  /// hold [outstandingPullCount] above zero until expiry.
  void clearPendingRequestsForPeer(NodeId peer) {
    _recordNews();
    _pendingPullTracker.clearForPeer(peer);
    _reportedGaps.removeWhere((key) => key.$1 == peer);
  }

  /// Contiguity gaps already reported, keyed by
  /// (peer, channel, stream, author, expectedNext).
  ///
  /// A persistent hole (e.g. a peer that compacted past our position)
  /// recurs on every round — report it once per position, not per round.
  /// Bounded structurally: one entry per (peer × stream × author × gap
  /// position); cleared with the peer's pending state.
  final Set<(NodeId, ChannelId, StreamId, NodeId, int)> _reportedGaps = {};

  /// Reports entries dropped by the contiguity guard.
  ///
  /// A gapped SOLICITED response is always anomalous — the responder was
  /// asked for everything after our version vector, so a hole means it no
  /// longer has (or never had) entries we need; sync for that author is
  /// stalled until the range becomes obtainable. Surface it via
  /// [ErrorCallback] once per gap position.
  ///
  /// A gapped UNSOLICITED push is routine — a reactive push carries the
  /// writer's newest entries, and we may simply not have pulled the prefix
  /// yet; anti-entropy will catch up. Trace log only.
  void _reportContiguityGaps(
    DeltaResponse response,
    List<ContiguityGap> gaps, {
    required bool solicited,
  }) {
    for (final gap in gaps) {
      if (!solicited) {
        _log(
          LogLevel.trace,
          'push for ${response.channelId}/${response.streamId} dropped: '
          'behind for ${gap.author} (next needed ${gap.expectedNext}, push '
          'starts at ${gap.firstAvailable}); anti-entropy will catch up',
        );
        continue;
      }
      final key = (
        response.sender,
        response.channelId,
        response.streamId,
        gap.author,
        gap.expectedNext,
      );
      if (!_reportedGaps.add(key)) continue;
      _log(
        LogLevel.warning,
        'delta response from ${response.sender} has a sequence hole for '
        '${gap.author} in ${response.channelId}/${response.streamId}: '
        'expected ${gap.expectedNext}, first available ${gap.firstAvailable}',
      );
      _emitError(
        ChannelSyncError(
          response.channelId,
          SyncErrorType.protocolError,
          'Peer ${response.sender} answered a delta request with a sequence '
          'hole for author ${gap.author} in '
          '${response.channelId}/${response.streamId}: expected seq '
          '${gap.expectedNext}, first available ${gap.firstAvailable}. The '
          'peer has likely compacted entries we never received; sync for '
          'this author is stalled until the missing range is obtainable.',
          occurredAt: DateTime.now(),
        ),
      );
    }
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
        _log(
          LogLevel.error,
          'Failed to persist HLC clock state: $error',
          error,
          stackTrace,
        );
      }),
    );
  }
}

/// A per-author sequence hole found while filtering a delta response.
///
/// The batch offered [firstAvailable] while we still need [expectedNext] —
/// everything from [firstAvailable] on was dropped to preserve the
/// version-vector high-water-mark invariant.
class ContiguityGap {
  final NodeId author;

  /// The sequence we need next (our high-water mark + 1).
  final int expectedNext;

  /// The lowest offered sequence beyond the hole.
  final int firstAvailable;

  const ContiguityGap({
    required this.author,
    required this.expectedNext,
    required this.firstAvailable,
  });
}
