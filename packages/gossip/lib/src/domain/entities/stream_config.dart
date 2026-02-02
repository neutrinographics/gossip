import 'package:meta/meta.dart';

/// Configuration for a stream's out-of-order entry buffering.
///
/// [StreamConfig] defines limits for buffering entries that arrive out of
/// sequence. When entries arrive with gaps in their sequence numbers, they
/// are temporarily buffered until missing entries arrive.
///
/// Buffer limits prevent memory exhaustion from:
/// - **Malicious peers**: Sending many entries with large sequence gaps
/// - **Buggy peers**: Generating invalid sequence numbers
/// - **Fake author attacks**: Creating many fake author identities
///
/// Two-level limiting:
/// - Per-author limit: Caps buffered entries from any single author
/// - Total limit: Caps buffered entries across all authors
///
/// Entities are compared by value equality (immutable value semantics).
@immutable
class StreamConfig {
  /// Maximum buffered entries per author (default: 1000).
  ///
  /// Limits how many out-of-order entries from a single author can be
  /// buffered before older entries are discarded.
  final int maxBufferSizePerAuthor;

  /// Maximum total buffered entries across all authors (default: 10000).
  ///
  /// Prevents memory exhaustion from attacks using many fake authors.
  /// Once this limit is reached, entries from authors with the most
  /// buffered entries are evicted first.
  final int maxTotalBufferEntries;

  /// Creates a [StreamConfig] with the given buffer limits.
  const StreamConfig({
    this.maxBufferSizePerAuthor = 1000,
    this.maxTotalBufferEntries = 10000,
  });

  /// Default configuration with standard buffer limits.
  static const defaults = StreamConfig();

  @override
  bool operator ==(Object other) =>
      other is StreamConfig &&
      other.maxBufferSizePerAuthor == maxBufferSizePerAuthor &&
      other.maxTotalBufferEntries == maxTotalBufferEntries;

  @override
  int get hashCode =>
      Object.hash(maxBufferSizePerAuthor, maxTotalBufferEntries);

  @override
  String toString() =>
      'StreamConfig(maxBufferPerAuthor: $maxBufferSizePerAuthor, '
      'maxTotal: $maxTotalBufferEntries)';
}
