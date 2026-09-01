import 'dart:math';

import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';

/// One stalled author range: a peer answered a solicited pull with a
/// per-author sequence hole, so asking again is waste until the world
/// changes or the probe window opens.
///
/// Identity is `(peer, channelId, streamId, author)` — held by the
/// registry's keying; the entity carries only the author (needed to read
/// vectors) and its lifecycle state. Transitions produce new values
/// ([refreshed], [probed]); nothing mutates in place.
///
/// The lifecycle separates two kinds of events deliberately:
/// - **New gap evidence** ([refreshed]) — another chunk of the same drain,
///   or a probe's response re-confirming the hole. Updates what we know
///   (expectation, advertised maximum) without touching the backoff: more
///   chunks are not more failures.
/// - **A probe being issued** ([probed]) — the moment an unshaped request
///   leaves for the peer. Re-arms the window immediately and doubles the
///   backoff, so a lost or empty probe response can never leave the record
///   permanently probe-due.
class StalledRange {
  const StalledRange({
    required this.author,
    required this.expectedNext,
    required this.advertisedMax,
    required this.retryAtMs,
    required this.probeCount,
  });

  final NodeId author;

  /// Our `ourVersion[author] + 1` when the gap was last observed — the
  /// staleness sentinel: a different expectation means the world changed
  /// and this record no longer describes it.
  final int expectedNext;

  /// The highest sequence the peer has ever advertised for the author in a
  /// gapped response — asking "since this" makes the peer send nothing for
  /// the author. Monotonic: a small probe page must never lower it.
  final int advertisedMax;

  /// When the next probe is allowed (epoch milliseconds).
  final int retryAtMs;

  /// How many probes have been issued for this stall; drives the backoff
  /// doubling.
  final int probeCount;

  bool isStale(VersionVector ourVersion) =>
      ourVersion[author] + 1 != expectedNext;

  bool isProbeDue(int nowMs) => nowMs >= retryAtMs;

  /// The successor after new gap evidence: expectation moves with the
  /// evidence, the advertised maximum only ever rises, and the probe
  /// schedule is untouched.
  StalledRange refreshed({
    required int expectedNext,
    required int advertisedMax,
  }) => StalledRange(
    author: author,
    expectedNext: expectedNext,
    advertisedMax: max(this.advertisedMax, advertisedMax),
    retryAtMs: retryAtMs,
    probeCount: probeCount,
  );

  /// The successor after a probe was issued: the window re-arms now, at
  /// double the previous backoff (capped), whatever the probe's response
  /// turns out to be.
  StalledRange probed({
    required int nowMs,
    required int initialBackoffMs,
    required int maxBackoffMs,
  }) {
    var backoffMs = initialBackoffMs;
    for (var i = 0; i < probeCount + 1 && backoffMs < maxBackoffMs; i++) {
      backoffMs = min(backoffMs * 2, maxBackoffMs);
    }
    return StalledRange(
      author: author,
      expectedNext: expectedNext,
      advertisedMax: advertisedMax,
      retryAtMs: nowMs + backoffMs,
      probeCount: probeCount + 1,
    );
  }
}
