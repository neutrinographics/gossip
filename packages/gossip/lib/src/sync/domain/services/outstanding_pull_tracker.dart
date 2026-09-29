import 'package:gossip/src/shared/domain/services/duration_clamp.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/rtt_estimate.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/sync/domain/aggregates/outstanding_pulls.dart';
import 'package:gossip/src/sync/domain/entities/pull_request.dart';
import 'package:gossip/src/sync/domain/services/legacy_correlation.dart';
import 'package:gossip/src/sync/domain/value_objects/answered_pull.dart';
import 'package:gossip/src/sync/domain/value_objects/correlation.dart';
import 'package:gossip/src/sync/domain/value_objects/request_id.dart';

/// What the gossip engine does with the pulls it has in flight, as pure
/// functions over an [OutstandingPulls]: issuing one, releasing one the
/// transport refused, deciding which request an arriving response answers,
/// and forgetting those a stop or a removal can never see answered. This is
/// what replaces deciding all of it from a single mark per (peer, channel,
/// stream).
///
/// Two policies live here, over the set rather than in its key. The planner's
/// gate ([issueUnlessOutstanding]) keeps at most one *planned* pull per peer
/// and stream: it dedupes duplicate digests from the same peer while never
/// letting a stalled slow peer block pulling the same stream from a faster
/// one — safe because the merge path's contiguity guard filters overlapping
/// entries before append. A continuation ([issue]) is owed rather than
/// planned and passes no gate: the peer is mid-answer, and the rest of the
/// page is only ever asked for once.
///
/// Staleness is the adaptive deadline ([effectiveTimeout]): RFC-6298 style,
/// SRTT + 4·RTTVAR over observed delta round-trips, clamped to 2–30s, 8s
/// before any sample. It measures page-transmit time on the deployment's
/// transport, so a large page still in flight is never re-requested — a
/// duplicate request is pure congestion amplification on a slow link. A
/// request past the deadline is no longer honoured and is dropped when the
/// next pull of that stream is planned, which is the only place it can be
/// dropped without a timer.
///
/// Correlation is by identity: a response that names a request we hold from
/// that sender is that request's answer whatever it carries, and a hole it
/// leaves is a stall to record rather than grounds to doubt it. Content is
/// consulted only for a peer that has never named a request
/// ([LegacyCorrelation]), and never again once it has.
///
/// Time is an input rather than a port held here, which is what makes a
/// staleness verdict and a round-trip sample reproducible from the value and
/// the reading alone. The transitions that decide and change answer both at
/// once — the decision and the change are one step, never a read the caller
/// stitches to a later write.
///
/// The reading is the caller's, taken just before the step, so it can be
/// older than the step by however long the caller was paused between the two.
/// That is the accepted limit of taking time as an input, and it is benign
/// here: the only thing a stale reading can do is honour a request that
/// expired during the pause, or issue a request or a round-trip sample short
/// by the pause — a shift of one scheduling delay against deadlines measured
/// in seconds, and never a request recorded as in flight after it was
/// answered.
abstract final class OutstandingPullTracker {
  /// Pre-sample default, sized to comfortably exceed one ~30KB page over a
  /// slow link so a cold-start pull is never deemed stale mid-transmission.
  static const Duration _defaultTimeout = Duration(seconds: 8);
  static const Duration _minTimeout = Duration(seconds: 2);
  static const Duration _maxTimeout = Duration(seconds: 30);

  /// How long a pull is honoured before it is considered stale and the stream
  /// may be pulled again.
  static Duration effectiveTimeout(OutstandingPulls pulls) {
    final rtt = pulls.rtt;
    if (rtt == null) return _defaultTimeout;
    return rtt.suggestedTimeout(
      minTimeout: _minTimeout,
      maxTimeout: _maxTimeout,
    );
  }

  /// Whether a pull to [peer] for this stream is in flight and still honoured
  /// — the planner's question, answered of the whole set, so a continuation
  /// counts as much as the pull that preceded it.
  static bool isOutstanding(
    OutstandingPulls pulls, {
    required NodeId peer,
    required ChannelId channel,
    required StreamId stream,
    required int nowMs,
  }) => _live(pulls, nowMs: nowMs, key: (peer, channel, stream)).isNotEmpty;

  /// How many requests are in flight and still honoured, across every peer —
  /// what a caller watching for quiescence reads. A request past the deadline
  /// is dead rather than "syncing…", so counting it would wedge that signal
  /// until the next pull of its stream is planned.
  static int outstandingCount(OutstandingPulls pulls, {required int nowMs}) =>
      _live(pulls, nowMs: nowMs).length;

