import '../value_objects/version_vector.dart';

/// Result of running compaction.
class CompactionResult {
  final int entriesRemoved;
  final int entriesRetained;
  final int bytesFreed;
  final VersionVector oldBaseVersion;
  final VersionVector newBaseVersion;

  const CompactionResult({
    required this.entriesRemoved,
    required this.entriesRetained,
    required this.bytesFreed,
    required this.oldBaseVersion,
    required this.newBaseVersion,
  });

  factory CompactionResult.noChange(VersionVector version) => CompactionResult(
    entriesRemoved: 0,
    entriesRetained: 0,
    bytesFreed: 0,
    oldBaseVersion: version,
    newBaseVersion: version,
  );

  @override
  bool operator ==(Object other) =>
      other is CompactionResult &&
      other.entriesRemoved == entriesRemoved &&
      other.entriesRetained == entriesRetained &&
      other.bytesFreed == bytesFreed &&
      other.oldBaseVersion == oldBaseVersion &&
      other.newBaseVersion == newBaseVersion;

  @override
  int get hashCode => Object.hash(
    entriesRemoved,
    entriesRetained,
    bytesFreed,
    oldBaseVersion,
    newBaseVersion,
  );
}
