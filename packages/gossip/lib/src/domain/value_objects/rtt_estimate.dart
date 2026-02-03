/// Immutable value object representing a Round-Trip Time estimate.
///
/// [RttEstimate] tracks smoothed RTT and variance using the EWMA algorithm
/// from RFC 6298 (TCP Retransmission Timer). This provides a stable estimate
/// of network latency that adapts to changing conditions while filtering
/// out noise.
///
/// ## EWMA Algorithm
///
/// On each RTT sample:
/// - **Smoothed RTT**: `SRTT = (1 - alpha) * SRTT + alpha * sample`
/// - **Variance**: `RTTVAR = (1 - beta) * RTTVAR + beta * |sample - SRTT|`
///
/// Where alpha=0.125 (1/8) and beta=0.25 (1/4) as recommended by RFC 6298.
///
/// ## Timeout Calculation
///
/// The suggested timeout is: `SRTT + 4 * RTTVAR`
///
/// This covers approximately 99.99% of RTT samples assuming normal
/// distribution, preventing premature timeouts while still detecting
/// actual failures.
///
/// ## Usage
///
/// ```dart
/// var estimate = RttEstimate.initial();
///
/// // Record first sample
/// estimate = estimate.update(Duration(milliseconds: 150), isFirstSample: true);
///
/// // Record subsequent samples
/// estimate = estimate.update(Duration(milliseconds: 180));
/// estimate = estimate.update(Duration(milliseconds: 160));
///
/// // Get adaptive timeout
/// final timeout = estimate.suggestedTimeout; // ~200-300ms depending on variance
/// ```
///
/// Value objects are immutable and compared by value equality.
class RttEstimate {
  /// Smoothed RTT using exponential weighted moving average.
  final Duration smoothedRtt;

  /// RTT variance (mean deviation) for timeout calculation.
  final Duration rttVariance;

  /// EWMA smoothing factor for RTT (1/8 per RFC 6298).
  static const double _alpha = 0.125;

  /// EWMA smoothing factor for variance (1/4 per RFC 6298).
  static const double _beta = 0.25;

  /// Default minimum timeout (network physics floor).
  static const Duration _defaultMinTimeout = Duration(milliseconds: 200);

  /// Default maximum timeout (reasonable upper limit).
  static const Duration _defaultMaxTimeout = Duration(seconds: 10);

  /// Creates an [RttEstimate] with the given smoothed RTT and variance.
  ///
  /// Throws [ArgumentError] if either value is negative.
  RttEstimate({required this.smoothedRtt, required this.rttVariance}) {
    if (smoothedRtt.isNegative) {
      throw ArgumentError.value(
        smoothedRtt,
        'smoothedRtt',
        'Smoothed RTT cannot be negative',
      );
    }
    if (rttVariance.isNegative) {
      throw ArgumentError.value(
        rttVariance,
        'rttVariance',
        'RTT variance cannot be negative',
      );
    }
  }

  /// Creates an initial estimate with conservative default values.
  ///
  /// Default smoothed RTT is 1 second (safe for both WiFi and BLE).
  /// Default variance is 500ms (high uncertainty).
  factory RttEstimate.initial() {
    return RttEstimate(
      smoothedRtt: const Duration(seconds: 1),
      rttVariance: const Duration(milliseconds: 500),
    );
  }

  /// Returns a new estimate updated with the given RTT sample.
  ///
  /// If [isFirstSample] is true, sets the smoothed RTT directly to the
  /// sample value (per RFC 6298 initialization). Otherwise applies EWMA
  /// smoothing.
  ///
  /// The variance is always updated using the EWMA formula.
  RttEstimate update(Duration sample, {bool isFirstSample = false}) {
    final sampleMs = sample.inMicroseconds / 1000.0;

    if (isFirstSample) {
      // Per RFC 6298: Initialize SRTT to first sample, RTTVAR to sample/2
      return RttEstimate(
        smoothedRtt: sample,
        rttVariance: Duration(
          microseconds: (sample.inMicroseconds / 2).round(),
        ),
      );
    }

    final oldSrttMs = smoothedRtt.inMicroseconds / 1000.0;
    final oldVarMs = rttVariance.inMicroseconds / 1000.0;

    // EWMA update for smoothed RTT
    final newSrttMs = (1 - _alpha) * oldSrttMs + _alpha * sampleMs;

    // EWMA update for variance
    final deviation = (sampleMs - oldSrttMs).abs();
    final newVarMs = (1 - _beta) * oldVarMs + _beta * deviation;

    return RttEstimate(
      smoothedRtt: Duration(microseconds: (newSrttMs * 1000).round()),
      rttVariance: Duration(microseconds: (newVarMs * 1000).round()),
    );
  }

  /// Returns the suggested timeout based on current RTT estimate.
  ///
  /// Formula: `timeout = smoothedRtt + 4 * rttVariance`
  ///
  /// The result is clamped between [minTimeout] and [maxTimeout].
  /// Defaults: min=200ms, max=10s.
  Duration suggestedTimeout({
    Duration minTimeout = _defaultMinTimeout,
    Duration maxTimeout = _defaultMaxTimeout,
  }) {
    final timeoutMicros =
        smoothedRtt.inMicroseconds + 4 * rttVariance.inMicroseconds;
    final timeout = Duration(microseconds: timeoutMicros);

    if (timeout < minTimeout) return minTimeout;
    if (timeout > maxTimeout) return maxTimeout;
    return timeout;
  }

  @override
  bool operator ==(Object other) =>
      other is RttEstimate &&
      other.smoothedRtt == smoothedRtt &&
      other.rttVariance == rttVariance;

  @override
  int get hashCode => Object.hash(smoothedRtt, rttVariance);

  @override
  String toString() =>
      'RttEstimate(smoothedRtt: ${smoothedRtt.inMilliseconds}ms, '
      'variance: ${rttVariance.inMilliseconds}ms)';
}
