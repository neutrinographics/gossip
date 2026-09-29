import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/rtt_estimate.dart';
import 'package:gossip/src/sync/domain/entities/pull_request.dart';
import 'package:gossip/src/sync/domain/value_objects/correlation.dart';
import 'package:gossip/src/sync/domain/value_objects/request_id.dart';

/// Every pull of ours awaiting an answer, by identity, with what is needed to
/// judge an arriving response: how each peer ties responses to requests
/// ([peers]; absent means [Correlation.unknown]), the delta round-trip
/// evidence the staleness deadline is derived from ([rtt], [sampleCount]),
/// and the sequence the next id is minted from ([nextSequence]).
///
/// Its invariant is about identity: no two requests share an id. "At most one
/// pull planned at a time per peer and stream" is a policy asked of the set,
/// not the set's key, which is what lets a pull and the continuation of the
/// page that answered it both be in flight and both be answered.
///
/// One value rather than four, because judging a response reads all of it at
/// once: a reader that caught them mid-move could measure a request against a
/// deadline none was ever issued under, mint an id a live request already
/// holds, or consult content for a peer that has since named a request.
/// Retiring a request moves the evidence for the same reason — the request it
/// retires is the sample it contributes.
///
/// [requests] keeps issue order: it is only ever built by adding to and
/// removing from the previous map, which preserves the order of what remains,
/// and the transitional content rule's oldest-first tie-break among requests
/// issued in one instant relies on that (pinned). The declared type is the
/// plain map interface; the ordering is a property of how this value is made,
/// not of the type, so it is stated here rather than assumed silently.
///
/// An immutable value, the whole of the engine's pull state, held in one
/// field: single-isolate execution (ADR-001) is what lets a plain field stand
/// where the Kotlin twin holds a guarded cell.
class OutstandingPulls {
  /// Creates a pull set.
  ///
  /// Throws [ArgumentError] when the evidence disagrees with itself: an
  /// estimate is held exactly when a sample has been taken, and no transition
  /// ever un-measures a transport.
  OutstandingPulls({
    required this.requests,
    required this.peers,
    required this.rtt,
    required this.sampleCount,
    required this.nextSequence,
  }) {
    if ((rtt == null) != (sampleCount == 0)) {
      throw ArgumentError.value(
        sampleCount,
        'sampleCount',
        'an RTT estimate is held exactly when a sample has been taken',
      );
    }
  }

  /// A node with nothing in flight, nothing measured and nothing learned.
  static final OutstandingPulls initial = OutstandingPulls(
    requests: const {},
    peers: const {},
    rtt: null,
    sampleCount: 0,
    nextSequence: 0,
  );

  /// The requests in flight, by identity, in issue order.
  final Map<RequestId, PullRequest> requests;

  /// How each peer we have heard from ties its responses to our requests.
  final Map<NodeId, Correlation> peers;

  /// The delta round-trip estimate, or null while nothing has been measured.
  final RttEstimate? rtt;

  /// How many round trips stand behind [rtt] — the first sample initializes
  /// the estimate rather than smoothing into it (RFC 6298), so what a
  /// recording does depends on how many came before.
  final int sampleCount;

  /// The sequence the next id is minted from. It survives every clear, so an
  /// id is never minted twice within one run.
  final int nextSequence;

  /// Whether the deadline rests on measurement or only on its cold default.
  bool get hasMeasuredRoundTrip => sampleCount > 0;

  /// This value with the given parts replaced.
  ///
  /// [rtt] and [sampleCount] move together or not at all, and nothing ever
  /// un-measures a transport, so omitting them keeps what was measured.
  OutstandingPulls copyWith({
    Map<RequestId, PullRequest>? requests,
    Map<NodeId, Correlation>? peers,
    RttEstimate? rtt,
    int? sampleCount,
    int? nextSequence,
  }) => OutstandingPulls(
    requests: requests ?? this.requests,
    peers: peers ?? this.peers,
    rtt: rtt ?? this.rtt,
    sampleCount: sampleCount ?? this.sampleCount,
    nextSequence: nextSequence ?? this.nextSequence,
  );

  @override
  String toString() =>
      'OutstandingPulls(requests: ${requests.length}, peers: ${peers.length}, '
      'samples: $sampleCount, nextSequence: $nextSequence)';
}
