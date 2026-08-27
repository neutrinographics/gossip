import 'package:gossip/src/shared/domain/interfaces/time_port.dart';

/// Abstraction for current time to enable deterministic testing.
///
/// A read-only clock view over [TimePort] for consumers that must not
/// schedule.
///
/// Use cases:
/// - `HlcClock` uses this to generate hybrid logical clock timestamps
/// - Retention policies use this to calculate entry ages
///
/// ## Usage
/// ```dart
/// final timeSource = TimeSource(timePort);
/// final now = timeSource.nowMillis();
/// ```
class TimeSource {
  final TimePort _timePort;

  const TimeSource(this._timePort);

  /// Returns current time in milliseconds since epoch.
  ///
  /// Delegates to [TimePort.nowMs], which returns real wall-clock time
  /// in production or simulated time in tests.
  int nowMillis() => _timePort.nowMs;
}
