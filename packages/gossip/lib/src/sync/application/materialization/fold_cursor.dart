import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';

/// Position of the last-folded entry in a stream's fold order.
///
/// Entries are folded in the full [LogEntry.compareTo] total order —
/// timestamp, then author, then sequence. A timestamp alone cannot say
/// whether an entry that TIES the cursor's timestamp was already folded
/// (HLC ties across authors are legal), so the cursor carries the full
/// position.
///
/// Serialized via [toString] into the opaque cursor string materializers
/// persist. [tryParse] also accepts the legacy timestamp-only format
/// (a bare `Hlc(...)` string) from cursors persisted before the author and
/// sequence were added; legacy cursors keep their old strictly-greater
/// semantics for timestamp ties.
class FoldCursor {
  final Hlc timestamp;

  /// Null for legacy timestamp-only cursors.
  final NodeId? author;

  /// Null for legacy timestamp-only cursors.
  final int? sequence;

  const FoldCursor(this.timestamp, {this.author, this.sequence})
    : assert(
        (author == null) == (sequence == null),
        'author and sequence must be provided together — a mixed cursor '
        'makes isBefore throw on sequence!',
      );

  factory FoldCursor.fromEntry(LogEntry entry) => FoldCursor(
    entry.timestamp,
    author: entry.author,
    sequence: entry.sequence,
  );

  /// Whether [entry] sorts strictly after this cursor in fold order —
  /// i.e. still needs folding.
  bool isBefore(LogEntry entry) {
    final byTimestamp = timestamp.compareTo(entry.timestamp);
    if (byTimestamp != 0) return byTimestamp < 0;
    final cursorAuthor = author;
    if (cursorAuthor == null) {
      // Legacy cursor: no tiebreak information — treat ties as folded
      // (the pre-COR3-27 behavior; correct going forward once a
      // full-position cursor is persisted).
      return false;
    }
    final byAuthor = cursorAuthor.value.compareTo(entry.author.value);
    if (byAuthor != 0) return byAuthor < 0;
    return sequence! < entry.sequence;
  }

  @override
  String toString() => author == null
      ? timestamp.toString()
      : '$timestamp|${author!.value}|$sequence';

  /// Parses a persisted cursor; null on any corruption (callers fall back
  /// to a full rebuild).
  static FoldCursor? tryParse(String s) {
    final parts = s.split('|');
    if (parts.length == 3) {
      final ts = Hlc.tryParse(parts[0]);
      final seq = int.tryParse(parts[2]);
      if (ts == null || seq == null || parts[1].trim().isEmpty) return null;
      return FoldCursor(ts, author: NodeId(parts[1]), sequence: seq);
    }
    final legacy = Hlc.tryParse(s);
    return legacy == null ? null : FoldCursor(legacy);
  }
}
