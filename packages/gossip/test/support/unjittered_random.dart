import 'dart:math';

/// A [Random] whose [nextDouble] always answers the jitter formula's exact
/// midpoint, so `applyJitter` (see `shared/domain/services/jitter.dart`)
/// returns its base [Duration] unchanged — the Dart mirror of gossip-kt's
/// `UnjitteredRandom`, but only for `nextDouble`: kt's also zeroes
/// `nextBits`, making its `nextInt` constant too, where this one still
/// delegates `nextInt`/`nextBool` to a real, seeded [Random]. Needed
/// wherever a test asserts an exact scheduled duration, or an exact round
/// count, rather than a jittered range.
///
/// [nextInt] and [nextBool] delegate to a real, seeded (so reproducible)
/// [Random], for tests that also rely on those for tie-breaking (e.g.
/// gossip partner selection): which candidate wins the tiebreak doesn't
/// matter to those tests, only that the same one wins every run.
class UnjitteredRandom implements Random {
  final Random _inner = Random(7);

  @override
  double nextDouble() => 0.5;

  @override
  int nextInt(int max) => _inner.nextInt(max);

  @override
  bool nextBool() => _inner.nextBool();
}
