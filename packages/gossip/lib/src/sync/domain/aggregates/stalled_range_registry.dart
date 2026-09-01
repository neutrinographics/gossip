import 'dart:math';

import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/sync/domain/entities/stalled_range.dart';

/// The stalled author ranges observed per peer, and the request shaping
/// they imply.
///
/// Fully deterministic and dependency-free: time arrives as `nowMs`
/// arguments, and [shapeSince] is a pure query — a stale record contributes
/// nothing whether or not [evictSatisfied] has pruned it yet, so request
/// correctness never depends on eviction timing.
///
/// Backoff doubling happens at probe *issue* ([markProbed]), not on the
/// response: new gap evidence ([recordGap] on an existing record) only
/// refreshes what we know. This keeps a multi-chunk drain from saturating
/// the backoff in one exchange, and a lost probe response from leaving the
/// record permanently probe-due.
class StalledRangeRegistry {
  StalledRangeRegistry({
    this.initialBackoff = const Duration(seconds: 30),
    this.maxBackoff = const Duration(minutes: 10),
  });

  final Duration initialBackoff;
  final Duration maxBackoff;

  /// Records keyed by stream identity, then author — the shape every
  /// operation reads: [shapeSince]/[markProbed]/[evictSatisfied] touch one
  /// stream's authors, never the whole registry.
  final Map<(NodeId, ChannelId, StreamId), Map<NodeId, StalledRange>>
  _ranges = {};

  /// The shaped `since` vector for a request to [peer] being built now.
  ///
  /// Owns the never-lower rule: a suppressed author contributes
  /// `max(base, advertisedMax, digestCeiling)`. A stale record (our
  /// coverage moved past its expectation) and a record whose probe window
  /// is open (that request IS the probe) contribute nothing.
  VersionVector shapeSince(
    NodeId peer,
    ChannelId channelId,
    StreamId streamId,
    VersionVector base, {
    VersionVector? digestCeiling,
    required int nowMs,
  }) {
    final authors = _ranges[(peer, channelId, streamId)];
    if (authors == null) return base;
    Map<NodeId, int>? shaped;
    for (final range in authors.values) {
      if (range.isStale(base) || range.isProbeDue(nowMs)) continue;
      final ceiling = digestCeiling?[range.author] ?? 0;
      final value = max(base[range.author], max(range.advertisedMax, ceiling));
      if (value > base[range.author]) {
        (shaped ??= {...base.entries})[range.author] = value;
      }
    }
    return shaped == null ? base : VersionVector(shaped);
  }

  /// Records a solicited gap for [author]. A new stall opens its first
  /// probe window at [initialBackoff]; an existing record is refreshed
  /// (expectation moves with the evidence, the advertised maximum only
  /// rises) without touching the probe schedule — more gapped chunks are
  /// not more probe failures.
  void recordGap(
    NodeId peer,
    ChannelId channelId,
    StreamId streamId,
    NodeId author, {
    required int expectedNext,
    required int advertisedMax,
    required int nowMs,
  }) {
    final authors = _ranges.putIfAbsent((peer, channelId, streamId), () => {});
    final existing = authors[author];
    authors[author] = existing == null
        ? StalledRange(
            author: author,
            expectedNext: expectedNext,
            advertisedMax: advertisedMax,
            retryAtMs: nowMs + initialBackoff.inMilliseconds,
            probeCount: 0,
          )
        : existing.refreshed(
            expectedNext: expectedNext,
            advertisedMax: advertisedMax,
          );
  }

  /// Marks every probe-due record on this stream as probed: an unshaped
  /// request is leaving for [peer] right now, and it IS the probe. Re-arms
  /// each window immediately at doubled backoff, so the suppression
  /// survives a lost or empty probe response. Call it when a request built
  /// from [shapeSince]'s output is successfully handed to the transport —
  /// a request that never left the node must not consume the window.
  void markProbed(
    NodeId peer,
    ChannelId channelId,
    StreamId streamId,
    int nowMs,
  ) {
    final authors = _ranges[(peer, channelId, streamId)];
    if (authors == null) return;
    authors.updateAll(
      (author, range) => range.isProbeDue(nowMs)
          ? range.probed(
              nowMs: nowMs,
              initialBackoffMs: initialBackoff.inMilliseconds,
              maxBackoffMs: maxBackoff.inMilliseconds,
            )
          : range,
    );
  }

  /// Removes records whose expectation [ourVersion] has passed — memory
  /// hygiene only; [shapeSince] already ignores them.
  void evictSatisfied(
    NodeId peer,
    ChannelId channelId,
    StreamId streamId,
    VersionVector ourVersion,
  ) {
    final key = (peer, channelId, streamId);
    final authors = _ranges[key];
    if (authors == null) return;
    authors.removeWhere((author, range) => range.isStale(ourVersion));
    if (authors.isEmpty) _ranges.remove(key);
  }

  /// Drops every record for [peer] — a removed peer is a fresh diagnosis
  /// window on reconnect.
  void clearForPeer(NodeId peer) =>
      _ranges.removeWhere((key, authors) => key.$1 == peer);

  /// Drops everything — a restart is a fresh diagnosis window.
  void clearAll() => _ranges.clear();
}
