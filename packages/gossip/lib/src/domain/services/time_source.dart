import '../../infrastructure/ports/time_port.dart';

/// Abstraction for current time to enable deterministic testing.
///
/// [TimeSource] decouples the domain from system time, allowing tests to
/// control time progression. It acts as an anti-corruption layer that
/// delegates to [TimePort], ensuring domain code doesn't depend directly
/// on infrastructure.
///
/// Use cases:
/// - [HlcClock] uses this to generate hybrid logical clock timestamps
/// - Retention policies use this to calculate entry ages
///
/// ## Usage
/// ```dart
/// final timeSource = TimeSource(timerPort);
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
