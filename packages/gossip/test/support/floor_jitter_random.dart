import 'dart:math';

/// A [Random] whose [nextDouble] always answers 0, so `applyJitter` (see
/// `shared/domain/services/jitter.dart`) returns the jitter band's floor —
/// the shortest wait a round can sleep. The floor-draw sibling of
/// [UnjitteredRandom](unjittered_random.dart), and the Dart mirror of
/// gossip-kt's `FloorJitterRandom`. Needed wherever a test pins what a round
/// does after the shortest wait the jitter can draw.
///
/// [nextInt] and [nextBool] delegate to a real, seeded (so reproducible)
/// [Random], for tests that also rely on those for tie-breaking.
class FloorJitterRandom implements Random {
  final Random _inner = Random(7);

  @override
  double nextDouble() => 0.0;

  @override
  int nextInt(int max) => _inner.nextInt(max);

  @override
  bool nextBool() => _inner.nextBool();
}
