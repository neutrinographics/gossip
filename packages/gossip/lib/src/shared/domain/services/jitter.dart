import 'dart:math';

/// The spread [applyJitter] and [jitterFloor] share, so a floor is always the
/// jitter's own.
const double defaultJitterFraction = 0.2;

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
Duration applyJitter(
  Duration base,
  Random random, {
  double fraction = defaultJitterFraction,
}) {
  if (fraction <= 0) return base;
  final factor = (1 - fraction) + random.nextDouble() * (2 * fraction);
  return Duration(microseconds: (base.inMicroseconds * factor).round());
}

/// The earliest a wait jittered on [base] can end — what a window compared
/// against such a wait must not exceed. Rounded as [applyJitter] rounds, so a
/// zero draw lands exactly here, and a [fraction] of zero or less is [base],
/// as it is for [applyJitter].
Duration jitterFloor(Duration base, {double fraction = defaultJitterFraction}) {
  if (fraction <= 0) return base;
  return Duration(microseconds: (base.inMicroseconds * (1 - fraction)).round());
}
