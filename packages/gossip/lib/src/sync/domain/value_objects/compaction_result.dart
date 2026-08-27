import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';

/// Result of running compaction.
class CompactionResult {
  final int entriesRemoved;
  final int entriesRetained;
  final int bytesFreed;

  /// The stream's version vector, unchanged by this compaction.
  ///
  /// `EntryRepository.getVersionVector` is a monotonic high-water mark that
  /// `EntryRepository.removeEntries` (what compaction calls) must never
  /// regress — so the value before and after a compaction pass is always
  /// the same one. A single field tells that truth; two identically-valued
  /// `old`/`new` fields would only invite a caller to expect them to
  /// diverge.
  final VersionVector baseVersion;

  const CompactionResult({
    required this.entriesRemoved,
    required this.entriesRetained,
    required this.bytesFreed,
    required this.baseVersion,
  });

  factory CompactionResult.noChange(VersionVector version) => CompactionResult(
    entriesRemoved: 0,
    entriesRetained: 0,
    bytesFreed: 0,
    baseVersion: version,
  );

  @override
  bool operator ==(Object other) =>
      other is CompactionResult &&
      other.entriesRemoved == entriesRemoved &&
      other.entriesRetained == entriesRetained &&
      other.bytesFreed == bytesFreed &&
      other.baseVersion == baseVersion;

  @override
  int get hashCode =>
      Object.hash(entriesRemoved, entriesRetained, bytesFreed, baseVersion);
}
