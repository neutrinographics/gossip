import 'package:gossip/src/sync/domain/value_objects/answered_pull.dart';

/// What a peer has shown about how it ties its responses to our requests: by
/// naming the request it answers, or by content alone, or nothing yet.
///
/// A fact about a peer's protocol behaviour, and sync's to keep because it is
/// about *our* requests, not about the peer's liveness. Once a peer has named
/// a request, every response of its that names none is a push, and no content
/// is consulted again. Nothing here is persisted, so our own restart forgets
/// it and the peer's next named answer teaches it again; in between, that
/// peer's responses are judged by content once more.
enum Correlation {
  /// Nothing shown yet — how a peer absent from the record stands.
  unknown,

  /// Answers by content alone: a peer on a pin that predates request
  /// identity.
  legacy,

  /// Names the request it answers, which is proof and needs no content.
  byReference,
}

/// What a response settled: the pull it answered, if any, and the fact it
/// taught us about its sender, if that was new — a peer's way of answering is
/// worth reporting once, not on every response.
///
/// Here rather than in a file of its own because it exists only to carry a
/// [Correlation] out of the one transition that can learn one.
class Correlated {
  /// Creates the settlement of one response.
  const Correlated({required this.answered, required this.learned});

  /// The pull this response answered, or null when it was a push.
  final AnsweredPull? answered;

  /// The fact newly learned about the sender, or null when it was already
  /// known — or when nothing about the sender was at stake.
  final Correlation? learned;

  @override
  bool operator ==(Object other) =>
      other is Correlated &&
      other.answered == answered &&
      other.learned == learned;

  @override
  int get hashCode => Object.hash(answered, learned);

  @override
  String toString() => 'Correlated(answered: $answered, learned: $learned)';
}
