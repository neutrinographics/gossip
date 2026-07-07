import 'dart:math';

/// Returns [base] scaled by a uniform random factor in
/// `[1 - fraction, 1 + fraction]`.
///
/// Used to decorrelate self-scheduling timer loops across nodes. Without
/// jitter, nodes that compute their intervals from a shared signal (e.g. a
/// common BLE RTT) can phase-lock into correlated request/response bursts,
/// which in turn cause correlated ping timeouts and correlated false
/// suspicions. A ±20% spread is standard SWIM practice.
///
/// [fraction] must be in `[0, 1]`; `0` makes this a no-op (returns [base]).
Duration applyJitter(Duration base, Random random, {double fraction = 0.2}) {
  if (fraction <= 0) return base;
  final factor = (1 - fraction) + random.nextDouble() * (2 * fraction);
  return Duration(microseconds: (base.inMicroseconds * factor).round());
}
