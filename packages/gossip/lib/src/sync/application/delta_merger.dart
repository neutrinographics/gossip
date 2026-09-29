import 'dart:async';

import 'package:gossip/src/shared/domain/errors/sync_error.dart';
import 'package:gossip/src/shared/domain/interfaces/time_port.dart';
import 'package:gossip/src/shared/domain/interfaces/local_node_repository.dart';
import 'package:gossip/src/shared/domain/services/keyed_task_chain.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/log_level.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/sync/domain/interfaces/entry_repository.dart';
import 'package:gossip/src/sync/domain/entities/pull_request.dart';
import 'package:gossip/src/sync/domain/messages/delta_response.dart';
import 'package:gossip/src/sync/domain/aggregates/stalled_range_registry.dart';
import 'package:gossip/src/sync/domain/services/hlc_clock.dart';
import 'package:gossip/src/sync/domain/value_objects/answered_pull.dart';

/// Owns `GossipEngine`'s delta-merge pipeline: filtering a [DeltaResponse]
/// down to the per-author contiguous prefix it can safely apply, appending
/// it, advancing the local HLC, and deciding whether a continuation pull is
/// owed, plus the contiguity guard and gap-reporting state that pipeline
/// depends on.
///
/// Pulled out of `GossipEngine`, which interleaved this filtering/merge
/// logic with digest/delta message dispatch and pull-request bookkeeping —
/// this class's contiguity guard and per-(channel, stream) serialization
/// have correctness invariants worth stating on their own (see [merge]'s
/// doc for the interleaving hazard they close), so they read better as one
/// small collaborator than as private methods scattered across the engine.
///
/// `GossipEngine` still owns the ingestion guard (whether a response's
/// channel/stream is one we actually have — it reads engine-owned channel
/// state) and the pulls in flight. This class notifies the engine of two
/// engine-owned side effects via the `onNewEntriesMerged` and
/// `onContinuationIssued` constructor callbacks — not by exposing them as
/// return-value fields the engine reacts to after [merge] returns — because
/// both must fire at a specific point *inside* the per-stream serialized
/// merge body:
/// - `onNewEntriesMerged` must fire before `onEntriesMerged` is awaited, so
///   the batch counter and news flag reflect a merge before any downstream
///   listener is notified of it.
/// - `onContinuationIssued` must fire synchronously, still inside the
///   chained merge task, before the continuation is returned — it is handed
///   what the continuation asks from and what it is for, and answers with
///   the request the engine issued. Recording a request in flight from
///   outside the chain would add a Future-chaining hop that a concurrently
///   in-flight message for the same stream could interleave into.
///
/// The continuation itself is returned, never sent: transmission is the
/// engine's seam, where a refused send takes the request back by its own
/// identity and a successful one consumes the probe window.
class DeltaMerger {
  DeltaMerger({
    required EntryRepository entryRepository,
    HlcClock? hlcClock,
    required LocalNodeRepository localNodeRepository,
    EntriesMergedCallback? onEntriesMerged,
    ErrorCallback? onError,
    LogCallback? onLog,
    required void Function() onNewEntriesMerged,
    required ContinuationIssuer onContinuationIssued,
    required StalledRangeRegistry stalledRanges,
    required TimePort timePort,
  }) : _entryRepository = entryRepository,
       _hlcClock = hlcClock,
       _localNodeRepository = localNodeRepository,
       _onEntriesMerged = onEntriesMerged,
       _onError = onError,
       _onLog = onLog,
       _onNewEntriesMerged = onNewEntriesMerged,
       _onContinuationIssued = onContinuationIssued,
       _stalledRanges = stalledRanges,
       _timePort = timePort;

  final EntryRepository _entryRepository;
  final HlcClock? _hlcClock;
  final LocalNodeRepository _localNodeRepository;
  final EntriesMergedCallback? _onEntriesMerged;
  final ErrorCallback? _onError;
  final LogCallback? _onLog;
  final void Function() _onNewEntriesMerged;
  final ContinuationIssuer _onContinuationIssued;

  /// Shared with the engine: the merger records solicited gaps here and
  /// shapes its continuation requests with it, so a multi-chunk drain
  /// never re-ships a range the peer already failed to supply.
  final StalledRangeRegistry _stalledRanges;
  final TimePort _timePort;

  /// Emits an error through the callback if one is registered.
  void _emitError(SyncError error) {
    _onError?.call(error);
  }

  /// Logs a message if logging is enabled.
  void _log(
    LogLevel level,
    String message, [
    Object? error,
    StackTrace? stack,
  ]) {
    _onLog?.call(level, message, error, stack);
  }

  /// Per-(channel, stream) chain of in-flight merges — see [merge].
  final KeyedTaskChain<(ChannelId, StreamId)> _mergeChain = KeyedTaskChain();

