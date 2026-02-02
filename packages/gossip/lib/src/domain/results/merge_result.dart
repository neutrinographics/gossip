import '../value_objects/log_entry.dart';
import '../value_objects/version_vector.dart';

/// Result of merging remote entries.
class MergeResult {
  final List<LogEntry> newEntries;
  final List<LogEntry> duplicates;
  final List<LogEntry> outOfOrder;
  final List<LogEntry> dropped;
  final List<LogEntry> rejected;
  final VersionVector newVersion;

  const MergeResult({
    required this.newEntries,
    required this.duplicates,
    required this.outOfOrder,
    required this.dropped,
    required this.rejected,
    required this.newVersion,
  });

  factory MergeResult.empty() => const MergeResult(
    newEntries: [],
    duplicates: [],
    outOfOrder: [],
    dropped: [],
    rejected: [],
    newVersion: VersionVector.empty,
  );

  bool get hasNewEntries => newEntries.isNotEmpty;
  bool get hasOutOfOrder => outOfOrder.isNotEmpty;
  bool get hasDropped => dropped.isNotEmpty;
  bool get hasRejected => rejected.isNotEmpty;
  int get totalProcessed =>
      newEntries.length +
      duplicates.length +
      outOfOrder.length +
      dropped.length +
      rejected.length;
}
