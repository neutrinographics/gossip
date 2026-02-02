/// Shared log formatting utilities.
///
/// Provides consistent formatting for timestamps, IDs, and byte sizes
/// across all logging in the application.
abstract class LogFormat {
  /// Formats a DateTime as a timestamp string: HH:mm:ss.SSS
  static String timestamp(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}.'
        '${time.millisecond.toString().padLeft(3, '0')}';
  }

  /// Formats a DateTime as a short time string: HH:mm:ss (no milliseconds)
  static String shortTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
  }

  /// Truncates an ID to a short prefix for display.
  static String shortId(String id, {int length = 8}) {
    return id.length > length ? id.substring(0, length) : id;
  }

  /// Formats bytes as a human-readable string (B, KB, MB).
  static String bytes(int byteCount) {
    if (byteCount < 1024) return '$byteCount B';
    if (byteCount < 1024 * 1024) {
      return '${(byteCount / 1024).toStringAsFixed(1)} KB';
    }
    return '${(byteCount / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Formats a log line with timestamp, category, and message.
  static String logLine(String category, String message, {DateTime? time}) {
    final ts = timestamp(time ?? DateTime.now());
    return '[$ts][$category] $message';
  }
}
