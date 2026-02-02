import 'package:meta/meta.dart';
import '../../domain/value_objects/stream_id.dart';
import '../../domain/value_objects/version_vector.dart';

/// Compact summary of a single stream's synchronization state.
///
/// [StreamDigest] represents the sync state of one stream in a compact form
/// suitable for wire transmission. Instead of sending all entries, peers
/// exchange digests containing only version vectors (highest sequence per
/// author). This allows efficient comparison to identify missing entries.
///
/// Digests are exchanged during anti-entropy:
/// 1. Peers send digests in [DigestRequest] and [DigestResponse]
/// 2. Receivers compare digests to their own state
/// 3. Receivers send [DeltaRequest] for streams where they're behind
///
/// ## Efficiency
/// A digest is typically 10-100 bytes (depending on number of authors),
/// while the actual stream might contain megabytes of entries. This enables
/// sub-second convergence even with large datasets.
@immutable
class StreamDigest {
  /// The stream being summarized.
  final StreamId streamId;

  /// Version vector summarizing sync state.
  ///
  /// Maps each author to the highest sequence number seen from that author
  /// in this stream. Enables efficient delta computation during anti-entropy.
  final VersionVector version;

  const StreamDigest({required this.streamId, required this.version});

  @override
  bool operator ==(Object other) =>
      other is StreamDigest &&
      other.streamId == streamId &&
      other.version == version;

  @override
  int get hashCode => Object.hash(streamId, version);

  @override
  String toString() => 'StreamDigest($streamId, $version)';
}
