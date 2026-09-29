import 'dart:math';

import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/sync/domain/aggregates/outstanding_pulls.dart';
import 'package:gossip/src/sync/domain/entities/pull_request.dart';
import 'package:gossip/src/sync/domain/services/outstanding_pull_tracker.dart';
import 'package:gossip/src/sync/domain/value_objects/answered_pull.dart';

/// TRANSITIONAL: how a response is tied to a request by its content alone,
/// applied only to a peer that has never named one — a peer on a pin that
/// predates request identity, which answers as it always did. It lives in one
/// file, reached by one call, so that when the fleet has moved it is deleted
/// together with its pins and that call, and nothing else changes; the
/// deletion criterion lives on the backlog item.
///
/// Content is evidence, not identity, so everything here is a judgement that
/// can be wrong, and the cases it has to survive are a mesh's: every peer
/// writes, so a peer's push of its own newest entry is the commonest response
/// there is, and it begins exactly where we hold that author —
/// indistinguishable by content from part of an answer.
abstract final class LegacyCorrelation {
  /// Whether a response carrying [firstByAuthor] — the first sequence it
  /// holds per author — under [floor] can be [request]'s answer.
  ///
  /// An answer begins exactly where the request asked, for every author it
  /// speaks about: one past what we held, or one past what the sender reports
  /// having compacted away and so can never supply — the same position the
  /// merge path judges contiguity from once that floor is adopted. Anything
  /// starting higher is a response to something else, whose hole is no
  /// evidence about the request. A sender whose floor is at or past what it
  /// sent contradicts itself but withholds nothing, so it answers too.
  ///
  /// And an answer speaks to the request: it accounts for an author the
  /// request was for ([addressed]), or carries one the page before it was
  /// carrying — a drain's next page may continue an author rather than open
  /// one still owed, and which it does is the responder's choice, recognised
  /// rather than required. A response that begins in the right place for
  /// every author it carries yet speaks to none of them is a push that
  /// happens to be contiguous, and answers nothing.
  ///
  /// A response carrying no author is an answer: a peer replying with nothing
  /// left to give has answered what it was asked.
  static bool answers(
    PullRequest request,
    Map<NodeId, int> firstByAuthor,
    VersionVector floor,
  ) {
    for (final carried in firstByAuthor.entries) {
      final asked = max(request.since[carried.key], floor[carried.key]) + 1;
      final beginsWhereAsked =
          carried.value == asked || floor[carried.key] >= carried.value;
      if (!beginsWhereAsked) return false;
    }
    if (firstByAuthor.isEmpty) return true;
    if (addressed(request, firstByAuthor, floor).isNotEmpty) return true;
    return request.carrying.any(firstByAuthor.containsKey);
  }

  /// The authors [request] was for that a response carrying [firstByAuthor]
  /// under [floor] accounts for: carried, or floored past what we hold — the
  /// sender saying that author's missing range is gone.
  static Set<NodeId> addressed(
    PullRequest request,
    Map<NodeId, int> firstByAuthor,
    VersionVector floor,
  ) => request.wanted
      .where(
        (author) =>
            firstByAuthor.containsKey(author) ||
            floor[author] > request.since[author],
      )
      .toSet();

  /// The oldest request to [sender] for this stream that a response carrying
  /// [firstByAuthor] under [floor] can answer, answered as far as it can be:
  /// retired when every author it was for is accounted for, when the response
  /// carries nothing, or when more is coming ([hasMore]), since the rest of
  /// it is handed to the continuation that follows and must not stand twice;
  /// narrowed to the authors still unaccounted for otherwise, because a
  /// response that speaks to some of what a request was for answers that much
  /// and no more. Nothing is answered, and the set stands, when no
  /// outstanding request can be its answer.
  ///
  /// Oldest first because a response can only be the answer to something
  /// already asked, and the older request is the one whose answer is overdue.
  ///
  /// A partial answer narrows the request to what is still owed only where
  /// the peer's dialect can mark a page partial ([marksPartialPages]): the
  /// rest is then still this request's to receive. Where it cannot (v1), the
  /// response is the whole of what this request will get — the peer relies on
  /// later rounds for the rest — so the request is retired and the next
  /// round's digest asks for the remainder; holding it open would suppress
  /// that pull until the deadline for a remainder nobody will send.
  ///
  /// The round trip is sampled from a request this response accounts for in
  /// full — including a page that says more is coming, because a request is
  /// measured to its own answer and the rest of the drain is asked for by a
  /// continuation with its own clock; a partial answer that leaves the
  /// request open measures nothing yet.
  ///
  /// One step rather than a read and a later write, because which request a
  /// response answers and what becomes of that request are the same decision.
  static ({OutstandingPulls state, AnsweredPull? answered}) answer(
    OutstandingPulls pulls, {
    required NodeId sender,
    required ChannelId channel,
    required StreamId stream,
    required Map<NodeId, int> firstByAuthor,
    required VersionVector floor,
    required bool hasMore,
    required int nowMs,
    bool marksPartialPages = true,
  }) {
    final answered = _candidate(
      pulls,
      sender: sender,
      channel: channel,
      stream: stream,
      firstByAuthor: firstByAuthor,
      floor: floor,
      nowMs: nowMs,
    );
    if (answered == null) return (state: pulls, answered: null);

    final remaining = firstByAuthor.isEmpty
        ? const <NodeId>{}
        : answered.wanted.difference(addressed(answered, firstByAuthor, floor));
    final elapsedMs = nowMs - answered.issuedAtMs;
    final whole = remaining.isEmpty || !marksPartialPages;
    final requests = whole || hasMore
        ? ({...pulls.requests}..remove(answered.id))
        : ({...pulls.requests}..[answered.id] = answered.narrowedTo(remaining));
    final settled = pulls.copyWith(requests: requests);
    return (
      state: whole
          ? OutstandingPullTracker.sampled(settled, elapsedMs)
          : settled,
      answered: AnsweredPull(elapsedMs: elapsedMs, remaining: remaining),
    );
  }

  /// The request this response is taken to answer, or null when none can be.
  ///
  /// Only requests still within the deadline are candidates: content is
  /// evidence, and a request long past its deadline is the one a push is
  /// likeliest to resemble by accident — a stall charged to a healthy peer. (A
  /// request answered by reference is honoured whatever its age; an id is
  /// proof.) Oldest first by issue reading; two issued in one instant fall
  /// back to issue order, which [OutstandingPulls.requests] keeps, so the
  /// ordering below is by (reading, position) and never by reading alone.
  static PullRequest? _candidate(
    OutstandingPulls pulls, {
    required NodeId sender,
    required ChannelId channel,
    required StreamId stream,
    required Map<NodeId, int> firstByAuthor,
    required VersionVector floor,
    required int nowMs,
  }) {
    final timeoutMs = OutstandingPullTracker.effectiveTimeout(
      pulls,
    ).inMilliseconds;
    final candidates = <(int, PullRequest)>[];
    for (final request in pulls.requests.values) {
      if (request.peer == sender &&
          request.channelId == channel &&
          request.streamId == stream &&
          nowMs - request.issuedAtMs < timeoutMs) {
        candidates.add((candidates.length, request));
      }
    }
    candidates.sort((a, b) {
      final byReading = a.$2.issuedAtMs.compareTo(b.$2.issuedAtMs);
      return byReading != 0 ? byReading : a.$1.compareTo(b.$1);
    });
    for (final (_, request) in candidates) {
      if (answers(request, firstByAuthor, floor)) return request;
    }
    return null;
  }
}
