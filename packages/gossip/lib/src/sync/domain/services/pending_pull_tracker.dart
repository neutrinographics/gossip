import 'package:gossip/src/shared/domain/interfaces/time_port.dart';
import 'package:gossip/src/shared/domain/services/duration_clamp.dart';
import 'package:gossip/src/shared/domain/services/rtt_tracker.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';

/// Owns `GossipEngine`'s pull-request dedup and adaptive per-request
/// timeout (CC5-1 engine slice): at most one outstanding DeltaRequest per
/// (peer, channel, stream) at a time, and how long that request is honoured
/// before it is considered stale.
///
/// Pulled out of `GossipEngine`, which interleaved this bookkeeping with
/// digest/delta message handling — the dedup gate ([tryMark]) is a single
/// synchronous check-and-mark with a correctness invariant worth stating on
/// its own (see its doc), and the adaptive timeout ([effectiveTimeout]) is
/// a self-contained RFC-6298 estimator, so both read better as one small
/// collaborator than as fields scattered across the engine.
class PendingPullTracker {
  PendingPullTracker({required TimePort timePort}) : _timePort = timePort;

  final TimePort _timePort;

  /// Tracks pending DeltaRequests to prevent duplicate requests.
  ///
  /// Keyed per-(peer, channel, stream): the timestamp (in ms) when the
  /// request was sent (or last continued — see [markContinuation]). When
  /// the corresponding DeltaResponse is received, [complete] removes the
  /// entry. Entries older than [effectiveTimeout] are considered expired
  /// and can be replaced with new requests (see [tryMark]).
  ///
  /// Keying by peer (not just stream) does two things: it keeps deduping
  /// duplicate DigestResponses from the *same* peer (the original
  /// sync-loop bug), while no longer letting a stalled *slow* peer block
  /// requesting the same stream from a *faster* peer — safe because
  /// duplicate/overlapping entries are filtered by the contiguity guard
  /// before merge.
  final Map<(NodeId, ChannelId, StreamId), int> _pendingSince = {};

  /// EWMA of observed delta round-trip times (request sent → response
  /// received), used to derive [effectiveTimeout]. This directly measures
  /// page-transmit time on the deployment's transport — a signal
  /// ping-based RTT can't provide (a 30KB page over BLE takes ~1-2 orders
  /// of magnitude longer than a 66-byte ping).
  final RttTracker _rttTracker = RttTracker();

  /// Default pending-delta timeout used before any delta round-trip has
  /// been observed. Sized to comfortably exceed one ~30KB page over a slow
  /// BLE link (~7.5s at a few KB/s) so a request is never deemed stale
  /// mid-transmission on a cold start.
  static const Duration _defaultTimeout = Duration(seconds: 8);
  static const Duration _minTimeout = Duration(seconds: 2);
  static const Duration _maxTimeout = Duration(seconds: 30);

  /// How long a pending delta request is honoured before it is considered
  /// stale and a replacement may be issued.
  ///
  /// Adaptive: derived (RFC-6298 style, SRTT + 4·RTTVAR) from observed
  /// delta round-trips so it always exceeds one page's transmit time on
  /// the actual transport, then clamped to [[_minTimeout], [_maxTimeout]].
  /// Before any round-trip is observed it is [_defaultTimeout]. This stops
  /// a large page still in flight from being re-requested (duplicate
  /// requests are pure congestion amplification on a slow link).
  Duration get effectiveTimeout {
    if (!_rttTracker.hasReceivedSamples) return _defaultTimeout;
    return _rttTracker.suggestedTimeout(
      minTimeout: _minTimeout,
      maxTimeout: _maxTimeout,
    );
  }

