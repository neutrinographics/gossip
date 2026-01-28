/// Severity levels for log messages.
enum LogLevel {
  /// Very detailed internal state changes, payload sizes
  trace,

  /// Endpoint discovered/lost, connection requested, handshake messages
  debug,

  /// Advertising/discovery started/stopped, connection established, handshake completed
  info,

  /// Handshake timeout, unexpected message format, connection retry
  warning,

  /// Send failed, handshake failed, unexpected disconnection
  error,
}

/// Callback for receiving log messages from the transport.
typedef LogCallback =
    void Function(
      LogLevel level,
      String message, [
      Object? error,
      StackTrace? stackTrace,
    ]);
