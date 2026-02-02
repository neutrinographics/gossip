import 'dart:math';
import 'node_id.dart';

/// Version vector tracking synchronization state across peers.
///
/// A [VersionVector] maps each peer to the highest sequence number seen
/// from that peer for a particular stream. Version vectors enable efficient
/// anti-entropy by allowing peers to quickly determine which entries they
/// are missing during synchronization.
///
/// Version vectors support:
/// - **Efficient delta sync**: Identify missing entries without scanning logs
/// - **Causality tracking**: Determine if one state dominates another
/// - **Progress monitoring**: Track sync advancement per peer
///
/// ## Invariants
/// - All sequence numbers must be non-negative (>= 0)
/// - Zero indicates "no entries seen from this node"
///
/// Value objects are immutable and compared by value equality.
class VersionVector {
  /// Map from node ID to highest sequence number seen from that node.
  final Map<NodeId, int> _versions;

  /// Creates a [VersionVector] with the given node-to-sequence mappings.
  ///
  /// Throws [ArgumentError] if any sequence number is negative.
  VersionVector([Map<NodeId, int>? versions])
    : _versions = versions ?? const {} {
    for (final entry in _versions.entries) {
      if (entry.value < 0) {
        throw ArgumentError.value(
          entry.value,
          'versions[${entry.key}]',
          'Sequence numbers must be non-negative',
        );
      }
    }
  }

  /// Private const constructor for empty constant.
  const VersionVector._empty() : _versions = const {};

  /// Empty version vector with no entries.
  static const empty = VersionVector._empty();

  /// Gets the sequence number for a node, or 0 if not present.
  int operator [](NodeId node) => _versions[node] ?? 0;

  /// Returns an unmodifiable view of all node-to-sequence mappings.
  Map<NodeId, int> get entries => Map.unmodifiable(_versions);

  /// Returns true if this version vector contains no entries.
  bool get isEmpty => _versions.isEmpty;

  /// Returns a new version vector with the sequence for [node] incremented by 1.
  VersionVector increment(NodeId node) =>
      VersionVector({..._versions, node: this[node] + 1});

  /// Returns a new version vector with [node] set to the given [sequence].
  VersionVector set(NodeId node, int sequence) =>
      VersionVector({..._versions, node: sequence});

  /// Merges two version vectors by taking the maximum sequence for each node.
  ///
  /// Returns a new version vector containing all nodes from both vectors,
  /// with each node's sequence set to the maximum of the two vectors.
  /// This is the standard version vector merge operation for anti-entropy.
  VersionVector merge(VersionVector other) {
    final merged = <NodeId, int>{..._versions};
    for (final entry in other._versions.entries) {
      merged[entry.key] = max(merged[entry.key] ?? 0, entry.value);
    }
    return VersionVector(Map.unmodifiable(merged));
  }

  /// Returns nodes and sequences where [other] is ahead of this vector.
  ///
  /// For each node in [other], if its sequence is greater than ours,
  /// includes that node mapped to our current sequence. This identifies
  /// which ranges of entries we need to request during synchronization.
  Map<NodeId, int> diff(VersionVector other) {
    final missing = <NodeId, int>{};
    for (final entry in other._versions.entries) {
      final ours = this[entry.key];
      if (entry.value > ours) {
        missing[entry.key] = ours;
      }
    }
    return missing;
  }

  /// Returns true if this vector dominates or equals [other].
  ///
  /// A version vector dominates another if its sequence for every node
  /// is greater than or equal to the other's sequence. This indicates
  /// that this vector has seen all events represented by [other].
  bool dominates(VersionVector other) {
    for (final entry in other._versions.entries) {
      if (this[entry.key] < entry.value) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) {
    if (other is! VersionVector) return false;
    if (_versions.length != other._versions.length) return false;
    for (final entry in _versions.entries) {
      if (other._versions[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    var hash = 0;
    for (final entry in _versions.entries) {
      hash ^= Object.hash(entry.key, entry.value);
    }
    return hash;
  }
}
