import 'dart:math';

import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';

/// One stalled author range: a peer answered a solicited pull with a
/// per-author sequence hole, so asking again is waste until the world
/// changes or the probe window opens.
///
/// Identity is `(peer, channelId, streamId, author)`. Transitions produce
/// new values ([rearmed]); nothing mutates in place.
class StalledRange {
  const StalledRange({
    required this.peer,
    required this.channelId,
    required this.streamId,
    required this.author,
    required this.expectedNext,
    required this.advertisedMax,
    required this.retryAtMs,
    required this.probeCount,
  });

  final NodeId peer;
  final ChannelId channelId;
  final StreamId streamId;
  final NodeId author;

  /// Our `ourVersion[author] + 1` when the gap was observed — the staleness
  /// sentinel: a different expectation means the world changed and this
  /// record no longer describes it.
  final int expectedNext;

  /// The highest sequence the peer advertised for the author in the gapped
  /// response — asking "since this" makes the peer send nothing for the
  /// author.
  final int advertisedMax;

  /// When the next probe is allowed (epoch milliseconds).
  final int retryAtMs;

  /// How many times this stall has been re-confirmed; drives the backoff
  /// doubling.
  final int probeCount;

  bool isStale(VersionVector ourVersion) =>
      ourVersion[author] + 1 != expectedNext;

  bool isProbeDue(int nowMs) => nowMs >= retryAtMs;

  /// The doubled-backoff successor after a probe re-confirmed the gap.
  StalledRange rearmed({
    required int nowMs,
    required int advertisedMax,
    required int initialBackoffMs,
    required int maxBackoffMs,
  }) {
    var backoffMs = initialBackoffMs;
    for (var i = 0; i <= probeCount && backoffMs < maxBackoffMs; i++) {
      backoffMs = min(backoffMs * 2, maxBackoffMs);
    }
    return StalledRange(
      peer: peer,
      channelId: channelId,
      streamId: streamId,
      author: author,
      expectedNext: expectedNext,
      advertisedMax: advertisedMax,
      retryAtMs: nowMs + backoffMs,
      probeCount: probeCount + 1,
    );
  }
}
