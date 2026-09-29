import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/sync/domain/value_objects/request_id.dart';

/// One request of ours, in flight: identified by [id], which the peer echoes,
/// so its answer arrives named rather than guessed at. It records the peer it
/// went to, the stream it asked about, the [since] it asked from, the authors
/// the peer's digest showed it ahead on ([wanted]), and when it was issued.
///
/// Identity, not subject: two requests to one peer for one stream — a pull
/// and the continuation of the page that answered it — are two entities, each
/// answered, released and measured on its own. This is what replaces keying
/// the bookkeeping by (peer, channel, stream).
///
/// A continuation is a request in its own right, with its own [since] (where
/// the page left us) and its own issue time, and it records nothing about the
/// page it follows: a peer answers a request, not a history.
///
/// [issuedAtMs] is a reading the caller took, which is what makes both the
/// staleness verdict and the round-trip sample reproducible from the value
/// alone.
///
/// Every attribute is fixed at issue but one: [wanted] is narrowed, by copy
/// ([narrowedTo]), when a peer that does not answer by reference accounts for
/// part of what the pull was for. That narrowing is the transitional content
/// rule's and goes when it goes; a request answered by reference is retired
/// whole.
///
/// [carrying] is the transitional rule's too: on a continuation, the authors
/// the page before it was carrying. A peer that answers by content pages a
/// drain as it likes, so its next page may continue an author already
/// accounted for rather than open one still owed; that page is recognised as
/// the drain going on by what it carries, without being required of it. Empty
/// on a planned pull, never read for a peer that answers by reference,
/// deleted with the rule.
class PullRequest {
  /// Creates a request of ours.
  ///
  /// Throws [ArgumentError] when it is for no author and carries none: a
  /// request that asks for nothing is not a request.
  PullRequest({
    required this.id,
    required this.peer,
    required this.channelId,
    required this.streamId,
    required this.since,
    required this.wanted,
    required this.issuedAtMs,
    this.carrying = const {},
  }) {
    if (wanted.isEmpty && carrying.isEmpty) {
      throw ArgumentError.value(
        wanted,
        'wanted',
        'a pull that is for no author and carries none is not a pull',
      );
    }
  }

  /// This request's identity, minted by us and echoed by the peer.
  final RequestId id;

  /// The peer it went to — the only sender whose echo of [id] is honoured.
  final NodeId peer;

  /// The channel it asked about.
  final ChannelId channelId;

  /// The stream it asked about.
  final StreamId streamId;

  /// What we held when we asked, per author.
  final VersionVector since;

  /// The authors the peer's digest showed it ahead on: what the pull is for.
  final Set<NodeId> wanted;

  /// The reading its issuer took as it left.
  final int issuedAtMs;

  /// On a continuation, the authors the page before it was carrying.
  final Set<NodeId> carrying;

  /// This request with [stillWanted] as what it is still for — the
  /// transitional content rule's narrowing, when a response accounted for
  /// part of what the pull asked about.
  PullRequest narrowedTo(Set<NodeId> stillWanted) => PullRequest(
    id: id,
    peer: peer,
    channelId: channelId,
    streamId: streamId,
    since: since,
    wanted: stillWanted,
    issuedAtMs: issuedAtMs,
    carrying: carrying,
  );

  @override
  String toString() =>
      'PullRequest(${id.value} -> ${peer.value}, ${channelId.value}/'
      '${streamId.value}, wanted: ${wanted.length}, at: $issuedAtMs)';
}
