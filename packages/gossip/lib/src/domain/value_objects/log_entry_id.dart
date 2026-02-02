import 'node_id.dart';

/// Unique identifier for a log entry within a stream.
///
/// A [LogEntryId] combines an author node ID with a sequence number to
/// create a globally unique identifier for each entry. The author identifies
/// which peer created the entry, and the sequence number is monotonically
/// increasing for that author.
///
/// LogEntryIds serve multiple purposes:
/// - **Deduplication**: Prevent processing the same entry multiple times
/// - **Causality tracking**: Establish happened-before relationships via HLCs
/// - **Stable references**: Uniquely identify entries across peers and time
///
/// ## Invariants
/// - sequence must be positive (> 0) - sequences start at 1
///
/// Value objects are immutable and compared by value equality.
class LogEntryId {
  /// The node that authored this entry.
  final NodeId author;

  /// The monotonically increasing sequence number for this author.
  final int sequence;

  /// Creates a [LogEntryId] from an author and sequence number.
  ///
  /// Throws [ArgumentError] if invariants are violated.
  LogEntryId(this.author, int sequence) : sequence = sequence {
    if (sequence <= 0) {
      throw ArgumentError.value(
        sequence,
        'sequence',
        'Sequence number must be positive (sequences start at 1)',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is LogEntryId &&
      other.author == author &&
      other.sequence == sequence;

  @override
  int get hashCode => Object.hash(author, sequence);

  @override
  String toString() => 'LogEntryId(${author.value}:$sequence)';
}
