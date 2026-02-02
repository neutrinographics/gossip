/// Log levels for observability.
enum LogLevel { trace, debug, info, warning, error }

/// Callback for logging.
typedef LogCallback =
    void Function(
      LogLevel level,
      String message, [
      Object? error,
      StackTrace? stack,
    ]);