  /// Checks for a live pending entry and marks a new one, SYNCHRONOUSLY,
  /// in one call — the dedup gate. The incoming-message listener doesn't
  /// await handlers, so two queued DigestResponses for the same (peer,
  /// channel, stream) interleave at the call site; checking and marking
  /// without an `await` between them is what makes the dedup effective.
  /// This is structural now, not a caller discipline to uphold: there is
  /// no `await` inside this method for two interleaved calls to
  /// interleave around.
  ///
  /// Returns true and marks when no live entry exists for this key —
  /// including when a previous entry has aged past [effectiveTimeout] (an
  /// expired entry is replaced, not treated as still live). Returns false
  /// without marking when a live (non-expired) entry already exists.
  bool tryMark(NodeId peer, ChannelId channel, StreamId stream) {
    final key = (peer, channel, stream);
    final pendingSince = _pendingSince[key];
    if (pendingSince != null) {
      final elapsed = _timePort.nowMs - pendingSince;
      if (elapsed < effectiveTimeout.inMilliseconds) return false;
      _pendingSince.remove(key);
    }
    _pendingSince[key] = _timePort.nowMs;
    return true;
  }

  /// Releases the pending entry for this key, if any.
  ///
  /// Called when a marked pull turns out not to need tracking after all:
  /// the send failed (the peer can never answer a request it didn't
  /// receive), or the dominance check found nothing left to request.
  void release(NodeId peer, ChannelId channel, StreamId stream) {
    _pendingSince.remove((peer, channel, stream));
  }

  /// Re-marks this key as pending for a continuation request.
  ///
  /// [complete] already removed the entry when the prior page's response
  /// arrived; this immediately re-arms it for the follow-up request
  /// draining the rest of a truncated backlog.
  void markContinuation(NodeId peer, ChannelId channel, StreamId stream) {
    _pendingSince[(peer, channel, stream)] = _timePort.nowMs;
  }

  /// Removes the pending entry for this key, if tracked, and returns the
  /// elapsed time in milliseconds since it was marked — or null if this
  /// key had no tracked entry (an unsolicited response, or one whose entry
  /// already expired and was replaced or cleared).
  ///
  /// When the elapsed reading is positive, feeds it as an RTT sample
  /// (clamped to [[_minTimeout], [_maxTimeout]]) into the estimator
  /// backing [effectiveTimeout] — this is the real delta round-trip,
  /// dominated by page-transmit time. A non-positive reading (e.g. a
  /// clock that hasn't advanced) is not a meaningful RTT sample and is
  /// dropped rather than distorting the estimate.
  int? complete(NodeId peer, ChannelId channel, StreamId stream) {
    final pendingSince = _pendingSince.remove((peer, channel, stream));
    if (pendingSince == null) return null;

    final elapsedMs = _timePort.nowMs - pendingSince;
    if (elapsedMs > 0) {
      final sample = clampDuration(
        Duration(milliseconds: elapsedMs),
        min: _minTimeout,
        max: _maxTimeout,
      );
      _rttTracker.recordSample(sample);
    }
    return elapsedMs;
  }

  /// Count of pending entries not yet expired (per [effectiveTimeout]).
  ///
  /// Excludes expired entries: a pull whose peer never answered is dead,
  /// not "syncing…" — counting it would wedge a caller's quiescence
  /// signal until the same key happens to be re-evaluated (by [tryMark]
  /// or [complete]).
  int get outstandingCount {
    final timeoutMs = effectiveTimeout.inMilliseconds;
    final nowMs = _timePort.nowMs;
    return _pendingSince.values
        .where((since) => nowMs - since < timeoutMs)
        .length;
  }

  /// Clears every pending entry.
  ///
  /// Call this when the owning engine stops or a peer disconnects, so
  /// resumed/reconnected pulls can be re-requested immediately instead of
  /// waiting out [effectiveTimeout].
  void clearAll() {
    _pendingSince.clear();
  }

  /// Clears pending entries addressed to [peer] only.
  ///
  /// Called when a single peer is removed: its in-flight pulls can never
  /// complete, so leaving them would block re-requesting after a fast
  /// reconnect and hold [outstandingCount] above zero until expiry.
  void clearForPeer(NodeId peer) {
    _pendingSince.removeWhere((key, _) => key.$1 == peer);
  }
}
