import 'dart:collection';

import 'log_format.dart';

/// A single log entry with timestamp, category, and message.
class LogEntry {
  final DateTime timestamp;
  final String category;
  final String message;

  const LogEntry({
    required this.timestamp,
    required this.category,
    required this.message,
  });

  /// Formats the entry as a log line: [HH:mm:ss.SSS][CATEGORY] message
  String format() {
    return LogFormat.logLine(category, message, time: timestamp);
  }
}

/// In-memory ring buffer for storing log entries.
///
/// Stores up to [maxEntries] log entries, evicting the oldest when full.
/// Provides export functionality for debugging.
class LogStorage {
  final int maxEntries;
  final Queue<LogEntry> _entries = Queue<LogEntry>();

  LogStorage({this.maxEntries = 10000});

  /// Appends a log entry to storage.
  ///
  /// If the buffer is full, the oldest entry is evicted.
  void append(String category, String message) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      category: category,
      message: message,
    );

    _entries.addLast(entry);

    while (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
  }

  /// Returns all stored entries (read-only).
  List<LogEntry> get entries => List.unmodifiable(_entries.toList());

  /// Returns the number of stored entries.
  int get entryCount => _entries.length;

  /// Clears all stored entries.
  void clear() {
    _entries.clear();
  }

  /// Exports all entries as formatted text.
  ///
  /// Each entry is on its own line in chronological order.
  String export() {
    if (_entries.isEmpty) return '';
    return _entries.map((e) => e.format()).join('\n');
  }

  /// Exports entries since the given timestamp.
  ///
  /// Useful for exporting only recent logs.
  String exportSince(DateTime since) {
    final filtered = _entries.where((e) => e.timestamp.isAfter(since));
    if (filtered.isEmpty) return '';
    return filtered.map((e) => e.format()).join('\n');
  }
}
