import 'dart:math' as math;

/// Pure quiescence pacing state machine (two-tier scheduling, WIRE4-1/2/4).
///
/// Owned by a protocol loop: the loop reports [quietRound] when a round
/// carried no news and [news] the moment anything happens; [apply]
/// stretches the loop's latency-derived base interval toward [ceiling]
/// while quiet. No clocks, timers, or I/O — the protocol layer owns those.
class QuiescencePacer {
  QuiescencePacer({required this.ceiling, this.growth = 1.5});

  /// The slowest the paced interval may get: callers pass their scheduling
  /// ceiling; the library pins 30 s and exposes no knob.
  final Duration ceiling;

  /// Multiplicative growth per quiet round (Trickle-style doubling core).
  final double growth;

  /// Hard cap keeps eternal idleness from growing the double unboundedly;
  /// [apply]'s ceiling clamp is what callers observe.
  static const double _maxMultiplier = 1048576; // 1 << 20

  double _multiplier = 1;

  /// Anything happened: snap back to the active cadence.
  void news() => _multiplier = 1;

  /// A round completed with nothing to say: rest a little longer.
  void quietRound() =>
      _multiplier = math.min(_multiplier * growth, _maxMultiplier);

  /// The paced interval for the loop's current latency-derived [base].
  Duration apply(Duration base) {
    final scaled = Duration(
      microseconds: (base.inMicroseconds * _multiplier).round(),
    );
    return scaled > ceiling ? ceiling : scaled;
  }
}
