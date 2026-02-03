import 'package:gossip/src/domain/value_objects/rtt_estimate.dart';

/// Domain service for tracking Round-Trip Time measurements.
///
/// [RttTracker] manages RTT samples and maintains a smoothed estimate
/// using the EWMA algorithm. It provides adaptive timeout suggestions
/// based on observed network latency.
///
/// ## Usage
///
/// ```dart
/// final tracker = RttTracker();
///
/// // Record RTT samples from ping/ack pairs
/// tracker.recordSample(Duration(milliseconds: 150));
/// tracker.recordSample(Duration(milliseconds: 180));
///
/// // Get adaptive timeout for SWIM probes
/// final timeout = tracker.suggestedTimeout();
/// ```
///
/// ## Bounds
///
/// RTT samples are clamped to prevent extreme values:
/// - Minimum: 50ms (network physics floor)
/// - Maximum: 30 seconds (reasonable upper limit)
///
/// ## Thread Safety
///
/// This class is NOT thread-safe. It should only be accessed from a
/// single isolate, consistent with the library's single-isolate design
/// (see ADR-001).
class RttTracker {
  /// Minimum RTT sample value (network physics floor).
  static const Duration _minSample = Duration(milliseconds: 50);

  /// Maximum RTT sample value (reasonable upper limit).
  static const Duration _maxSample = Duration(seconds: 30);

  /// The initial estimate to use when reset.
  final RttEstimate _initialEstimate;

  /// Current RTT estimate.
  RttEstimate _estimate;

  /// Number of samples recorded.
  int _sampleCount = 0;

  /// Creates an [RttTracker] with the given initial estimate.
  ///
  /// If no initial estimate is provided, uses conservative defaults
  /// (1 second RTT, 500ms variance).
  RttTracker({RttEstimate? initialEstimate})
    : _initialEstimate = initialEstimate ?? RttEstimate.initial(),
      _estimate = initialEstimate ?? RttEstimate.initial();

  /// Current RTT estimate.
  RttEstimate get estimate => _estimate;

  /// Current smoothed RTT.
  Duration get smoothedRtt => _estimate.smoothedRtt;

  /// Current RTT variance.
  Duration get rttVariance => _estimate.rttVariance;

  /// Number of samples recorded since creation or last reset.
  int get sampleCount => _sampleCount;

  /// Whether any samples have been recorded.
  bool get hasReceivedSamples => _sampleCount > 0;

  /// Records an RTT sample and updates the estimate.
  ///
  /// The sample is clamped to [_minSample, _maxSample] to prevent
  /// extreme values from destabilizing the estimate.
  ///
  /// Negative samples are ignored (likely measurement errors).
  void recordSample(Duration sample) {
    if (sample.isNegative) return;

    // Clamp sample to valid range
    final clampedSample = _clampSample(sample);

    // Update estimate
    final isFirst = _sampleCount == 0;
    _estimate = _estimate.update(clampedSample, isFirstSample: isFirst);
    _sampleCount++;
  }

  /// Clamps sample to valid range.
  Duration _clampSample(Duration sample) {
    if (sample < _minSample) return _minSample;
    if (sample > _maxSample) return _maxSample;
    return sample;
  }

  /// Returns the suggested timeout based on current RTT estimate.
  ///
  /// Delegates to [RttEstimate.suggestedTimeout] with optional bounds.
  Duration suggestedTimeout({Duration? minTimeout, Duration? maxTimeout}) {
    if (minTimeout != null && maxTimeout != null) {
      return _estimate.suggestedTimeout(
        minTimeout: minTimeout,
        maxTimeout: maxTimeout,
      );
    } else if (minTimeout != null) {
      return _estimate.suggestedTimeout(minTimeout: minTimeout);
    } else if (maxTimeout != null) {
      return _estimate.suggestedTimeout(maxTimeout: maxTimeout);
    }
    return _estimate.suggestedTimeout();
  }

  /// Resets the tracker to its initial state.
  ///
  /// Clears all samples and restores the initial estimate.
  void reset() {
    _estimate = _initialEstimate;
    _sampleCount = 0;
  }
}