  /// Filters, applies, and (if needed) requests continuation for one
  /// [DeltaResponse].
  ///
  /// Serialized per (channel, stream): the merge body reads the version
  /// vector, filters, and appends across awaits, so two overlapping
  /// responses for the same stream (per-peer pending keys deliberately
  /// allow concurrent same-stream pulls from two peers) would both pass
  /// the filter against the same stale vector — the second append then
  /// rejects the whole batch and its genuinely-new entries are delayed to
  /// a later round, with a spurious error blaming the peer.
  /// Failure isolation between chained merges is [KeyedTaskChain]'s
  /// contract, not reimplemented here.
  ///
  /// [answered] is the pull this response answered, null when it answered
  /// none. It gates floor adoption, gap severity and whether there is a
  /// continuation at all, and says what the pull was still for. The caller
  /// decides it — a peer's own claim can't be trusted for it — and passes it
  /// in rather than this class reaching into the pulls in flight.
  Future<({PullRequest? continuation, bool mergedNewEntries})> merge(
    DeltaResponse response, {
    required AnsweredPull? answered,
  }) {
    final chainKey = (response.channelId, response.streamId);
    return _mergeChain.enqueue(
      chainKey,
      () => _mergeInner(response, answered: answered),
    );
  }

  Future<({PullRequest? continuation, bool mergedNewEntries})> _mergeInner(
    DeltaResponse response, {
    required AnsweredPull? answered,
  }) async {
    // Solicited means: this response answered a pull of ours, which the
    // engine settled against the requests it has in flight before calling
    // here.
    final solicited = answered != null;
    // A solicited response may carry the sender's compaction floor: the
    // range below it was pruned by retention and is unobtainable, so adopt
    // it as truncated history (raising our high-water mark and our own
    // floor) BEFORE filtering — the surviving entries then pass the
    // contiguity guard instead of being dropped forever.
    // Unsolicited responses cannot move our floor: we never asked this
    // sender, and honoring an unsolicited claim would let any peer make us
    // skip history that is still obtainable elsewhere.
    if (solicited && response.floor.entries.isNotEmpty) {
      await _entryRepository.adoptVersionFloor(
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

    if (response.entries.isEmpty) {
      return (continuation: null, mergedNewEntries: false);
    }

    // Keep only entries we don't already have, in per-author contiguous
    // order. Duplicate/stale DeltaResponses (a slow peer answering after
    // the pending timeout, overlap between two peers' responses) must not
    // be handed to the repository — whose contract rejects duplicates —
    // nor re-reported via onEntriesMerged as if they were new.
    final ourVersion = await _entryRepository.getVersionVector(
      response.channelId,
      response.streamId,
    );
    final selection = _selectContiguousEntries(response.entries, ourVersion);
    final newEntries = selection.accepted;
    if (selection.gaps.isNotEmpty) {
      _reportContiguityGaps(response, selection.gaps, solicited: solicited);
      // Solicited only, matching the reporting rule: an unsolicited gapped
      // response already means "anti-entropy will catch up" and must not
      // poison the pull path.
      if (solicited) {
        for (final gap in selection.gaps) {
          _stalledRanges.recordGap(
            response.sender,
            response.channelId,
            response.streamId,
            gap.author,
            expectedNext: gap.expectedNext,
            advertisedMax: gap.advertisedMax,
            nowMs: _timePort.nowMs,
          );
          _log(
            LogLevel.debug,
            'suppressing pulls of ${gap.author} from ${response.sender} '
            'for ${response.channelId}/${response.streamId}: peer cannot '
            'supply ${gap.expectedNext}..${gap.firstAvailable - 1} '
            '(advertised max ${gap.advertisedMax})',
          );
        }
      }
    }
    if (newEntries.isEmpty) {
      return (continuation: null, mergedNewEntries: false);
    }

    // Only entries we actually merge drive the clock: a rejected entry
    // (gapped, duplicate) must not be able to touch local causality state.
    _updateHlcFromEntries(newEntries);

    // Snapshot the current tail HLC before appending to detect out-of-order
    final previousTailHlc = await _entryRepository.getTailTimestamp(
      response.channelId,
      response.streamId,
    );

    await _entryRepository.appendAll(
      response.channelId,
      response.streamId,
      newEntries,
    );

    // Out-of-order: any merged entry sorts before the previous tail. The
    // tail is known only by timestamp, so an entry TYING it may still sort
    // before it on the author tiebreak — treat ties as possibly
    // out-of-order (a rare extra rebuild beats silent fold/rebuild
    // divergence).
    final containsOutOfOrderEntries =
        previousTailHlc != null &&
        newEntries.any((e) => e.timestamp <= previousTailHlc);

    // Fires the engine's batch-count/news bookkeeping BEFORE
    // onEntriesMerged is awaited (see this class's doc for why this must
    // be a callback fired here, not the engine reacting after [merge]
    // returns).
    _onNewEntriesMerged();

    await _onEntriesMerged?.call(
      response.channelId,
      response.streamId,
      newEntries,
      containsOutOfOrderEntries,
    );

    if (!response.hasMore) return (continuation: null, mergedNewEntries: true);

    // Only a response that answered a request of ours is continued: a page
    // nobody asked for is merged as the push it is, and what remains of it
    // is pulled by whatever the next digest exchange plans, like anything
    // else. Continuing it instead would put a request on the wire for a
    // stream this node had not decided to pull.
    if (answered == null) {
      _log(
        LogLevel.trace,
        'a page for ${response.channelId}/${response.streamId} from '
        '${response.sender} claims more but answered no pull of ours; the '
        'next digest exchange plans what is left',
      );
      return (continuation: null, mergedNewEntries: true);
    }

    // The continuation is still for what this page left owed, and carries
    // what this page carried: which of them the next page opens with, and
    // whether an author's run was cut here or was complete, is the
    // responder's to know, so a page continuing a carried author is
    // recognised without being required.
    final wanted = answered.remaining;
    final carrying = response.firstByAuthor.keys.toSet();
    if (wanted.isEmpty && carrying.isEmpty) {
      // Only a page with no entries at all, which cannot reach here:
      // [_mergeInner] answers such a response above, before anything is
      // applied. Stated as the backstop it is, because a request for no
      // author is not a request and constructing one would throw out of an
      // inbound-message handler.
      _log(
        LogLevel.debug,
        'not continuing an answer for ${response.channelId}/'
        '${response.streamId} from ${response.sender}: it claims more but '
        'is for no author',
      );
      return (continuation: null, mergedNewEntries: true);
    }

    // Continue draining from the same peer at our advanced version. No
    // digest ceiling mid-drain; the stored advertised maximum suffices, and
    // staleness self-corrects through the probe cycle. Any probe this
    // leaves unshaped is marked at the engine's send seam, which every
    // continuation passes through — never here, where transmission hasn't
    // happened yet.
    final advanced = await _entryRepository.getVersionVector(
      response.channelId,
      response.streamId,
    );
    final since = _stalledRanges.shapeSince(
      response.sender,
      response.channelId,
      response.streamId,
      advanced,
      nowMs: _timePort.nowMs,
    );
    // Issues the continuation synchronously, still inside this chained
    // merge, right before returning it (see this class's doc for why the
    // timing matters).
    return (
      continuation: _onContinuationIssued(
        response.sender,
        response.channelId,
        response.streamId,
        since,
        wanted: wanted,
        carrying: carrying,
      ),
      mergedNewEntries: true,
    );
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
          // past our position stalls sync invisibly).
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
            // The list is sorted by sequence, so the last entry is the
            // response's advertised maximum for this author.
            advertisedMax: authorEntries.last.sequence,
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

  /// Clears all reported contiguity gaps.
  ///
  /// Call this when a peer disconnects to allow the same gap to be
  /// re-diagnosed on reconnect. Without clearing, a persistent gap would
  /// silently stop being reported after the first sighting.
  void clearReportedGaps() {
    _reportedGaps.clear();
  }

  /// Clears reported contiguity gaps attributed to [peer].
  ///
  /// Called when a single peer is removed: a fresh connection to it (or a
  /// replacement peer) deserves a fresh diagnosis window, not one
  /// permanently silenced by a gap reported against the old connection.
  void clearReportedGapsForPeer(NodeId peer) {
    _reportedGaps.removeWhere((key) => key.$1 == peer);
  }
}

/// How the merger asks its owner to issue the continuation a page is owed:
/// it is handed whom to ask, what the continuation asks from, what it is
/// still for and what the page before it carried, and answers with the
/// request the owner recorded as in flight.
///
/// A function rather than a returned description because the request must be
/// recorded inside the merge's serialized span — see [DeltaMerger]'s doc —
/// while putting it on the wire stays the owner's.
typedef ContinuationIssuer =
    PullRequest Function(
      NodeId peer,
      ChannelId channelId,
      StreamId streamId,
      VersionVector since, {
      required Set<NodeId> wanted,
      required Set<NodeId> carrying,
    });

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

  /// The highest sequence the response offered for this author — what a
  /// suppression must ask "since" to silence the author.
  final int advertisedMax;

  const ContiguityGap({
    required this.author,
    required this.expectedNext,
    required this.firstAvailable,
    required this.advertisedMax,
  });
}