  /// Plans a pull of [stream] from [peer] and issues it in ONE step — the
  /// dedup gate. Answers no request, and the value it was given, while a pull
  /// of that stream to that peer is still honoured; otherwise drops the ones
  /// past the deadline, which nothing else will ever drop, and answers the
  /// request to send.
  ///
  /// A dropped request's answer, should it still come, names a request we no
  /// longer hold and is a push (a stall is not recorded, its round trip is
  /// not sampled). So only answers inside the current deadline teach the
  /// deadline, and a link slower than the pre-sample default cannot teach it
  /// to grow — the cost of a deadline that expires requests rather than waits
  /// on them, chosen over sampling a wrong round trip against the wrong
  /// request.
  static ({OutstandingPulls state, PullRequest? request})
  issueUnlessOutstanding(
    OutstandingPulls pulls, {
    required NodeId peer,
    required ChannelId channel,
    required StreamId stream,
    required VersionVector since,
    required Set<NodeId> wanted,
    required int nowMs,
  }) {
    if (isOutstanding(
      pulls,
      peer: peer,
      channel: channel,
      stream: stream,
      nowMs: nowMs,
    )) {
      return (state: pulls, request: null);
    }
    // Every request to the key is past the deadline here: a live one would
    // have answered above.
    final swept = {...pulls.requests}
      ..removeWhere(
        (_, request) =>
            request.peer == peer &&
            request.channelId == channel &&
            request.streamId == stream,
      );
    return issue(
      pulls.copyWith(requests: swept),
      peer: peer,
      channel: channel,
      stream: stream,
      since: since,
      wanted: wanted,
      nowMs: nowMs,
    );
  }

  /// Issues a pull of [stream] from [peer], gated by nothing: what a
  /// continuation is, and what the planner has already decided to send.
  static ({OutstandingPulls state, PullRequest request}) issue(
    OutstandingPulls pulls, {
    required NodeId peer,
    required ChannelId channel,
    required StreamId stream,
    required VersionVector since,
    required Set<NodeId> wanted,
    required int nowMs,
    Set<NodeId> carrying = const {},
  }) {
    final request = PullRequest(
      id: RequestId.mint(nowMs, pulls.nextSequence),
      peer: peer,
      channelId: channel,
      streamId: stream,
      since: since,
      wanted: wanted,
      issuedAtMs: nowMs,
      carrying: carrying,
    );
    return (
      state: pulls.copyWith(
        requests: {...pulls.requests, request.id: request},
        nextSequence: pulls.nextSequence + 1,
      ),
      request: request,
    );
  }

  /// Takes back the request [id] names: the transport refused the send, and a
  /// peer can never answer a request it did not receive. Nothing else is
  /// touched — another pull to the same peer for the same stream is a request
  /// of its own, still owed.
  static OutstandingPulls release(OutstandingPulls pulls, RequestId id) =>
      pulls.copyWith(requests: {...pulls.requests}..remove(id));

  /// Settles a response from [sender] against what we have in flight: which
  /// pull it answered, if any, and what it taught us about how that peer
  /// answers, if that was new.
  ///
  /// A response naming a request we hold from that sender is that request's
  /// answer, whatever it carries, and the round trip is measured from that
  /// request's own issue time. One naming a request we do not hold —
  /// expired, cleared, or from before a restart — is a push, though the
  /// sender has still shown that it answers by reference. One naming a
  /// request of ours that went to a different peer, or asked about a
  /// different stream, is neither: nothing of ours is at stake, so nothing is
  /// answered and nothing is concluded about the sender.
  ///
  /// From a peer that has named a request before, a response naming none is a
  /// push — including one that begins exactly where an outstanding request
  /// asked, which on a mesh is simply that peer's own newest write. Only a
  /// peer that has never named one is judged by content
  /// ([LegacyCorrelation]), and doing so is itself what we learn about it.
  static ({OutstandingPulls state, Correlated correlated}) answer(
    OutstandingPulls pulls, {
    required NodeId sender,
    required RequestId? inReplyTo,
    required ChannelId channel,
    required StreamId stream,
    required Map<NodeId, int> firstByAuthor,
    required VersionVector floor,
    required bool hasMore,
    bool marksPartialPages = true,
    required int nowMs,
  }) {
    if (inReplyTo != null) {
      return _answerByReference(
        pulls,
        sender: sender,
        inReplyTo: inReplyTo,
        channel: channel,
        stream: stream,
        nowMs: nowMs,
      );
    }
    if (pulls.peers[sender] == Correlation.byReference) {
      return (state: pulls, correlated: _nothingSettled);
    }

    final settled = LegacyCorrelation.answer(
      pulls,
      sender: sender,
      channel: channel,
      stream: stream,
      firstByAuthor: firstByAuthor,
      floor: floor,
      hasMore: hasMore,
      marksPartialPages: marksPartialPages,
      nowMs: nowMs,
    );
    final answered = settled.answered;
    if (answered == null) {
      return (state: settled.state, correlated: _nothingSettled);
    }
    return (
      state: settled.state.copyWith(
        peers: {...settled.state.peers, sender: Correlation.legacy},
      ),
      correlated: Correlated(
        answered: answered,
        learned: pulls.peers[sender] == Correlation.legacy
            ? null
            : Correlation.legacy,
      ),
    );
  }

