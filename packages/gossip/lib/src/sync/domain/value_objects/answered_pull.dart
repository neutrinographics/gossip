import 'package:gossip/src/shared/domain/value_objects/node_id.dart';

/// A pull a response answered, in whole or in part: how long since it was
/// issued, and the authors it was for that this response did not account for
/// — empty when it answered the whole of it, and what a continuation of it
/// still wants otherwise.
class AnsweredPull {
  /// Creates the settlement of one pull.
  const AnsweredPull({required this.elapsedMs, required this.remaining});

  /// The round trip, from that request's own issue reading to this response.
  final int elapsedMs;

  /// The authors the pull was for that this response left unaccounted for.
  final Set<NodeId> remaining;

  @override
  bool operator ==(Object other) =>
      other is AnsweredPull &&
      other.elapsedMs == elapsedMs &&
      other.remaining.length == remaining.length &&
      other.remaining.containsAll(remaining);

  @override
  int get hashCode => Object.hash(
    elapsedMs,
    remaining.fold<int>(0, (hash, author) => hash ^ author.hashCode),
  );

  @override
  String toString() =>
      'AnsweredPull(elapsedMs: $elapsedMs, remaining: ${remaining.length})';
}
