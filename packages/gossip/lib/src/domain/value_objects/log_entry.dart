import 'dart:typed_data';
import 'hlc.dart';
import 'log_entry_id.dart';
import 'node_id.dart';

/// Atomic unit of synchronization in a stream.
///
/// A [LogEntry] represents a single immutable event authored by a peer.
/// Entries form an ordered log within each stream and are the fundamental
/// unit that the gossip protocol synchronizes across peers.
///
/// Each entry contains:
/// - **Identity**: Author and sequence number (unique per author)
/// - **Causality**: Hybrid logical clock timestamp
/// - **Content**: Opaque payload bytes (application-defined semantics)
///
/// Entries are payload-agnostic; the library syncs opaque bytes while
/// applications define their own serialization and semantics.
///
/// ## Ordering
/// Entries implement [Comparable] for deterministic ordering:
/// 1. Primary: HLC timestamp (physicalMs, then logical)
/// 2. Secondary: Author NodeId (for entries with identical HLCs)
/// 3. Tertiary: Sequence number (for same author, same HLC)
///
/// This ensures all nodes sort entries identically even when concurrent
/// writes produce identical HLCs.
///
/// ## Invariants
/// - sequence must be positive (> 0) - sequences start at 1
///
/// Value objects are immutable and compared by identity (author + sequence).
class LogEntry implements Comparable<LogEntry> {
  /// The peer that created this entry.
  final NodeId author;

  /// Monotonically increasing sequence number for this author.
  final int sequence;

  /// Hybrid logical clock timestamp for causality tracking.
  final Hlc timestamp;

  /// Opaque application-defined payload bytes.
  final Uint8List payload;

  /// Creates a [LogEntry] with the given components.
  ///
  /// Throws [ArgumentError] if invariants are violated.
  LogEntry({
    required this.author,
    required this.sequence,
    required this.timestamp,
    required this.payload,
  }) {
    if (sequence <= 0) {
      throw ArgumentError.value(
        sequence,
        'sequence',
        'Sequence number must be positive (sequences start at 1)',
      );
    }
  }

  /// Returns the unique identifier for this entry.
  ///
  /// Combines [author] and [sequence] into a [LogEntryId] that uniquely
  /// identifies this entry across all peers and time.
  LogEntryId get id => LogEntryId(author, sequence);

  /// Estimated size in bytes for quota management and wire protocol sizing.
  ///
  /// This is an approximation based on the wire encoding format:
  /// - author: 36 bytes (UUID string as UTF-8)
  /// - sequence: 4 bytes (int32)
  /// - timestamp: 8 bytes (int64 combining physicalMs and logical)
  /// - payload: variable length
  /// - framing overhead: ~4 bytes (length prefixes)
  ///
  /// Total: 52 + payload.length bytes
  int get sizeBytes => 52 + payload.length;

  /// Compares entries for deterministic ordering.
  ///
  /// Comparison order:
  /// 1. HLC timestamp (primary - preserves causality)
  /// 2. Author NodeId (secondary - deterministic tiebreaker for identical HLCs)
  /// 3. Sequence number (tertiary - for same author with same HLC)
  ///
  /// This ensures all nodes produce identical sort orders for the same entries.
  @override
  int compareTo(LogEntry other) {
    // Primary: HLC timestamp
    final timestampCmp = timestamp.compareTo(other.timestamp);
    if (timestampCmp != 0) return timestampCmp;

    // Secondary: Author NodeId (deterministic tiebreaker)
    final authorCmp = author.value.compareTo(other.author.value);
    if (authorCmp != 0) return authorCmp;

    // Tertiary: Sequence number (same author, same HLC)
    return sequence.compareTo(other.sequence);
  }

  /// Entries are equal if they have the same author and sequence.
  ///
  /// Identity is defined by author + sequence (unique per author's log).
  /// Timestamp and payload are not considered for equality.
  @override
  bool operator ==(Object other) =>
      other is LogEntry && other.author == author && other.sequence == sequence;

  @override
  int get hashCode => Object.hash(author, sequence);

  @override
  String toString() => 'LogEntry(${author.value}:$sequence @$timestamp)';
}
