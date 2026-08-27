import 'dart:async';

import 'package:gossip/src/shared/domain/interfaces/time_port.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';

/// Owns `GossipEngine`'s reactive-push debounce state machine (CC5-1):
/// coalescing a burst of local writes within [_pushDebounce]
/// into a single push, instead of one push per write.
///
/// Pulled out of `GossipEngine`, which interleaved this bookkeeping with
/// the round-loop scheduler and message handling — this class's
/// generation/flag/buffer trio has a correctness invariant worth stating
/// on its own (see [_pushGeneration]'s doc), so it reads better as one
/// small collaborator than as fields scattered across the engine.
///
/// `GossipEngine` still owns *sending* — [_flush] receives a snapshot of
/// the buffered batches and is responsible for looking up reachable
/// peers, encoding, and sending. This class owns only *when*: debouncing,
/// coalescing, and recognizing a stale run across [invalidate],
/// [invalidateAndClear], and [onRoundLoopDead].
class ReactivePusher {
  ReactivePusher({
    required TimePort timePort,
    required bool Function() isRunning,
    required Future<void> Function(
      Map<(ChannelId, StreamId), List<LogEntry>> batches,
    )
    flush,
    required void Function(Object error, StackTrace stackTrace)
    onSchedulingFailure,
  }) : _timePort = timePort,
       _isRunning = isRunning,
       _flush = flush,
       _onSchedulingFailure = onSchedulingFailure;

  final TimePort _timePort;
  final bool Function() _isRunning;
  final Future<void> Function(
    Map<(ChannelId, StreamId), List<LogEntry>> batches,
  )
  _flush;
  final void Function(Object error, StackTrace stackTrace) _onSchedulingFailure;

  /// Debounce window for coalescing a burst of local writes into a single
  /// reactive push (rumor mongering — see [notifyWrite]).
  static const Duration _pushDebounce = Duration(milliseconds: 150);

  /// Locally-written entries pending a reactive push, buffered per stream
  /// so a burst of writes within the debounce window coalesces into one
  /// push.
  final Map<(ChannelId, StreamId), List<LogEntry>> _pendingPush = {};

  /// True while a debounced push flush is scheduled (coalesces a burst
  /// into one flush).
  bool _pushFlushScheduled = false;

  /// Generation token for the debounce: bumped by [invalidate],
  /// [invalidateAndClear], and [onRoundLoopDead] so a debounce callback
  /// scheduled by a run any of those has since superseded recognizes
  /// itself as stale and does nothing. (For the pre-GenerationScheduler
  /// shared-counter design this descends from, see gossip_engine.dart's
  /// history prior to the CC5-1 extraction.)
  int _pushGeneration = 0;

  /// Reactive dissemination (rumor mongering): buffers [entry] for a
  /// debounced push, coalescing a burst of writes within the debounce
  /// window into a single [_flush] call.
  ///
  /// No-op when [_isRunning] reads false: a paused/listen-only engine
  /// disseminates nothing (consistent with push-pull reciprocation).
  void notifyWrite(ChannelId channelId, StreamId streamId, LogEntry entry) {
    if (!_isRunning()) return;
    _pendingPush.putIfAbsent((channelId, streamId), () => []).add(entry);
    if (_pushFlushScheduled) return;
    _pushFlushScheduled = true;
    final generation = _pushGeneration;
    _timePort
        .delay(_pushDebounce)
        .then((_) {
          if (generation != _pushGeneration) return; // stale run — do nothing
          _pushFlushScheduled = false;
          if (_isRunning()) {
            final batches = Map.of(_pendingPush);
            _pendingPush.clear();
            unawaited(_flush(batches));
          }
        })
        .catchError((Object error, StackTrace stackTrace) {
          if (generation != _pushGeneration) return;
          _pushFlushScheduled = false;
          _pendingPush.clear();
          _onSchedulingFailure(error, stackTrace);
        });
  }

  /// Invalidates any in-flight debounce without touching the buffer or
  /// the scheduled flag — for `GossipEngine.start()`: a restart is news,
  /// never resumed mid-debounce into a stale world, but a write buffered
  /// just before the restart is still worth pushing once the fresh
  /// debounce (from the next [notifyWrite]) fires.
  void invalidate() {
    _pushGeneration++;
  }

  /// Invalidates any in-flight debounce AND drops the buffer — for
  /// `GossipEngine.stop()`: the periodic anti-entropy loop is also
  /// stopping, so a buffered write has no live delivery mechanism left to
  /// ride along on and a stale delay callback would otherwise find the
  /// generation already bumped by [invalidate] alone but the buffer still
  /// holding stale entries.
  void invalidateAndClear() {
    _pushGeneration++;
    _pendingPush.clear();
    _pushFlushScheduled = false;
  }

  /// Called when the round loop dies from a LIVE scheduling failure (the
  /// caller gates this against a stale failure — see its call site's doc
  /// for the live/stale distinction this depends on). Bumps the
  /// generation AND clears the in-flight flag — bumping alone is not
  /// enough to unwedge reactive push (the C6 wedge): an in-flight
  /// debounce recognizes a bumped generation as stale only when it
  /// *fires*, and its "stale run — do nothing" early return does not
  /// reset [_pushFlushScheduled] — so nothing else ever would, since the
  /// round loop already stopped itself before this runs, meaning the
  /// caller's own eventual [invalidateAndClear] (via `stop()`), whose
  /// reset this flag would otherwise rely on, sees the engine already
  /// stopped and short-circuits as a no-op. Without clearing it here
  /// directly, a write issued after a healed restart would find the flag
  /// still (wrongly) true and silently skip scheduling its own debounce
  /// forever.
  ///
  /// Deliberately does NOT clear the buffer (unlike [invalidateAndClear]):
  /// entries already buffered before the round loop died are not lost —
  /// they ride along with the next successful flush once a fresh write
  /// after the restart schedules one.
  void onRoundLoopDead() {
    _pushGeneration++;
    _pushFlushScheduled = false;
  }
}
