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
class StalledRangeRegistry {
  StalledRangeRegistry({
    this.initialBackoff = const Duration(seconds: 30),
    this.maxBackoff = const Duration(minutes: 10),
  });

  final Duration initialBackoff;
  final Duration maxBackoff;

  final Map<(NodeId, ChannelId, StreamId, NodeId), StalledRange> _ranges = {};

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
    Map<NodeId, int>? shaped;
    for (final range in _ranges.values) {
      if (range.peer != peer ||
          range.channelId != channelId ||
          range.streamId != streamId) {
        continue;
      }
      if (range.isStale(base) || range.isProbeDue(nowMs)) continue;
      final ceiling = digestCeiling?[range.author] ?? 0;
      final value = max(base[range.author], max(range.advertisedMax, ceiling));
      if (value > base[range.author]) {
        (shaped ??= {...base.entries})[range.author] = value;
      }
    }
    return shaped == null ? base : VersionVector(shaped);
  }

  /// Records a solicited gap for [author], or re-arms an existing record
  /// with doubled backoff and a refreshed advertised maximum.
  void recordGap(
    NodeId peer,
    ChannelId channelId,
    StreamId streamId,
    NodeId author, {
    required int expectedNext,
    required int advertisedMax,
    required int nowMs,
  }) {
    final key = (peer, channelId, streamId, author);
    final existing = _ranges[key];
    _ranges[key] = existing == null
        ? StalledRange(
            peer: peer,
            channelId: channelId,
            streamId: streamId,
            author: author,
            expectedNext: expectedNext,
            advertisedMax: advertisedMax,
            retryAtMs: nowMs + initialBackoff.inMilliseconds,
            probeCount: 0,
          )
        : existing.rearmed(
            nowMs: nowMs,
            advertisedMax: advertisedMax,
            initialBackoffMs: initialBackoff.inMilliseconds,
            maxBackoffMs: maxBackoff.inMilliseconds,
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
    _ranges.removeWhere(
      (key, range) =>
          range.peer == peer &&
          range.channelId == channelId &&
          range.streamId == streamId &&
          range.isStale(ourVersion),
    );
  }

  /// Drops every record for [peer] — a removed peer is a fresh diagnosis
  /// window on reconnect.
  void clearForPeer(NodeId peer) =>
      _ranges.removeWhere((key, range) => range.peer == peer);

  /// Drops everything — a restart is a fresh diagnosis window.
  void clearAll() => _ranges.clear();
}