  /// Clears every pull in flight (engine stop). What the transport was
  /// measured at is still true of it after a restart, and how each peer
  /// answers is still true of that peer, so both survive: a stop is not a
  /// restart, and nothing outstanding is being measured any more anyway.
  static OutstandingPulls clearAll(OutstandingPulls pulls) =>
      pulls.copyWith(requests: const {});

  /// Forgets [peer]: the pulls addressed to it, which it will never answer,
  /// and how it answered them, which is a fact about a peer we no longer
  /// have. Its next named answer teaches us that again.
  static OutstandingPulls clearForPeer(OutstandingPulls pulls, NodeId peer) =>
      pulls.copyWith(
        requests: {...pulls.requests}
          ..removeWhere((_, request) => request.peer == peer),
        peers: {...pulls.peers}..remove(peer),
      );

  /// Clears the pulls for [channel], across every peer (channel removal). A
  /// pull addressed to a channel that no longer exists can never be answered
  /// — the stream it was for is gone — so it must not survive to suppress the
  /// first pull of a channel later recreated under the same id.
  static OutstandingPulls clearForChannel(
    OutstandingPulls pulls,
    ChannelId channel,
  ) => pulls.copyWith(
    requests: {...pulls.requests}
      ..removeWhere((_, request) => request.channelId == channel),
  );

  /// The value whose evidence includes a round trip of [elapsedMs], clamped
  /// into the band the deadline is drawn from so one outlier cannot move it
  /// out of range; unchanged for a reading of zero or less, which measures a
  /// clock rather than a transport.
  ///
  /// Reached by [LegacyCorrelation] as well, so the whole rule samples the
  /// one way, with the one clamp.
  static OutstandingPulls sampled(OutstandingPulls pulls, int elapsedMs) {
    if (elapsedMs <= 0) return pulls;
    final sample = clampDuration(
      Duration(milliseconds: elapsedMs),
      min: _minTimeout,
      max: _maxTimeout,
    );
    return pulls.copyWith(
      rtt: (pulls.rtt ?? RttEstimate.initial()).update(
        sample,
        isFirstSample: !pulls.hasMeasuredRoundTrip,
      ),
      sampleCount: pulls.sampleCount + 1,
    );
  }

  static ({OutstandingPulls state, Correlated correlated}) _answerByReference(
    OutstandingPulls pulls, {
    required NodeId sender,
    required RequestId inReplyTo,
    required ChannelId channel,
    required StreamId stream,
    required int nowMs,
  }) {
    // A reference is honoured for the request it names and nothing else: the
    // sender must be the peer that request went to, and the response must be
    // for the stream it asked about. An id is minted for one peer and one
    // stream; a peer echoing it from elsewhere is a fault to be inert about —
    // retiring the request, or worse adopting a floor for a stream we never
    // asked that peer about, would act on the fault. "Whatever it carries" is
    // about the entries, not the address.
    final named = pulls.requests[inReplyTo];
    if (named != null &&
        (named.peer != sender ||
            named.channelId != channel ||
            named.streamId != stream)) {
      return (state: pulls, correlated: _nothingSettled);
    }

    final learned = pulls.peers[sender] == Correlation.byReference
        ? null
        : Correlation.byReference;
    final correlating = pulls.copyWith(
      peers: {...pulls.peers, sender: Correlation.byReference},
    );
    if (named == null) {
      return (
        state: correlating,
        correlated: Correlated(answered: null, learned: learned),
      );
    }

    final elapsedMs = nowMs - named.issuedAtMs;
    return (
      state: sampled(
        correlating.copyWith(
          requests: {...correlating.requests}..remove(inReplyTo),
        ),
        elapsedMs,
      ),
      correlated: Correlated(
        answered: AnsweredPull(elapsedMs: elapsedMs, remaining: const {}),
        learned: learned,
      ),
    );
  }

  /// The requests still honoured: every one of them, or those to one peer for
  /// one stream when [key] names it.
  ///
  /// The deadline boundary lives here alone — a request is honoured while
  /// less than the deadline has passed, so one exactly at it is already
  /// stale, and both the planner's gate and the quiescence count read that
  /// one rule.
  static Iterable<PullRequest> _live(
    OutstandingPulls pulls, {
    required int nowMs,
    (NodeId, ChannelId, StreamId)? key,
  }) {
    final timeoutMs = effectiveTimeout(pulls).inMilliseconds;
    return pulls.requests.values.where(
      (request) =>
          nowMs - request.issuedAtMs < timeoutMs &&
          (key == null ||
              (request.peer == key.$1 &&
                  request.channelId == key.$2 &&
                  request.streamId == key.$3)),
    );
  }

  static const Correlated _nothingSettled = Correlated(
    answered: null,
    learned: null,
  );
}
