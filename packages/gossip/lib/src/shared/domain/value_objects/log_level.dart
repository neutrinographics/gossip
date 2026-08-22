/// Severity levels for log messages.
///
/// Used by [LogCallback] to allow filtering by importance.
enum LogLevel {
  /// Very detailed internal state changes, message sizes, version vectors.
  ///
  /// Use for high-frequency events like individual message sends/receives.
  trace,

  /// Protocol flow details: digest exchange, delta computation.
  ///
  /// Use for understanding sync behavior during debugging.
  debug,

  /// Important state changes: sync completed, peer connected.
  ///
  /// Use for operational monitoring in production.
  info,

  /// Recoverable issues: timeout, retry, unexpected message format.
  ///
  /// Use for alerting on potential problems.
  warning,

  /// Failures: send failed, protocol violation, data corruption.
  ///
  /// Use for error tracking and alerting.
  error,
}

/// Callback for receiving log messages.
///
/// Used by [Coordinator] and transport implementations to provide
/// observability into protocol behavior.
///
/// Example:
/// ```dart
/// final coordinator = await Coordinator.create(
///   // ...
///   onLog: (level, message, [error, stackTrace]) {
///     if (level.index >= LogLevel.info.index) {
///       print('[$level] $message');
///     }
///   },
/// );
/// ```
typedef LogCallback =
    void Function(
      LogLevel level,
      String message, [
      Object? error,
      StackTrace? stackTrace,
    ]);
