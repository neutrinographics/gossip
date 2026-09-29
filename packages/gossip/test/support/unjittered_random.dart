import 'dart:math';

/// A [Random] whose [nextDouble] always answers the jitter formula's exact
/// midpoint, so `applyJitter` (see `shared/domain/services/jitter.dart`)
/// returns its base [Duration] unchanged. The Dart mirror of gossip-kt's
/// `UnjitteredRandom` — needed wherever a test asserts an exact scheduled
/// duration, or an exact round count, rather than a jittered range.
///
/// [nextInt] and [nextBool] still delegate to a real (seeded, so
/// reproducible) [Random], for tests that also rely on those for
/// tie-breaking (e.g. gossip partner selection) and don't care about that
/// choice being fixed.
class UnjitteredRandom implements Random {
  final Random _inner = Random(7);

  @override
  double nextDouble() => 0.5;

  @override
  int nextInt(int max) => _inner.nextInt(max);

  @override
  bool nextBool() => _inner.nextBool();
}
